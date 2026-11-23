// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Fork: autoplay control. A page can start "paused": its audio and video
/// can't start on their own until the user starts them. Which pages start
/// paused is decided as each page begins to load (`ForkPageScripts`), from
/// how its tab got there (settings in `ForkSettings`):
/// - opened from a link into a new tab, in the background or not;
/// - an unloaded tab (restored, discarded) loading again, selected or not;
/// - loading while its tab isn't the selected one.
/// A page loaded in the selected tab some other way (following a link,
/// typing an address) plays as usual. Sites can be excluded from the rules
/// (always allow) or always start paused.
///
/// Starting media yourself always works: playback the page starts in
/// response to a click or key press (its play button, Space) goes through,
/// and by default any click or key press on the page lets it play from then
/// on (the browser's own sticky user activation). Muted media may play
/// unless the user turns that off; media that unmutes itself is paused.
///
/// In the page, `HTMLMediaElement.play()` refuses with the browser's own
/// autoplay error (`NotAllowedError`), which players already handle by
/// showing their play button, and media that starts any other way (the
/// `autoplay` attribute) is paused as it starts, in the document and in
/// shadow DOM. Every frame gets the script, embedded players included.
@MainActor
enum ForkAutoplay {
    // MARK: Page script

    static func script(pausing: Bool) -> String {
        let rules = ForkSettings.autoplaySiteRules
        let config: [String: Any] = [
            "pause": pausing,
            "allowMuted": ForkSettings.autoplayAllowsMuted,
            "unlock": ForkSettings.autoplayUnlocksOnInteraction,
            "allowSites": rules.filter { $0.value == .allow }.map(\.key),
            "pauseSites": rules.filter { $0.value == .pause }.map(\.key)
        ]
        let json = (try? JSONSerialization.data(withJSONObject: config))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return pageScript.replacingOccurrences(of: "__CONFIG__", with: json)
    }

    private static let pageScript = """
    (() => {
      if (!/^https?:$/.test(location.protocol)) return;
      const KEY = Symbol.for('phiPlus.autoplay');
      // Run again on a page that has it (each load event, the polling while
      // a paused page loads): a page that started paused stays paused. A
      // later load of the same page (YouTube's own loads, in-page
      // navigation) is judged as the selected tab and would otherwise let
      // it play; only the user (playing, or allowing the site) lifts it.
      if (window[KEY]) { window[KEY].rerun(__CONFIG__); return; }
      let cfg = __CONFIG__;
      const host = location.hostname.replace(/^www\\./, '');
      const listed = (list) => (list || []).some((site) => host === site || host.endsWith('.' + site));
      const guarded = () => !listed(cfg.allowSites) && (cfg.pause || listed(cfg.pauseSites));
      let guard = guarded();
      const activation = navigator.userActivation;
      // Started by the user: a click or key press just now (a play button,
      // Space), or, by default, any time on this page before.
      const byUser = () => !!activation && (activation.isActive || (cfg.unlock && activation.hasBeenActive));
      const audible = (m) => !m.muted && m.volume > 0;
      const allowed = (m) => !guard || byUser() || (cfg.allowMuted && !audible(m));
      const held = new Set();
      const proto = HTMLMediaElement.prototype;
      const nativePlay = proto.play, nativePause = proto.pause;
      proto.play = function () {
        if (allowed(this)) return nativePlay.apply(this, arguments);
        held.add(this);
        return Promise.reject(new DOMException('Autoplay is paused by Phi+.', 'NotAllowedError'));
      };
      const stop = (e) => {
        const m = e.target;
        if (!(m instanceof HTMLMediaElement) || m.paused || allowed(m)) return;
        held.add(m);
        nativePause.call(m);
      };
      // Media events don't bubble or leave shadow DOM: listen while they
      // capture, on the window and on every shadow root.
      const watch = (root) => {
        for (const type of ['play', 'playing', 'volumechange']) root.addEventListener(type, stop, true);
      };
      watch(window);
      const shadow = window[Symbol.for('phiPlus.shadowRoots')];
      if (shadow) shadow.onRoot(watch);
      const resume = () => {
        for (const m of held) {
          const r = m.isConnected && m.getBoundingClientRect();
          if (m.paused && r && (r.width > 0 || m instanceof HTMLAudioElement)) nativePlay.call(m).catch(() => {});
        }
        held.clear();
      };
      // Added late (the page committed before the script was registered):
      // stop what already started on its own.
      const stopPlaying = () => {
        if (!guard) return;
        const media = [...document.querySelectorAll('video, audio')];
        if (shadow) for (const root of shadow.roots()) media.push(...root.querySelectorAll('video, audio'));
        for (const m of media) if (!m.paused && !allowed(m)) { held.add(m); nativePause.call(m); }
      };
      if (document.readyState !== 'loading') stopPlaying();
      else document.addEventListener('DOMContentLoaded', stopPlaying, { once: true });
      window[KEY] = {
        update(next) { cfg = Object.assign({}, cfg, next); guard = guarded(); if (!guard) resume(); },
        rerun(next) { this.update(Object.assign({}, next, { pause: cfg.pause || next.pause })); },
        playHeld() { resume(); },
        status() {
          return { guard, held: [...held].filter((m) => m.isConnected && m.paused).length };
        }
      };
    })();
    """

    // MARK: Sites

    /// The site a page belongs to, as autoplay rules name it.
    static func site(of urlString: String?) -> String? {
        guard let host = urlString.flatMap(URL.init(string:))?.host?.lowercased(),
              let scheme = urlString.flatMap(URL.init(string:))?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The rule that applies to `site` (its own or a parent domain's).
    static func rule(for site: String) -> AutoplaySiteRule? {
        let rules = ForkSettings.autoplaySiteRules
        var candidate = site
        while true {
            if let rule = rules[candidate] { return rule }
            guard let dot = candidate.firstIndex(of: ".") else { return nil }
            candidate = String(candidate[candidate.index(after: dot)...])
            if !candidate.contains(".") { return nil }
        }
    }

    /// Sets (or clears, with nil) `site`'s rule, and applies it to the open
    /// page in `tab` at once.
    static func setRule(_ rule: AutoplaySiteRule?, for site: String, applyingTo tab: Tab?) {
        var rules = ForkSettings.autoplaySiteRules
        rules[site] = rule
        ForkSettings.autoplaySiteRules = rules
        guard let tab else { return }
        let all = ForkSettings.autoplaySiteRules
        let patch: [String: Any] = [
            "allowSites": all.filter { $0.value == .allow }.map(\.key),
            "pauseSites": all.filter { $0.value == .pause }.map(\.key)
        ]
        guard let json = (try? JSONSerialization.data(withJSONObject: patch)).flatMap({ String(data: $0, encoding: .utf8) }) else { return }
        Task { _ = await ForkPageScripts.evaluate("window[Symbol.for('phiPlus.autoplay')]?.update(\(json))", in: tab) }
    }

    struct PageStatus: Equatable {
        /// The page's media can't start on its own.
        var isPaused: Bool
        /// Media the page tried to start and was stopped.
        var heldCount: Int
    }

    static func status(of tab: Tab) async -> PageStatus? {
        guard let value = await ForkPageScripts.evaluate(
            "window[Symbol.for('phiPlus.autoplay')]?.status() ?? null", in: tab) as? [String: Any] else { return nil }
        return PageStatus(isPaused: value["guard"] as? Bool ?? false, heldCount: value["held"] as? Int ?? 0)
    }

    /// Plays what the page was stopped from playing.
    static func playHeldMedia(in tab: Tab) {
        Task { _ = await ForkPageScripts.evaluate("window[Symbol.for('phiPlus.autoplay')]?.playHeld()", in: tab) }
    }

    /// Opens Settings → General scrolled to the Autoplay section.
    static func openSettings() {
        wantsSettingsScroll = true
        _ = AppController.shared?.showSettings(pane: .general)
        // Already open: it scrolls on this; opening: on appearing.
        NotificationCenter.default.post(name: showSettingsNotification, object: nil)
    }

    static let settingsAnchor = "fork.autoplay.settings"
    static let showSettingsNotification = Notification.Name("ForkAutoplayShowSettings")
    private static var wantsSettingsScroll = false

    static func scrollToSettingsIfAsked(_ proxy: ScrollViewProxy) {
        guard wantsSettingsScroll else { return }
        wantsSettingsScroll = false
        // After the pane has laid out.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(settingsAnchor, anchor: .top) }
        }
    }

    // MARK: Address bar button menu

    /// The menu of the sidebar address bar's Autoplay button.
    static func menu(for tab: Tab?, status: PageStatus?) -> NSMenu {
        let menu = NSMenu()
        let site = site(of: tab?.url)
        let enabled = ForkSettings.autoplayControlEnabled
        let header = NSMenuItem(title: site.map {
            String(format: NSLocalizedString("autoplay.menu.siteTitle", value: "Autoplay on %@",
                comment: "Autoplay menu - title naming the current site; %@ is the site"), $0)
        } ?? NSLocalizedString("autoplay.menu.title", value: "Autoplay", comment: "Autoplay menu - title"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let site, enabled {
            let current = rule(for: site)
            let options: [(AutoplaySiteRule?, String)] = [
                (nil, NSLocalizedString("autoplay.menu.useRules", value: "Follow Autoplay Rules",
                    comment: "Autoplay menu - the site follows the tab rules")),
                (.allow, AutoplaySiteRule.allow.displayName),
                (.pause, AutoplaySiteRule.pause.displayName)
            ]
            for (rule, title) in options {
                let item = ClosureMenuItem(title: title) { setRule(rule, for: site, applyingTo: tab) }
                item.state = current == rule ? .on : .off
                menu.addItem(item)
            }
            if let tab, let status, status.heldCount > 0 {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: NSLocalizedString("autoplay.menu.playHeld", value: "Play Paused Media",
                    comment: "Autoplay menu - plays the media this page was kept from playing")) { playHeldMedia(in: tab) })
            }
        }
        menu.addItem(.separator())
        let toggle = ClosureMenuItem(title: NSLocalizedString("autoplay.menu.control", value: "Autoplay Control",
            comment: "Autoplay menu - turns autoplay control on or off")) {
            UserDefaults.standard.set(!ForkSettings.autoplayControlEnabled, forKey: ForkSettings.Key.autoplayControlEnabled)
        }
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(ClosureMenuItem(title: NSLocalizedString("autoplay.menu.settings", value: "Autoplay Settings…",
            comment: "Autoplay menu - opens the autoplay settings"), action: openSettings))
        return menu
    }

    /// A menu item that runs a closure. A plain `NSMenuItem` whose target
    /// holds the closure: AppKit copies menu items (Phi's shortcut display
    /// does), which a subclass with its own initializer can't survive.
    private static func ClosureMenuItem(title: String, action handler: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureTarget(handler)
        let item = NSMenuItem(title: title, action: #selector(ClosureTarget.run), keyEquivalent: "")
        item.target = target
        // The item keeps its target alive (`target` is weak).
        item.representedObject = target
        return item
    }

    private final class ClosureTarget: NSObject {
        private let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func run() { handler() }
    }
}

// MARK: - Extensions menu section

/// The Autoplay section of the address bar's extensions menu: what autoplay
/// does on the current page, this site's rule, and the settings.
struct ForkAutoplayMenuSection: View {
    let tab: Tab?
    let onRequestDismiss: (() -> Void)?
    @AppStorage(ForkSettings.Key.autoplayControlEnabled) private var isEnabled = true
    @State private var status: ForkAutoplay.PageStatus?
    @State private var siteRule: AutoplaySiteRule?
    @State private var isHovered = false

    private var site: String? { ForkAutoplay.site(of: tab?.url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("autoplay.section.title", value: "Autoplay", comment: "Extensions menu - Autoplay section title"))
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary)
                .padding(.horizontal, 12)
            Group {
                statusRow
                if isEnabled, let site {
                    siteRow(site)
                }
                controlRow
                settingsRow
            }
            .padding(.horizontal, 8)
        }
        .task(id: tab?.url) { await refresh() }
    }

    private var statusRow: some View {
        HStack(spacing: 4) {
            Image(systemName: statusSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .center)
            Text(statusText)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let tab, let status, status.heldCount > 0 {
                Button(NSLocalizedString("autoplay.section.play", value: "Play",
                    comment: "Extensions menu - plays the media this page was kept from playing")) {
                    ForkAutoplay.playHeldMedia(in: tab)
                    onRequestDismiss?()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 4)
    }

    private var statusSymbol: String {
        guard isEnabled else { return "play" }
        return status?.isPaused == true ? "play.slash" : "play"
    }

    private var statusText: String {
        guard isEnabled else {
            return NSLocalizedString("autoplay.section.off", value: "Autoplay control is off",
                comment: "Extensions menu - autoplay control is turned off")
        }
        if let status, status.isPaused {
            if status.heldCount > 0 {
                return String(format: NSLocalizedString("autoplay.section.held", value: "Paused %d on this page",
                    comment: "Extensions menu - how many media items this page was kept from playing; %d is the number"), status.heldCount)
            }
            return NSLocalizedString("autoplay.section.paused", value: "Paused on this page",
                comment: "Extensions menu - this page's media can't start on its own")
        }
        return NSLocalizedString("autoplay.section.allowed", value: "Plays on this page",
            comment: "Extensions menu - this page's media may start on its own")
    }

    private func siteRow(_ site: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .center)
            Text(site)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Picker("", selection: Binding(get: { siteRule }, set: { rule in
                siteRule = rule
                ForkAutoplay.setRule(rule, for: site, applyingTo: tab)
                Task { try? await Task.sleep(for: .milliseconds(150)); await refresh() }
            })) {
                Text(NSLocalizedString("autoplay.section.rules", value: "Rules",
                    comment: "Extensions menu - the site follows the autoplay rules")).tag(AutoplaySiteRule?.none)
                Text(NSLocalizedString("autoplay.section.allow", value: "Allow",
                    comment: "Extensions menu - the site may always autoplay")).tag(AutoplaySiteRule?.some(.allow))
                Text(NSLocalizedString("autoplay.section.pause", value: "Pause",
                    comment: "Extensions menu - the site always starts paused")).tag(AutoplaySiteRule?.some(.pause))
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
        .frame(height: 22)
        .padding(.horizontal, 4)
    }

    private var controlRow: some View {
        HStack(spacing: 4) {
            Text(NSLocalizedString("autoplay.section.control", value: "Autoplay control",
                comment: "Extensions menu - switch that turns autoplay control on or off"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .frame(height: 22)
        .padding(.horizontal, 4)
    }

    private var settingsRow: some View {
        Button {
            onRequestDismiss?()
            ForkAutoplay.openSettings()
        } label: {
            HStack(spacing: 4) {
                Text(NSLocalizedString("autoplay.section.settings", value: "Autoplay Settings",
                    comment: "Extensions menu - opens the autoplay settings"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .frame(height: 22)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Color.gray.opacity(0.1) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovered = $0 }
    }

    private func refresh() async {
        siteRule = site.flatMap(ForkAutoplay.rule(for:))
        guard let tab, isEnabled else { status = nil; return }
        status = await ForkAutoplay.status(of: tab)
    }
}

// MARK: - Settings

/// Settings → General → Autoplay.
struct ForkAutoplaySettingsSection: View {
    @AppStorage(ForkSettings.Key.autoplayControlEnabled) private var isEnabled = true
    @AppStorage(ForkSettings.Key.autoplayPausesLinkTabs) private var pausesLinkTabs = true
    @AppStorage(ForkSettings.Key.autoplayPausesRestoredTabs) private var pausesRestoredTabs = true
    @AppStorage(ForkSettings.Key.autoplayPausesBackgroundLoads) private var pausesBackgroundLoads = true
    @AppStorage(ForkSettings.Key.autoplayAllowsMuted) private var allowsMuted = true
    @AppStorage(ForkSettings.Key.autoplayUnlocksOnInteraction) private var unlocksOnInteraction = true
    @State private var rules: [(site: String, rule: AutoplaySiteRule)] = []
    @State private var newSite = ""
    @State private var newRule: AutoplaySiteRule = .allow

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("settings.autoplay.sectionTitle", value: "Autoplay",
            comment: "General settings - Autoplay section title")) {
            GeneralContainerView {
                ForkToggleRow(
                    title: NSLocalizedString("settings.autoplay.enabled.title", value: "Autoplay control",
                        comment: "Autoplay settings - master switch"),
                    description: NSLocalizedString("settings.autoplay.enabled.description", value: "Keep pages from starting video and audio on their own. Clicking play or pressing Space always works.",
                        comment: "Autoplay settings - description of the master switch"),
                    isOn: $isEnabled)
                if isEnabled {
                    Divider()
                    ForkToggleRow(
                        title: NSLocalizedString("settings.autoplay.linkTabs.title", value: "Pause in tabs opened from links",
                            comment: "Autoplay settings - rule for tabs opened from a link"),
                        description: NSLocalizedString("settings.autoplay.linkTabs.description", value: "A link opened in a new tab, in the background or not, starts paused.",
                            comment: "Autoplay settings - description of the link-tab rule"),
                        isOn: $pausesLinkTabs)
                    Divider()
                    ForkToggleRow(
                        title: NSLocalizedString("settings.autoplay.restoredTabs.title", value: "Pause in unloaded tabs",
                            comment: "Autoplay settings - rule for unloaded (restored or discarded) tabs"),
                        description: NSLocalizedString("settings.autoplay.restoredTabs.description", value: "A restored or unloaded tab starts paused when it loads again, even when you select it.",
                            comment: "Autoplay settings - description of the unloaded-tab rule"),
                        isOn: $pausesRestoredTabs)
                    Divider()
                    ForkToggleRow(
                        title: NSLocalizedString("settings.autoplay.backgroundLoads.title", value: "Pause pages that load in the background",
                            comment: "Autoplay settings - rule for pages loading in a tab that isn't selected"),
                        description: NSLocalizedString("settings.autoplay.backgroundLoads.description", value: "A page that loads while its tab isn't selected starts paused. Pages you open in the selected tab play as usual.",
                            comment: "Autoplay settings - description of the background-load rule"),
                        isOn: $pausesBackgroundLoads)
                    Divider()
                    ForkToggleRow(
                        title: NSLocalizedString("settings.autoplay.muted.title", value: "Let muted videos play",
                            comment: "Autoplay settings - muted media may still autoplay"),
                        description: NSLocalizedString("settings.autoplay.muted.description", value: "Silent previews and backgrounds keep playing. A video that unmutes itself is paused.",
                            comment: "Autoplay settings - description of the muted-media option"),
                        isOn: $allowsMuted)
                    Divider()
                    ForkToggleRow(
                        title: NSLocalizedString("settings.autoplay.unlock.title", value: "Allow after you use the page",
                            comment: "Autoplay settings - a click or key press on the page lets it play"),
                        description: NSLocalizedString("settings.autoplay.unlock.description", value: "After a click or key press on a paused page, it plays as usual, such as the next video in a playlist.",
                            comment: "Autoplay settings - description of the unlock-on-interaction option"),
                        isOn: $unlocksOnInteraction)
                    Divider()
                    siteRules
                }
            }
        }
        .onAppear(perform: loadRules)
    }

    private var siteRules: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("settings.autoplay.sites.title", value: "Sites", comment: "Autoplay settings - site rules title"))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
            Text(NSLocalizedString("settings.autoplay.sites.description", value: "Sites here don't follow the rules above. Subdomains are included.",
                comment: "Autoplay settings - site rules description"))
                .font(.system(size: 11))
                .themedForeground(.textSecondary)
            ForEach(rules, id: \.site) { entry in
                HStack(spacing: 8) {
                    Text(entry.site)
                        .font(.system(size: 12))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Picker("", selection: Binding(get: { entry.rule }, set: { rule in
                        ForkAutoplay.setRule(rule, for: entry.site, applyingTo: nil)
                        loadRules()
                    })) {
                        ForEach(AutoplaySiteRule.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    Button {
                        ForkAutoplay.setRule(nil, for: entry.site, applyingTo: nil)
                        loadRules()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(NSLocalizedString("settings.autoplay.sites.remove", value: "Remove", comment: "Autoplay settings - removes a site rule"))
                }
            }
            HStack(spacing: 8) {
                TextField(NSLocalizedString("settings.autoplay.sites.placeholder", value: "example.com", comment: "Autoplay settings - placeholder for a new site"),
                          text: $newSite)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(addSite)
                Picker("", selection: $newRule) {
                    ForEach(AutoplaySiteRule.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                Button(NSLocalizedString("settings.autoplay.sites.add", value: "Add", comment: "Autoplay settings - adds a site rule"), action: addSite)
                    .controlSize(.small)
                    .disabled(Self.normalized(newSite) == nil)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadRules() {
        rules = ForkSettings.autoplaySiteRules.map { ($0.key, $0.value) }.sorted { $0.site < $1.site }
    }

    private func addSite() {
        guard let site = Self.normalized(newSite) else { return }
        ForkAutoplay.setRule(newRule, for: site, applyingTo: nil)
        newSite = ""
        loadRules()
    }

    /// "https://www.Example.com/x" → "example.com".
    static func normalized(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://" + value }
        guard var host = URL(string: value)?.host, host.contains(".") else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
