// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import NaturalLanguage
import SwiftUI

/// Fork: select text that isn't English and a chip under it translates it
/// into English with DeepL (`ForkSelectionTranslateScript` is the page
/// half, `ForkDeepLClient` the DeepL half). `ForkSettings.selectionTranslateEnabled`.
///
/// The selected tab of each window keeps one app-owned DevTools session
/// (`AppDevToolsPageSession`) with a binding the page script calls. Other
/// tabs have none: text can only be selected in a tab you're looking at.
///
/// Recognising a selection's language happens on this Mac
/// (`NLLanguageRecognizer`), so only text you ask to translate goes to
/// DeepL. Translating, copying and opening Settings answer only to a click
/// the app has just seen, so a page can't spend your DeepL allowance or
/// write to your clipboard by calling the binding itself.
@MainActor
enum ForkSelectionTranslate {
    // MARK: Tabs (from `Tab`)

    /// The tab became or stopped being its window's selected tab, or
    /// finished loading (a reloaded, discarded tab has a new target).
    static func tabActivityChanged(_ tab: Tab) {
        if tab.isActive {
            selectedTabs[tab.guid] = WeakTab(tab: tab)
            if ForkSettings.selectionTranslateEnabled { attach(tab) }
        } else {
            selectedTabs.removeValue(forKey: tab.guid)
            detach(tab.guid)
        }
    }

    /// The setting changed.
    static func enabledChanged() {
        if ForkSettings.selectionTranslateEnabled {
            installClickMonitor()
            for case let tab? in selectedTabs.values.map(\.tab) where tab.isActive { attach(tab) }
        } else {
            for id in Array(attachments.keys) { detach(id) }
        }
    }

    private struct WeakTab { weak var tab: Tab? }
    private static var selectedTabs: [Int: WeakTab] = [:]

    // MARK: Sessions

    private final class Attachment {
        var session: AppDevToolsPageSession?
        var targetId: String?
        private var tail: Task<Void, Never>?

        /// Session commands run one at a time.
        func enqueue(_ step: @escaping @MainActor () async -> Void) {
            let previous = tail
            tail = Task { @MainActor in
                await previous?.value
                await step()
            }
        }
    }

    private static var attachments: [Int: Attachment] = [:]

    private static func attach(_ tab: Tab) {
        guard let targetId = tab.webContentWrapper?.devToolsTargetId else { return }
        if let existing = attachments[tab.guid] {
            // Still on the same page target: give the new page the binding
            // (DevTools adds it only to documents that exist when it's added)
            // and the script (it installs once per document).
            if existing.targetId == targetId {
                existing.enqueue {
                    guard let session = existing.session else { return }
                    let name = ForkSelectionTranslateScript.bindingName
                    _ = try? await session.command("Runtime.removeBinding", params: ["name": name], timeout: 3)
                    _ = try? await session.command("Runtime.addBinding", params: ["name": name], timeout: 3)
                    _ = try? await session.command("Runtime.evaluate", params: [
                        "expression": ForkSelectionTranslateScript.source, "returnByValue": true, "silent": true
                    ], timeout: 3)
                }
                return
            }
            detach(tab.guid)
        }
        installClickMonitor()
        let tabId = tab.guid
        let attachment = Attachment()
        attachment.targetId = targetId
        attachments[tabId] = attachment
        attachment.enqueue {
            guard let session = try? await AppDevToolsPageSession.open(targetId: targetId, timeout: 3) else {
                if attachments[tabId] === attachment { attachments[tabId] = nil }
                return
            }
            guard attachments[tabId] === attachment else { session.close(); return }
            attachment.session = session
            session.observe(onEvent: { [weak attachment] method, params in
                guard let attachment, method == "Runtime.bindingCalled",
                      params["name"] as? String == ForkSelectionTranslateScript.bindingName,
                      let payload = params["payload"] as? String else { return }
                handle(payload, contextId: params["executionContextId"] as? Int, in: attachment)
            }, onClose: { [weak attachment] in
                guard let attachment, attachments[tabId] === attachment else { return }
                attachments[tabId] = nil
            })
            let source = ForkSelectionTranslateScript.source
            _ = try? await session.command("Runtime.addBinding",
                                           params: ["name": ForkSelectionTranslateScript.bindingName], timeout: 3)
            _ = try? await session.command("Page.addScriptToEvaluateOnNewDocument",
                                           params: ["source": source], timeout: 3)
            _ = try? await session.command("Runtime.evaluate", params: [
                "expression": source, "returnByValue": true, "silent": true
            ], timeout: 3)
            AppLogDebug("[ForkSelectionTranslate] attached to tab \(tabId)")
        }
    }

    /// Closing the session also removes its binding and page script.
    private static func detach(_ tabId: Int) {
        guard let attachment = attachments.removeValue(forKey: tabId) else { return }
        attachment.enqueue { attachment.session?.close() }
    }

    // MARK: Messages from the page

    private static func handle(_ payload: String, contextId: Int?, in attachment: Attachment) {
        guard payload.utf8.count < 64_000,
              let data = payload.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = message["op"] as? String,
              let id = message["id"] as? Int else { return }
        let text = (message["text"] as? String) ?? ""
        let reply: ([String: Any]) -> Void = { body in
            var body = body
            body["id"] = id
            deliver(body, contextId: contextId, in: attachment)
        }

        switch op {
        case "detect":
            guard let language = foreignLanguage(of: text) else { return }
            reply(["op": "offer", "lang": language.rawValue, "name": displayName(of: language.rawValue) ?? ""])
        case "translate":
            guard userJustClicked, !text.isEmpty, text.count <= 5000 else { return }
            Task { @MainActor in
                do {
                    let result = try await ForkDeepLClient.translate(text, target: ForkSettings.translateEnglishVariant)
                    reply(["op": "result", "text": result.text,
                           "name": result.sourceLanguage.flatMap(displayName(of:)) ?? ""])
                } catch {
                    let failure = error as? ForkDeepLClient.Failure ?? .failed(0)
                    reply(["op": "error", "message": failure.message, "settings": failure.opensSettings])
                }
            }
        case "copy":
            guard userJustClicked, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "settings":
            guard userJustClicked else { return }
            ForkAutoplay.openSettings(anchor: settingsAnchor)
        default:
            break
        }
    }

    private static func deliver(_ body: [String: Any], contextId: Int?, in attachment: Attachment) {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else { return }
        var params: [String: Any] = [
            "expression": "window[Symbol.for('phiPlus.translate')]?.deliver(\(json))",
            "silent": true
        ]
        if let contextId { params["contextId"] = contextId }
        attachment.enqueue {
            _ = try? await attachment.session?.command("Runtime.evaluate", params: params, timeout: 3)
        }
    }

    // MARK: Language

    /// The selection's language when it's confidently not English.
    static func foreignLanguage(of text: String) -> NLLanguage? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 2 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let (best, confidence) = hypotheses.max(by: { $0.value < $1.value }),
              best != .english, best != .undetermined else { return nil }
        // Short selections are easy to misjudge: ask for more certainty.
        let needed = letters < 12 ? 0.8 : letters < 40 ? 0.65 : 0.5
        guard confidence >= needed, (hypotheses[.english] ?? 0) < 0.25 else { return nil }
        return best
    }

    /// "French" for "fr" or DeepL's "FR"; "Chinese" for "zh-Hans".
    static func displayName(of code: String) -> String? {
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? code
        return Locale.current.localizedString(forLanguageCode: base)
    }

    // MARK: Clicks

    /// The last mouse click in Phi+. A page script can't fake one.
    private static var lastClick = Date.distantPast
    private static var clickMonitor: Any?

    private static var userJustClicked: Bool { Date().timeIntervalSince(lastClick) < 2 }

    private static func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            lastClick = Date()
            return event
        }
    }

    // MARK: Settings

    static let settingsAnchor = "fork.translate.settings"
}

// MARK: - Settings

/// Settings → General → Translate.
struct ForkSelectionTranslateSettingsSection: View {
    @AppStorage(ForkSettings.Key.selectionTranslateEnabled) private var isEnabled = true
    @AppStorage(ForkSettings.Key.translateEnglishVariant) private var variant = "EN-GB"
    @State private var hasKey = ForkDeepLClient.hasKey
    @State private var keyDraft = ""
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("settings.translate.sectionTitle", value: "Translate",
            comment: "General settings - Translate section title")) {
            GeneralContainerView {
                ForkToggleRow(
                    title: NSLocalizedString("settings.translate.enabled.title", value: "Translate selected text",
                        comment: "Translate settings - master switch"),
                    description: NSLocalizedString("settings.translate.enabled.description", value: "Select text that isn't in English and a button under it translates it with DeepL. The language is recognised on your Mac: only text you translate goes to DeepL.",
                        comment: "Translate settings - description of the master switch"),
                    isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, _ in ForkSelectionTranslate.enabledChanged() }
                if isEnabled {
                    Divider()
                    keyRow
                    Divider()
                    HStack {
                        Text(NSLocalizedString("settings.translate.variant.title", value: "Translate into",
                            comment: "Translate settings - which English to translate into"))
                            .font(.system(size: 13))
                            .themedForeground(.textPrimary)
                        Spacer()
                        Picker("", selection: $variant) {
                            Text(NSLocalizedString("settings.translate.variant.british", value: "British English",
                                comment: "Translate settings - British English option")).tag("EN-GB")
                            Text(NSLocalizedString("settings.translate.variant.american", value: "American English",
                                comment: "Translate settings - American English option")).tag("EN-US")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(NSLocalizedString("settings.translate.key.title", value: "DeepL API key",
                    comment: "Translate settings - DeepL API key row title"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Spacer()
                if hasKey {
                    Text(maskedKey)
                        .font(.system(size: 12, design: .monospaced))
                        .themedForeground(.textSecondary)
                    Button(NSLocalizedString("settings.translate.key.remove", value: "Remove",
                        comment: "Translate settings - removes the saved DeepL API key")) {
                        ForkDeepLClient.deleteKey()
                        hasKey = false
                        status = nil
                    }
                    .controlSize(.small)
                } else {
                    SecureField(NSLocalizedString("settings.translate.key.placeholder", value: "Paste your key",
                        comment: "Translate settings - placeholder of the DeepL API key field"), text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 220)
                        .onSubmit(saveKey)
                    Button(NSLocalizedString("settings.translate.key.save", value: "Save",
                        comment: "Translate settings - saves the DeepL API key")) { saveKey() }
                        .controlSize(.small)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
                }
            }
            HStack(spacing: 4) {
                Text(status ?? NSLocalizedString("settings.translate.key.description", value: "A free DeepL API key translates 500,000 characters a month. It's kept on this Mac.",
                    comment: "Translate settings - description under the DeepL API key"))
                    .font(.system(size: 11))
                    .themedForeground(.textSecondary)
                if !hasKey {
                    Link(NSLocalizedString("settings.translate.key.get", value: "Get a key",
                        comment: "Translate settings - link to DeepL's API sign-up page"),
                         destination: URL(string: "https://www.deepl.com/pro-api")!)
                        .font(.system(size: 11))
                }
            }
        }
        .padding(.vertical, 2)
        .task(id: hasKey) { await refreshUsage() }
    }

    private var maskedKey: String {
        guard let key = ForkDeepLClient.readKey() else { return "" }
        return "••••" + key.suffix(key.hasSuffix(":fx") ? 7 : 4)
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !checking else { return }
        checking = true
        status = NSLocalizedString("settings.translate.key.checking", value: "Checking the key…",
            comment: "Translate settings - checking a newly entered DeepL API key")
        Task { @MainActor in
            defer { checking = false }
            do {
                _ = try await ForkDeepLClient.usage(key: key)
                ForkDeepLClient.writeKey(key)
                keyDraft = ""
                hasKey = true
            } catch {
                status = (error as? ForkDeepLClient.Failure ?? .failed(0)).message
            }
        }
    }

    private func refreshUsage() async {
        guard hasKey, let key = ForkDeepLClient.readKey(),
              let usage = try? await ForkDeepLClient.usage(key: key), usage.limit > 0 else { return }
        let format = NSLocalizedString("settings.translate.key.usage", value: "%@ of %@ characters used this month.",
            comment: "Translate settings - DeepL usage, e.g. 1,234 of 500,000 characters used this month")
        status = String(format: format, usage.used.formatted(), usage.limit.formatted())
    }
}
