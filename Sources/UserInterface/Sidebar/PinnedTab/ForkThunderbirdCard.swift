// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import WebKit

/// Fork: the Gmail pinned tab's card when it shows Thunderbird's Unified
/// Inbox (`ForkThunderbirdMail`), laid out like Apple Mail's message list.
struct ForkThunderbirdCardView: View {
    @ObservedObject var mail: ForkThunderbirdMail
    /// Opens a link from a message in a new Phi+ tab.
    let openLink: (URL) -> Void
    @State private var isRefreshing = false
    /// The native list takes a row's click for its selection, so a click
    /// reaches the row as a selection; it opens the message and clears.
    @State private var clickedMessageId: Int?

    var body: some View {
        ZStack {
            if let opened = mail.openedMessage {
                ForkMailReaderView(message: opened, mail: mail, openLink: openLink)
                    .transition(.move(edge: .trailing))
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    if mail.addonNeedsUpdate {
                        updateBar
                        Divider()
                    } else if mail.status == .connecting {
                        reconnectingBar
                        Divider()
                    }
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.move(edge: .leading))
            }
        }
        .animation(.easeOut(duration: 0.2), value: mail.openedMessage?.id)
        .clipped()
        .onChange(of: mail.messages) { _, _ in isRefreshing = false }
    }

    /// While the add-on is away (Thunderbird busy, the add-on removed or
    /// disabled), the last list stays up with this note.
    private var reconnectingBar: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(NSLocalizedString("pinnedPreview.mail.reconnecting", value: "Reconnecting to Thunderbird…",
                comment: "Thunderbird mail card - slim notice above the list while the Thunderbird add-on is not connected"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// A slim notice above the list while the add-on is out of date.
    private var updateBar: some View {
        HStack(spacing: 6) {
            Text(NSLocalizedString("pinnedPreview.mail.update.bar", value: "Update the Phi+ Mail add-on to read mail here.",
                comment: "Thunderbird mail card - slim notice above the list when the Thunderbird add-on is out of date"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(NSLocalizedString("pinnedPreview.mail.update.show", value: "Show File",
                comment: "Thunderbird mail card - link in the update notice that shows the add-on file in Finder"),
                   action: mail.revealAddon)
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(NSLocalizedString("pinnedPreview.mail.title", value: "Inbox",
                    comment: "Thunderbird mail card - title above the Unified Inbox list"))
                    .font(.system(size: 15, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if mail.status == .connected || (mail.status == .connecting && mail.hasSnapshot) {
                Button(action: mail.compose) {
                    Image(systemName: "square.and.pencil")
                }
                .help(NSLocalizedString("pinnedPreview.mail.compose", value: "New Message",
                    comment: "Thunderbird mail card - button that starts a new message in Thunderbird"))
                Button {
                    isRefreshing = true
                    mail.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { isRefreshing = false }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                                   value: isRefreshing)
                }
                .help(NSLocalizedString("pinnedPreview.mail.refresh", value: "Refresh",
                    comment: "Thunderbird mail card - button that reloads the message list"))
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    private var subtitle: String {
        let unread = mail.messages.filter { !$0.read }.count
        guard mail.status == .connected, mail.hasSnapshot, unread > 0 else {
            return NSLocalizedString("pinnedPreview.mail.subtitle", value: "Thunderbird",
                comment: "Thunderbird mail card - subtitle naming the app the mail comes from")
        }
        return String(format: NSLocalizedString("pinnedPreview.mail.unread", value: "%d unread",
            comment: "Thunderbird mail card - subtitle with the number of unread messages in the list"), unread)
    }

    @ViewBuilder
    private var content: some View {
        switch mail.status {
        case .connected, .connecting where mail.hasSnapshot:
            // While the add-on reconnects, the last list stays up.
            if !mail.hasSnapshot {
                ProgressView().controlSize(.small)
            } else if mail.messages.isEmpty {
                Text(NSLocalizedString("pinnedPreview.mail.empty", value: "No Mail",
                    comment: "Thunderbird mail card - shown when the inbox has no recent messages"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                // A native list, for Apple Mail's swipe left to archive (a
                // full swipe archives at once).
                List(selection: $clickedMessageId) {
                    ForEach(mail.messages) { message in
                        ForkMailRow(message: message, mail: mail)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button { mail.archive(message) } label: {
                                    Label(ForkMailRow.archiveTitle, systemImage: "archivebox.fill")
                                }
                                // The unread dot's color.
                                .tint(.accentColor)
                            }
                    }
                }
                .listStyle(.plain)
                .onChange(of: clickedMessageId) { _, id in
                    guard let id else { return }
                    clickedMessageId = nil
                    if let message = mail.messages.first(where: { $0.id == id }) { mail.read(message) }
                }
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
            }
        case .connecting:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("pinnedPreview.mail.connecting", value: "Connecting to Thunderbird…",
                    comment: "Thunderbird mail card - shown while waiting for the Thunderbird add-on to connect"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("pinnedPreview.mail.connecting.hint", value: "If this doesn't change, check the Phi+ Mail add-on is installed and enabled in Thunderbird's Add-ons and Themes.",
                    comment: "Thunderbird mail card - hint under the connecting spinner"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
                Button(NSLocalizedString("pinnedPreview.mail.setup.reveal", value: "Show Add-on File",
                    comment: "Thunderbird mail card - button that shows the add-on file in Finder, to install it in Thunderbird"),
                       action: mail.revealAddon)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        case .thunderbirdClosed:
            message(
                title: NSLocalizedString("pinnedPreview.mail.closed.title", value: "Thunderbird Isn't Open",
                    comment: "Thunderbird mail card - title when Thunderbird is not running"),
                detail: NSLocalizedString("pinnedPreview.mail.closed.detail", value: "Your inbox shows here while Thunderbird is running.",
                    comment: "Thunderbird mail card - explains that Thunderbird must be running"),
                button: NSLocalizedString("pinnedPreview.mail.closed.button", value: "Open Thunderbird",
                    comment: "Thunderbird mail card - button that opens Thunderbird"),
                action: mail.openThunderbird)
        case .needsAddon:
            if mail.isThunderbirdInstalled {
                // Opening the file with Thunderbird attaches it to a new
                // message instead of installing it, so the card shows the
                // file and the steps.
                message(
                    title: NSLocalizedString("pinnedPreview.mail.setup.title", value: "Connect Thunderbird",
                        comment: "Thunderbird mail card - title when the Phi+ add-on is not installed in Thunderbird yet"),
                    detail: NSLocalizedString("pinnedPreview.mail.setup.steps", value: "Install the small Phi+ Mail add-on: in Thunderbird, choose Tools ▸ Add-ons and Themes, click the gear button, choose Install Add-on From File, and pick the file this button shows.",
                        comment: "Thunderbird mail card - steps for installing the Phi+ add-on file in Thunderbird"),
                    button: NSLocalizedString("pinnedPreview.mail.setup.reveal", value: "Show Add-on File",
                        comment: "Thunderbird mail card - button that shows the add-on file in Finder, to install it in Thunderbird"),
                    action: mail.revealAddon)
            } else {
                message(
                    title: NSLocalizedString("pinnedPreview.mail.missing.title", value: "Thunderbird Isn't Installed",
                        comment: "Thunderbird mail card - title when Thunderbird is not installed"),
                    detail: NSLocalizedString("pinnedPreview.mail.missing.detail", value: "Install Thunderbird, or show the Gmail website in this card in Settings → Spaces.",
                        comment: "Thunderbird mail card - explains what to do when Thunderbird is not installed"),
                    button: nil, action: {})
            }
        }
    }

    private func message(title: String, detail: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let button {
                Button(button, action: action)
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 28)
    }
}

/// One message, as in Apple Mail: unread dot, bold sender with the date on
/// the right, subject, and two lines of preview.
private struct ForkMailRow: View {
    let message: ForkThunderbirdMail.Message
    let mail: ForkThunderbirdMail
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .opacity(message.read ? 0 : 1)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.senderName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if message.flagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Text(Self.dateText(message.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(message.subject.isEmpty
                     ? NSLocalizedString("pinnedPreview.mail.noSubject", value: "(No Subject)",
                         comment: "Thunderbird mail card - shown for a message without a subject")
                     : message.subject)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if !message.preview.isEmpty {
                    Text(message.preview)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 26) }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(message.read
                   ? NSLocalizedString("pinnedPreview.mail.markUnread", value: "Mark as Unread",
                       comment: "Thunderbird mail card - context menu item that marks the message unread")
                   : NSLocalizedString("pinnedPreview.mail.markRead", value: "Mark as Read",
                       comment: "Thunderbird mail card - context menu item that marks the message read")) {
                mail.setRead(message, !message.read)
            }
            Button(NSLocalizedString("pinnedPreview.mail.reply", value: "Reply",
                comment: "Thunderbird mail card - button that opens Thunderbird's reply window for the message")) {
                mail.reply(message, all: false)
            }
            Button(NSLocalizedString("pinnedPreview.mail.replyAll", value: "Reply All",
                comment: "Thunderbird mail card - button that opens Thunderbird's reply-to-all window for the message")) {
                mail.reply(message, all: true)
            }
            Button(Self.archiveTitle) { mail.archive(message) }
            Divider()
            Button(NSLocalizedString("pinnedPreview.mail.open", value: "Open in Thunderbird",
                comment: "Thunderbird mail card - context menu item that opens the message in Thunderbird")) {
                mail.open(message)
            }
        }
    }

    static var archiveTitle: String {
        NSLocalizedString("pinnedPreview.mail.archive", value: "Archive",
            comment: "Thunderbird mail card - swipe, menu and toolbar action that archives the message (Gmail: moves it to All Mail)")
    }

    /// Apple Mail's dates: a time today, "Yesterday", a weekday this week,
    /// otherwise a short date.
    static func dateText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return timeFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) {
            return NSLocalizedString("pinnedPreview.mail.yesterday", value: "Yesterday",
                comment: "Thunderbird mail card - date shown for a message from yesterday")
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: Date())).day, days < 7 {
            return weekdayFormatter.string(from: date)
        }
        return dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - Reading a message

/// One message, read in the card as in Apple Mail: back to the inbox, the
/// sender, date, subject and recipients, then the message itself.
struct ForkMailReaderView: View {
    let message: ForkThunderbirdMail.Message
    @ObservedObject var mail: ForkThunderbirdMail
    let openLink: (URL) -> Void
    @Environment(\.colorScheme) private var colorScheme
    /// In dark mode, show messages darkened instead of as designed.
    @AppStorage(ForkSettings.Key.mailMessagesDark) private var showsMessagesDark = false
    /// Set when the content hasn't arrived after a while.
    @State private var isSlow = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            headers
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: message.id) {
            isSlow = false
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { isSlow = true }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: mail.closeReader) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text(NSLocalizedString("pinnedPreview.mail.title", value: "Inbox",
                        comment: "Thunderbird mail card - title above the Unified Inbox list"))
                }
            }
            Spacer(minLength: 8)
            if colorScheme == .dark {
                Button { showsMessagesDark.toggle() } label: {
                    Image(systemName: showsMessagesDark ? "sun.max" : "moon")
                }
                .help(showsMessagesDark
                      ? NSLocalizedString("pinnedPreview.mail.showLight", value: "Show Messages as Designed",
                          comment: "Thunderbird mail card - button that shows messages with their own light colours")
                      : NSLocalizedString("pinnedPreview.mail.showDark", value: "Show Messages in Dark",
                          comment: "Thunderbird mail card - button that darkens messages to match dark mode"))
            }
            Button { mail.reply(message, all: false) } label: { Image(systemName: "arrowshape.turn.up.left") }
                .help(NSLocalizedString("pinnedPreview.mail.reply", value: "Reply",
                    comment: "Thunderbird mail card - button that opens Thunderbird's reply window for the message"))
            Button { mail.reply(message, all: true) } label: { Image(systemName: "arrowshape.turn.up.left.2") }
                .help(NSLocalizedString("pinnedPreview.mail.replyAll", value: "Reply All",
                    comment: "Thunderbird mail card - button that opens Thunderbird's reply-to-all window for the message"))
            Button { mail.archive(message) } label: { Image(systemName: "archivebox") }
                .help(ForkMailRow.archiveTitle)
            Button {
                mail.setRead(message, false)
                mail.closeReader()
            } label: { Image(systemName: "envelope.badge") }
                .help(NSLocalizedString("pinnedPreview.mail.markUnread", value: "Mark as Unread",
                    comment: "Thunderbird mail card - context menu item that marks the message unread"))
            Button { mail.open(message) } label: { Image(systemName: "arrow.up.forward.app") }
                .help(NSLocalizedString("pinnedPreview.mail.open", value: "Open in Thunderbird",
                    comment: "Thunderbird mail card - context menu item that opens the message in Thunderbird"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var headers: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(message.senderName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Self.dateFormatter.string(from: message.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(message.subject.isEmpty
                 ? NSLocalizedString("pinnedPreview.mail.noSubject", value: "(No Subject)",
                     comment: "Thunderbird mail card - shown for a message without a subject")
                 : message.subject)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if let body = currentBody, !body.to.isEmpty {
                Text(String(format: NSLocalizedString("pinnedPreview.mail.to", value: "To: %@",
                    comment: "Thunderbird mail card - the message's recipients; %@ is the list"), body.to))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var currentBody: ForkThunderbirdMail.Body? {
        guard let body = mail.openedBody, body.id == message.id else { return nil }
        return body
    }

    @ViewBuilder
    private var content: some View {
        if mail.addonNeedsUpdate {
            ForkMailAddonUpdateNotice(mail: mail)
        } else if let body = currentBody {
            if let error = body.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
            } else {
                let dark = colorScheme == .dark && showsMessagesDark
                ForkMailBodyView(document: Self.document(for: body, dark: dark),
                                 background: dark ? NSColor(white: 0.1, alpha: 1) : .white,
                                 openLink: openLink)
            }
        } else if !mail.isConnected {
            notice(NSLocalizedString("pinnedPreview.mail.reader.offline", value: "Not connected to Thunderbird. Make sure Thunderbird is open and the Phi+ Mail add-on is installed and enabled.",
                comment: "Thunderbird mail card - shown in place of a message while the Thunderbird add-on is not connected"))
        } else if isSlow {
            notice(NSLocalizedString("pinnedPreview.mail.reader.slow", value: "This message is taking a while to load from the mail server.",
                comment: "Thunderbird mail card - shown when a message's content hasn't arrived after 15 seconds"))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func notice(_ text: String) -> some View {
        VStack(spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(NSLocalizedString("pinnedPreview.mail.open", value: "Open in Thunderbird",
                comment: "Thunderbird mail card - context menu item that opens the message in Thunderbird")) {
                mail.open(message)
            }
        }
        .padding(.horizontal, 28)
    }

    /// The message as a page: its HTML (or its text, escaped), fitted to the
    /// card. Shown as designed (light), or when asked darkened with the same
    /// invert-and-rotate look as the Gmail card, pictures flipped back. The
    /// view always presents itself to the message as light mode (see
    /// `ForkMailBodyView`), so a message's own dark-mode styles, which often
    /// turn text white and leave the background to the mail app, never mix
    /// with this.
    static func document(for body: ForkThunderbirdMail.Body, dark: Bool) -> String {
        let content: String
        if !body.html.isEmpty {
            content = body.html
        } else {
            let escaped = body.text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            content = "<div style=\"white-space:pre-wrap\">\(escaped)</div>"
        }
        let darkStyle = dark ? """
        html { filter: invert(0.9) hue-rotate(180deg); }
        img, video, picture, svg, [style*="background-image"] { filter: invert(1) hue-rotate(180deg); }
        """ : ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light">
        <style>
        html { background: #fff; }
        body { margin: 12px 14px; font: 13px -apple-system, "Helvetica Neue", sans-serif; color: #1d1d1f; overflow-wrap: anywhere; }
        img { max-width: 100%; height: auto; }
        pre { white-space: pre-wrap; }
        \(darkStyle)
        </style></head><body>\(content)</body></html>
        """
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

/// Shown when the add-on in Thunderbird is older than this Phi+ expects.
struct ForkMailAddonUpdateNotice: View {
    @ObservedObject var mail: ForkThunderbirdMail

    var body: some View {
        VStack(spacing: 8) {
            Text(NSLocalizedString("pinnedPreview.mail.update.title", value: "Update the Phi+ Mail Add-on",
                comment: "Thunderbird mail card - title when the Thunderbird add-on is older than Phi+ needs"))
                .font(.system(size: 14, weight: .semibold))
            Text(NSLocalizedString("pinnedPreview.mail.update.detail", value: "Reading mail here needs the newer add-on. Install it the same way: Tools ▸ Add-ons and Themes ▸ gear button ▸ Install Add-on From File.",
                comment: "Thunderbird mail card - explains how to update the Thunderbird add-on"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(NSLocalizedString("pinnedPreview.mail.setup.reveal", value: "Show Add-on File",
                comment: "Thunderbird mail card - button that shows the add-on file in Finder, to install it in Thunderbird"),
                   action: mail.revealAddon)
                .padding(.top, 4)
        }
        .padding(.horizontal, 28)
    }
}

/// The message's HTML in a WebKit view that runs no scripts, opens links in
/// a new Phi+ tab, and shrinks wide messages to fit the card. It always
/// renders in light mode: see `ForkMailReaderView.document(for:dark:)`.
struct ForkMailBodyView: NSViewRepresentable {
    let document: String
    let background: NSColor
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(openLink: openLink) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.appearance = NSAppearance(named: .aqua)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = background
        context.coordinator.load(document, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.openLink = openLink
        webView.underPageBackgroundColor = background
        if context.coordinator.loadedDocument != document {
            context.coordinator.load(document, in: webView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var openLink: (URL) -> Void
        private(set) var loadedDocument: String?

        init(openLink: @escaping (URL) -> Void) { self.openLink = openLink }

        func load(_ document: String, in webView: WKWebView) {
            loadedDocument = document
            webView.pageZoom = 1
            webView.loadHTMLString(document, baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if action.navigationType == .linkActivated || action.targetFrame == nil {
                if url.scheme == "http" || url.scheme == "https" {
                    openLink(url)
                } else if url.scheme == "mailto" {
                    NSWorkspace.shared.open(url)
                }
                return decisionHandler(.cancel)
            }
            // Only the message itself (and its in-page frames) may load.
            decisionHandler(url.scheme == "about" || url.scheme == "data" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, url.scheme == "http" || url.scheme == "https" { openLink(url) }
            return nil
        }

        /// Messages laid out wider than the card (newsletters are often
        /// 600px) are zoomed out to fit, as Apple Mail does.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.scrollWidth") { [weak webView] result, _ in
                MainActor.assumeIsolated {
                    guard let webView, let width = (result as? NSNumber)?.doubleValue,
                          width > webView.bounds.width + 1, webView.bounds.width > 0 else { return }
                    webView.pageZoom = max(0.4, webView.bounds.width / width)
                }
            }
        }
    }
}
