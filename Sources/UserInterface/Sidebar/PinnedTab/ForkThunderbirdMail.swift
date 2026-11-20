// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

/// Fork: the Unified Inbox from Thunderbird, for the Gmail pinned tab's card
/// (`ForkSettings.gmailCardSource == .thunderbird`).
///
/// Thunderbird has no API other apps can call, so a small Thunderbird add-on
/// (built here, see `addonFiles`) reads the mail and talks to Phi+ through
/// Thunderbird's native messaging: Thunderbird starts the "host" this class
/// registers, a one-line script that runs macOS's `nc` to join a Unix socket
/// Phi+ listens on in its own data folder. Messages in both directions are
/// native-messaging frames (a 4-byte length, then JSON). The add-on sends a
/// snapshot of the newest messages on connect and whenever mail changes;
/// Phi+ sends commands (refresh, open, mark read, compose).
@MainActor
final class ForkThunderbirdMail: ObservableObject {
    static let shared = ForkThunderbirdMail()

    struct Message: Identifiable, Equatable {
        let id: Int
        let author: String
        let subject: String
        let date: Date
        var read: Bool
        let flagged: Bool
        let preview: String

        /// "Name <address>" → Name; a bare address stays as it is.
        var senderName: String {
            let trimmed = author.trimmingCharacters(in: .whitespaces)
            if let open = trimmed.lastIndex(of: "<"), open > trimmed.startIndex {
                let name = trimmed[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                if !name.isEmpty { return name }
            }
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
    }

    enum Status: Equatable {
        /// The add-on has never connected: the card offers to install it.
        case needsAddon
        case thunderbirdClosed
        /// Thunderbird is open; its add-on retries the connection every 10 s.
        case connecting
        case connected
    }

    /// A message's content, for reading it in the card.
    struct Body: Equatable {
        let id: Int
        let html: String
        let text: String
        let to: String
        let cc: String
        let error: String?
    }

    static let thunderbirdBundleId = "org.mozilla.thunderbird"
    /// The add-on version this Phi+ expects (its `hello` message). An older
    /// add-on keeps working for the list; the card asks to update it.
    static let currentAddonVersion = 4
    static let hostName = "com.bengutteridge.phiplus.mail"
    static let addonId = "phiplus-mail@bengutteridge"

    @Published private(set) var messages: [Message] = []
    @Published private(set) var hasSnapshot = false
    @Published private(set) var isConnected = false
    @Published private(set) var isThunderbirdRunning = false
    @Published private(set) var addonSeen = ForkSettings.thunderbirdAddonSeen
    @Published private(set) var addonVersion: Int?
    /// The message being read in the card, and its content once it arrives.
    @Published private(set) var openedMessage: Message?
    @Published private(set) var openedBody: Body?
    private var bodyRequestedAt: Date?

    var addonNeedsUpdate: Bool { isConnected && (addonVersion ?? 0) < Self.currentAddonVersion }

    var status: Status {
        if isConnected { return .connected }
        if !addonSeen { return .needsAddon }
        return isThunderbirdRunning ? .connecting : .thunderbirdClosed
    }

    private var started = false
    private var server: Server?
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {}

    /// Registers the native-messaging host and starts listening. Cheap and
    /// idempotent; called at launch when the card uses Thunderbird, and when
    /// the setting or the card asks for it.
    func start() {
        guard !started else { return }
        started = true
        let paths = Paths()
        writeHostFiles(paths)
        let server = Server(socketPath: paths.socket)
        server.onConnect = { [weak self] in
            Task { @MainActor in self?.isConnected = true }
        }
        server.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.isConnected = false
                self?.addonVersion = nil
            }
        }
        server.onMessage = { [weak self] json in
            Task { @MainActor in self?.handle(json) }
        }
        server.start()
        self.server = server
        updateRunning()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.thunderbirdBundleId else { return }
                MainActor.assumeIsolated { self?.updateRunning() }
            })
        }
    }

    // MARK: Commands

    func refresh() { send(["cmd": "refresh"]) }

    func open(_ message: Message) {
        send(["cmd": "open", "id": message.id])
        setLocalRead(message.id, true)
        activateThunderbird()
    }

    /// Shows `message` in the card and asks the add-on for its content.
    func read(_ message: Message) {
        openedMessage = message
        openedBody = nil
        bodyRequestedAt = Date()
        AppLogInfo("[ForkThunderbirdMail] content requested for \(message.id)")
        send(["cmd": "getBody", "id": message.id])
        if !message.read { setRead(message, true) }
    }

    func closeReader() {
        openedMessage = nil
        openedBody = nil
    }

    func setRead(_ message: Message, _ read: Bool) {
        send(["cmd": "setRead", "id": message.id, "read": read])
        setLocalRead(message.id, read)
    }

    /// Archives `message` in Thunderbird (Gmail: to All Mail). It leaves the
    /// list at once; the add-on's next snapshot confirms it.
    func archive(_ message: Message) {
        send(["cmd": "archive", "id": message.id])
        archivedAt[message.id] = Date()
        // Animated, so the rows below slide up as the swipe finishes,
        // instead of the gap closing in one jump.
        withAnimation(Self.listAnimation) {
            messages.removeAll { $0.id == message.id }
        }
        if openedMessage?.id == message.id { closeReader() }
    }

    /// Messages archived from the card in the last few seconds, kept out of
    /// snapshots the add-on sent before Thunderbird finished moving them, so
    /// a row never reappears and vanishes again.
    private var archivedAt: [Int: Date] = [:]
    private static let listAnimation = Animation.easeInOut(duration: 0.28)

    /// Opens Thunderbird's reply window for `message`, ready to type.
    func reply(_ message: Message, all: Bool) {
        send(["cmd": "reply", "id": message.id, "all": all])
        activateThunderbird()
    }

    func compose() {
        send(["cmd": "compose"])
        activateThunderbird()
    }

    func openThunderbird() {
        if activateThunderbird() { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.thunderbirdBundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    var isThunderbirdInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.thunderbirdBundleId) != nil
    }

    /// Builds the add-on and shows the file in Finder, to install in
    /// Thunderbird's Add-ons and Themes page.
    func revealAddon() {
        guard let xpi = buildAddon() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([xpi])
    }

    @discardableResult
    private func activateThunderbird() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.thunderbirdBundleId).first else { return false }
        app.activate()
        return true
    }

    private func updateRunning() {
        isThunderbirdRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.thunderbirdBundleId).isEmpty
    }

    private func setLocalRead(_ id: Int, _ read: Bool) {
        if openedMessage?.id == id { openedMessage?.read = read }
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].read = read
    }

    private func send(_ command: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        server?.send(data)
    }

    private func handle(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        if !addonSeen {
            addonSeen = true
            ForkSettings.thunderbirdAddonSeen = true
        }
        switch type {
        case "snapshot":
            let list = json["messages"] as? [[String: Any]] ?? []
            let now = Date()
            archivedAt = archivedAt.filter { now.timeIntervalSince($0.value) < 15 }
            let incoming: [Message] = list.compactMap { item in
                guard let id = (item["id"] as? NSNumber)?.intValue else { return nil }
                let millis = (item["date"] as? NSNumber)?.doubleValue ?? 0
                return Message(id: id, author: item["from"] as? String ?? "",
                               subject: item["subject"] as? String ?? "",
                               date: Date(timeIntervalSince1970: millis / 1000),
                               read: item["read"] as? Bool ?? true,
                               flagged: item["flagged"] as? Bool ?? false,
                               preview: item["preview"] as? String ?? "")
            }.filter { archivedAt[$0.id] == nil }
            // Rows that arrive or leave (new mail, changes in Thunderbird)
            // slide in and out like an archived one, rather than jumping.
            if hasSnapshot, incoming != messages {
                withAnimation(Self.listAnimation) { messages = incoming }
            } else {
                messages = incoming
            }
            hasSnapshot = true
        case "hello":
            addonVersion = (json["version"] as? NSNumber)?.intValue
            AppLogInfo("[ForkThunderbirdMail] add-on connected, version \(addonVersion ?? 0)")
        case "body":
            let elapsed = bodyRequestedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            AppLogInfo("[ForkThunderbirdMail] content for \(json["id"] ?? "?") after \(elapsed) ms, \(data.count) bytes, error: \(json["error"] as? String ?? "none")")
            guard let id = (json["id"] as? NSNumber)?.intValue, id == openedMessage?.id else { break }
            openedBody = Body(id: id, html: json["html"] as? String ?? "", text: json["text"] as? String ?? "",
                              to: json["to"] as? String ?? "", cc: json["cc"] as? String ?? "",
                              error: json["error"] as? String)
        case "error":
            AppLogInfo("[ForkThunderbirdMail] add-on error: \(json["message"] as? String ?? "")")
        default:
            break
        }
    }

    // MARK: Host registration

    private struct Paths {
        let dataFolder: URL
        let socket: String
        let hostScript: URL

        init() {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dataFolder = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.bengutteridge.phiplus", isDirectory: true)
            hostScript = dataFolder.appendingPathComponent("thunderbird-mail-host.sh")
            let preferred = dataFolder.appendingPathComponent("tb-mail.sock").path
            // A Unix socket path must fit in 104 bytes.
            socket = preferred.utf8.count < 100 ? preferred
                : (NSTemporaryDirectory() as NSString).appendingPathComponent("phiplus-mail.sock")
        }

        /// Thunderbird reads per-user host manifests from one of these; its
        /// documentation and Firefox's disagree, so both get one.
        var manifestFolders: [URL] {
            let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
            return [
                library.appendingPathComponent("Mozilla/NativeMessagingHosts", isDirectory: true),
                library.appendingPathComponent("Application Support/Mozilla/NativeMessagingHosts", isDirectory: true)
            ]
        }
    }

    private func writeHostFiles(_ paths: Paths) {
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.dataFolder, withIntermediateDirectories: true)
        let quoted = paths.socket.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        # Phi+: relays the Phi+ Mail add-on in Thunderbird to Phi+ (native messaging).
        exec /usr/bin/nc -U '\(quoted)'

        """
        writeIfChanged(Data(script.utf8), to: paths.hostScript)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.hostScript.path)
        let manifest: [String: Any] = [
            "name": Self.hostName,
            "description": "Phi+ mail card",
            "path": paths.hostScript.path,
            "type": "stdio",
            "allowed_extensions": [Self.addonId]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        for folder in paths.manifestFolders {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            writeIfChanged(data, to: folder.appendingPathComponent("\(Self.hostName).json"))
        }
    }

    private func writeIfChanged(_ data: Data, to url: URL) {
        if (try? Data(contentsOf: url)) == data { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: The add-on

    private func buildAddon() -> URL? {
        let paths = Paths()
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("phiplus-mail-addon-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for (name, contents) in Self.addonFiles {
                try Data(contents.utf8).write(to: staging.appendingPathComponent(name))
            }
        } catch { return nil }
        let xpi = paths.dataFolder.appendingPathComponent("Phi+ Mail for Thunderbird.xpi")
        try? fm.removeItem(at: xpi)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-q", "-X", xpi.path] + Self.addonFiles.map(\.0)
        do { try zip.run() } catch { return nil }
        zip.waitUntilExit()
        return zip.terminationStatus == 0 ? xpi : nil
    }

    private static let addonFiles: [(String, String)] = [("manifest.json", addonManifest), ("background.js", addonBackground)]

    private static let addonManifest = #"""
    {
      "manifest_version": 2,
      "name": "Phi+ Mail",
      "description": "Shows your latest mail in the Gmail pinned tab's card in Phi+.",
      "version": "1.4",
      "browser_specific_settings": {
        "gecko": { "id": "phiplus-mail@bengutteridge", "strict_min_version": "128.0" }
      },
      "background": { "scripts": ["background.js"] },
      "permissions": ["accountsRead", "messagesRead", "messagesUpdate", "messagesMove", "compose", "nativeMessaging"]
    }
    """#

    private static let addonBackground = #"""
    "use strict";
    // Phi+ Mail: sends the newest messages to Phi+ and runs its commands.
    // Talks to Phi+ through the native-messaging host Phi+ registers; when
    // Phi+ isn't running the host exits at once and this retries later.
    const HOST = "com.bengutteridge.phiplus.mail";
    const LIMIT = 40;
    const DAYS = 90;
    let port = null;
    let retryTimer = null;
    let snapshotTimer = null;

    function connect() {
      clearTimeout(retryTimer);
      retryTimer = null;
      try {
        port = messenger.runtime.connectNative(HOST);
      } catch (e) {
        port = null;
        scheduleReconnect();
        return;
      }
      port.onMessage.addListener(onCommand);
      port.onDisconnect.addListener(() => {
        port = null;
        scheduleReconnect();
      });
      port.postMessage({ type: "hello", version: 4 });
      scheduleSnapshot(0);
    }

    function scheduleReconnect() {
      if (!retryTimer) retryTimer = setTimeout(connect, 10000);
    }

    function scheduleSnapshot(delay = 1500) {
      if (!port) return;
      clearTimeout(snapshotTimer);
      snapshotTimer = setTimeout(sendSnapshot, delay);
    }

    // The Unified Inbox: every account's Inbox together.
    async function sourceFolders() {
      const folders = await messenger.folders.query({ specialUse: ["inbox"] });
      return folders.filter(f => !f.isUnified && !f.isVirtual && f.accountId).map(f => f.id);
    }

    // Preview text, read once per message (Thunderbird keeps no preview a
    // MailExtension can see) and cached by Message-ID.
    const previews = new Map();
    async function preview(m) {
      const key = m.headerMessageId || String(m.id);
      if (previews.has(key)) return previews.get(key);
      let text = "";
      try {
        const parts = await messenger.messages.listInlineTextParts(m.id);
        const plain = parts.find(p => p.contentType === "text/plain");
        const html = parts.find(p => p.contentType === "text/html");
        if (plain) {
          text = plain.content;
        } else if (html) {
          try {
            text = await messenger.messengerUtilities.convertToPlainText(html.content);
          } catch (e) {
            text = html.content.replace(/<style[\s\S]*?<\/style>/gi, " ").replace(/<[^>]+>/g, " ");
          }
        }
      } catch (e) {
        return "";
      }
      text = text.split("\n").filter(line => !/^\s*>/.test(line)).join(" ")
        .replace(/https?:\/\/\S+/g, "").replace(/\s+/g, " ").trim().slice(0, 220);
      previews.set(key, text);
      if (previews.size > 500) previews.delete(previews.keys().next().value);
      return text;
    }

    async function sendSnapshot() {
      if (!port) return;
      try {
        const folderIds = await sourceFolders();
        let messages = [];
        if (folderIds.length) {
          let page = await messenger.messages.query({
            folderId: folderIds,
            fromDate: new Date(Date.now() - DAYS * 86400000),
            messagesPerPage: 500,
            autoPaginationTimeout: 0
          });
          messages = page.messages;
          while (page.id && messages.length < 5000) {
            page = await messenger.messages.continueList(page.id);
            messages = messages.concat(page.messages);
          }
        }
        messages.sort((a, b) => new Date(b.date) - new Date(a.date));
        const seen = new Set();
        const out = [];
        for (const m of messages) {
          const key = m.headerMessageId || String(m.id);
          if (seen.has(key)) continue;
          seen.add(key);
          out.push({
            id: m.id,
            from: m.author || "",
            subject: m.subject || "",
            date: new Date(m.date).getTime(),
            read: !!m.read,
            flagged: !!m.flagged,
            preview: previews.get(key) || "",
            header: m,
            key
          });
          if (out.length >= LIMIT) break;
        }
        if (port) port.postMessage({ type: "snapshot", messages: out.map(({ header, key, ...rest }) => rest) });
        // Then again with previews, read a few at a time.
        const missing = out.filter(o => !previews.has(o.key));
        for (let i = 0; i < missing.length; i += 6) {
          await Promise.all(missing.slice(i, i + 6).map(o => preview(o.header)));
        }
        for (const o of out) o.preview = previews.get(o.key) || "";
        if (port) port.postMessage({ type: "snapshot", messages: out.map(({ header, key, ...rest }) => rest) });
      } catch (e) {
        if (port) port.postMessage({ type: "error", message: String(e) });
      }
    }

    // Gmail's archive is a move to All Mail: the message leaves the Inbox and
    // stays in All Mail. Other accounts use Thunderbird's own archive setting.
    async function archiveMessage(id) {
      const header = await messenger.messages.get(id);
      const accountId = header.folder && header.folder.accountId;
      if (accountId) {
        const folders = await messenger.folders.query({ accountId });
        const allMail = folders.find(f => /^\/\[(Gmail|Google Mail)\]\/All Mail$/i.test(f.path || ""));
        if (allMail) {
          await messenger.messages.move([id], allMail.id);
          return;
        }
      }
      await messenger.messages.archive([id]);
    }

    async function onCommand(msg) {
      try {
        switch (msg && msg.cmd) {
          case "refresh":
            scheduleSnapshot(0);
            break;
          case "open":
            await openInThunderbird(msg.id);
            break;
          case "getBody":
            await sendBody(msg.id);
            break;
          case "setRead":
            await messenger.messages.update(msg.id, { read: !!msg.read });
            break;
          case "compose":
            await messenger.compose.beginNew();
            break;
          case "reply":
            await messenger.compose.beginReply(msg.id, msg.all ? "replyToAll" : "replyToSender");
            break;
          case "archive":
            await archiveMessage(msg.id);
            break;
        }
      } catch (e) {
        if (port) port.postMessage({ type: "error", message: String(e) });
      }
    }

    // With no main window (Thunderbird running, window closed) there is no
    // tab to show the message in, so it gets a window of its own.
    async function openInThunderbird(id) {
      const normal = await messenger.windows.getAll({ windowTypes: ["normal"] });
      const props = { messageId: id };
      if (!normal.length) props.location = "window";
      const tab = await messenger.messageDisplay.open(props);
      if (tab && tab.windowId !== undefined) {
        try { await messenger.windows.update(tab.windowId, { focused: true }); } catch (e) {}
      }
    }

    // The message's content, for reading it in the card.
    async function sendBody(id) {
      try {
        const header = await messenger.messages.get(id);
        const parts = await messenger.messages.listInlineTextParts(id);
        const html = parts.find(p => p.contentType === "text/html");
        const plain = parts.find(p => p.contentType === "text/plain");
        if (port) port.postMessage({
          type: "body",
          id,
          html: html ? html.content : "",
          text: plain ? plain.content : "",
          to: (header.recipients || []).join(", "),
          cc: (header.ccList || []).join(", ")
        });
      } catch (e) {
        if (port) port.postMessage({ type: "body", id, error: String(e) });
      }
    }

    messenger.messages.onNewMailReceived.addListener(() => scheduleSnapshot());
    messenger.messages.onUpdated.addListener(() => scheduleSnapshot());
    messenger.messages.onMoved.addListener(() => scheduleSnapshot());
    messenger.messages.onDeleted.addListener(() => scheduleSnapshot());
    connect();
    """#
}

// MARK: - Socket server

/// One-client Unix socket server speaking native-messaging frames. All I/O
/// runs on its own queue; callbacks arrive on that queue.
private final class Server: @unchecked Sendable {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onMessage: ((Data) -> Void)?

    private let socketPath: String
    private let queue = DispatchQueue(label: "com.bengutteridge.phiplus.thunderbird-mail")
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clientFD: Int32 = -1
    private var clientSource: DispatchSourceRead?
    private var buffer = Data()

    init(socketPath: String) { self.socketPath = socketPath }

    func start() {
        queue.async { self.listen() }
    }

    func send(_ payload: Data) {
        queue.async {
            guard self.clientFD >= 0 else { return }
            var length = UInt32(payload.count).littleEndian
            var frame = Data(bytes: &length, count: 4)
            frame.append(payload)
            frame.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(self.clientFD, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
    }

    private func listen() {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 2) == 0 else { close(fd); return }
        // Only this user may connect.
        chmod(socketPath, 0o600)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        listenSource = source
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        dropClient(notify: false)
        clientFD = fd
        buffer.removeAll()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readClient() }
        source.setCancelHandler { close(fd) }
        source.resume()
        clientSource = source
        onConnect?()
    }

    private func readClient() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = read(clientFD, &chunk, chunk.count)
        guard count > 0 else {
            dropClient(notify: true)
            return
        }
        buffer.append(contentsOf: chunk[0..<count])
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard length < 8 << 20 else { dropClient(notify: true); return }
            guard buffer.count >= 4 + length else { break }
            let payload = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + length)
            onMessage?(payload)
        }
    }

    private func dropClient(notify: Bool) {
        guard clientFD >= 0 else { return }
        clientSource?.cancel()
        clientSource = nil
        clientFD = -1
        buffer.removeAll()
        if notify { onDisconnect?() }
    }
}
