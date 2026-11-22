// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Fork: adds the fork's page scripts (the picture-in-picture button,
/// `ForkVideoPiPButton`, and autoplay control, `ForkAutoplay`) to every page
/// a tab loads, in every frame.
///
/// Phi Framework has no user-script API, so this uses the app's own
/// in-process DevTools sessions (`AppDevToolsPageSession`, as Reader View
/// does), only while a page loads:
/// 1. When a tab starts loading, a session on the tab registers the script
///    for the next document (`Page.addScriptToEvaluateOnNewDocument`), so it
///    runs before the page's own scripts in the page and its same-process
///    frames. That is what lets autoplay control stop media before it starts.
/// 2. When loading ends, the script is run once more (it installs only once
///    per document; this covers a document that committed before step 1
///    finished), embedded players in other processes (cross-origin iframes)
///    get it too, and the session closes. Players added a little later are
///    picked up by one more pass a few seconds on.
/// Nothing stays attached between loads, and no session opens while both
/// features are off.
@MainActor
enum ForkPageScripts {
    // MARK: Tab events (from `Tab` and `PhiChromiumCoordinator`)

    /// A new tab, with how it was opened (a link, typed, restored…).
    static func tabCreated(_ tab: Tab, kind: NativeTabCreationKind) {
        guard kind == .linkForeground || kind == .linkBackground else { return }
        let state = state(for: tab)
        state.openedFromLink = true
        // The tab's first load can start before Phi hears how it was opened:
        // judge that load again and register the script with its decision.
        AppLogDebug("[ForkPageScripts] tab \(tab.guid) opened from a link, loading=\(tab.isLoading), session=\(state.session != nil)")
        if tab.isLoading || state.session != nil, isEnabled {
            state.inheritUntil = nil
            loadStarted(tab)
        }
    }

    /// The tab was unloaded (restored but not yet loaded, or discarded).
    static func tabUnloaded(_ tab: Tab) {
        state(for: tab).wasUnloaded = true
    }

    static func loadingChanged(_ tab: Tab, isLoading: Bool) {
        guard isEnabled else {
            states.removeValue(forKey: tab.guid)?.end()
            return
        }
        if isLoading { loadStarted(tab) } else { loadFinished(tab) }
    }

    // MARK: Per tab

    private final class TabState {
        var openedFromLink = false
        var wasUnloaded = false
        /// How the tab's first loads are judged: a load starting before this
        /// moment (a redirect right after the tab opened) keeps the decision
        /// of the load that opened it.
        var inheritUntil: Date?
        var inheritedPause = false
        /// The current document's decision: whether it starts paused.
        var pausesAutoplay = false
        var session: AppDevToolsPageSession?
        var scriptId: String?
        /// Session work runs one step at a time.
        var tail: Task<Void, Never>?
        var latePass: Task<Void, Never>?

        func enqueue(_ step: @escaping @MainActor () async -> Void) {
            let previous = tail
            tail = Task { @MainActor in
                await previous?.value
                await step()
            }
        }

        func end() {
            latePass?.cancel()
            session?.close()
            session = nil
            scriptId = nil
        }
    }

    private static var states: [Int: TabState] = [:]

    private static func state(for tab: Tab) -> TabState {
        if let existing = states[tab.guid] { return existing }
        let state = TabState()
        states[tab.guid] = state
        return state
    }

    private static var isEnabled: Bool {
        ForkSettings.videoPiPButtonEnabled || ForkSettings.autoplayControlEnabled
    }

    /// Whether the page now loading in `tab` starts with autoplay paused.
    private static func decidePause(for tab: Tab, state: TabState) -> Bool {
        let now = Date()
        if let until = state.inheritUntil, now < until { return state.inheritedPause }
        var pause = false
        if state.openedFromLink, ForkSettings.autoplayPausesLinkTabs { pause = true }
        if state.wasUnloaded, ForkSettings.autoplayPausesRestoredTabs { pause = true }
        if !tab.isActive, ForkSettings.autoplayPausesBackgroundLoads { pause = true }
        let firstOfKind = state.openedFromLink || state.wasUnloaded
        state.openedFromLink = false
        state.wasUnloaded = false
        // Redirects straight after a tab opens or reloads keep its decision.
        state.inheritUntil = firstOfKind ? now.addingTimeInterval(6) : nil
        state.inheritedPause = pause
        return pause
    }

    private static func loadStarted(_ tab: Tab) {
        let state = state(for: tab)
        state.latePass?.cancel()
        state.pausesAutoplay = decidePause(for: tab, state: state)
        let source = script(pausing: state.pausesAutoplay)
        let started = Date()
        state.enqueue { [weak tab] in
            guard let tab, let targetId = tab.webContentWrapper?.devToolsTargetId else { return }
            if state.session == nil {
                state.session = try? await AppDevToolsPageSession.open(targetId: targetId, timeout: 3)
                _ = try? await state.session?.command("Page.enable", timeout: 3)
            }
            guard let session = state.session else { return }
            if let old = state.scriptId {
                _ = try? await session.command("Page.removeScriptToEvaluateOnNewDocument",
                                               params: ["identifier": old], timeout: 3)
                state.scriptId = nil
            }
            let reply = try? await session.command("Page.addScriptToEvaluateOnNewDocument",
                                                   params: ["source": source], timeout: 3)
            state.scriptId = reply?["identifier"] as? String
            AppLogDebug("[ForkPageScripts] tab \(tab.guid) load started, pauses=\(state.pausesAutoplay), "
                + "registered=\(state.scriptId != nil) after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            // Opening the session takes a moment, so a fast page can commit
            // before the script is registered. A page that starts paused
            // doesn't wait for the end of its load: while it loads, the
            // script is run again every quarter second (it installs once per
            // document) and stops anything that has started.
            guard state.pausesAutoplay else { return }
            for _ in 0..<24 {
                guard tab.isLoading, state.session === session else { return }
                _ = try? await session.command("Runtime.evaluate", params: [
                    "expression": source, "returnByValue": true, "silent": true
                ], timeout: 3)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static func loadFinished(_ tab: Tab) {
        let state = state(for: tab)
        let source = script(pausing: state.pausesAutoplay)
        let tabId = tab.guid
        state.enqueue { [weak tab] in
            guard let tab, let targetId = tab.webContentWrapper?.devToolsTargetId else { return }
            let session: AppDevToolsPageSession?
            if let open = state.session {
                session = open
            } else {
                session = try? await AppDevToolsPageSession.open(targetId: targetId, timeout: 3)
            }
            if let session {
                _ = try? await session.command("Runtime.evaluate", params: [
                    "expression": source, "returnByValue": true, "silent": true
                ], timeout: 3)
            }
            session?.close()
            state.session = nil
            state.scriptId = nil
            // Embedded players, outside the tab's queue so the next page's
            // registration never waits behind it.
            Task { @MainActor in
                guard let frameSession = try? await AppDevToolsPageSession.open(targetId: targetId, timeout: 3) else { return }
                await addToEmbeddedFrames(of: targetId, pageSession: frameSession, source: source)
                frameSession.close()
            }
            // Players that arrive after the load (lazy embeds).
            state.latePass = Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, states[tabId] === state else { return }
                guard let session = try? await AppDevToolsPageSession.open(targetId: targetId, timeout: 3) else { return }
                await addToEmbeddedFrames(of: targetId, pageSession: session, source: source)
                session.close()
                // Nothing else pending for the tab: forget it.
                if states[tabId] === state, !state.openedFromLink, !state.wasUnloaded,
                   (state.inheritUntil ?? .distantPast) < Date() {
                    states.removeValue(forKey: tabId)
                }
            }
        }
    }

    /// Runs `source` in the page's cross-origin frames (embedded players),
    /// which live in their own processes and DevTools targets.
    private static func addToEmbeddedFrames(of pageTargetId: String, pageSession: AppDevToolsPageSession,
                                            source: String) async {
        for frameTarget in await embeddedFrameTargets(of: pageTargetId, pageSession: pageSession).prefix(12) {
            guard let session = try? await AppDevToolsPageSession.open(targetId: frameTarget, timeout: 3) else { continue }
            _ = try? await session.command("Runtime.evaluate", params: [
                "expression": source, "returnByValue": true, "silent": true
            ], timeout: 3)
            session.close()
        }
    }

    /// The DevTools targets of the page's cross-origin frames, outermost first.
    private static func embeddedFrameTargets(of pageTargetId: String,
                                             pageSession: AppDevToolsPageSession) async -> [String] {
        guard let tree = try? await pageSession.command("Page.getFrameTree", timeout: 3),
              let browser = try? await AppDevToolsPageSession.openBrowser(timeout: 3) else { return [] }
        defer { browser.close() }
        guard let reply = try? await browser.command("Target.getTargets", timeout: 3),
              let infos = reply["targetInfos"] as? [[String: Any]] else { return [] }
        var frames: Set<String> = [pageTargetId]
        func collect(_ node: [String: Any]) {
            if let id = (node["frame"] as? [String: Any])?["id"] as? String { frames.insert(id) }
            for child in node["childFrames"] as? [[String: Any]] ?? [] { collect(child) }
        }
        if let root = tree["frameTree"] as? [String: Any] { collect(root) }
        // Frames nest; take each level once its parent is known.
        var remaining = infos.filter { ($0["type"] as? String) == "iframe" }
        var embedded: [String] = []
        var grew = true
        while grew {
            grew = false
            remaining.removeAll { info in
                guard let id = info["targetId"] as? String,
                      let parent = info["parentFrameId"] as? String, frames.contains(parent) else { return false }
                frames.insert(id)
                embedded.append(id)
                grew = true
                return true
            }
        }
        return embedded
    }

    // MARK: Picture in picture (the shortcut)

    /// Pops the page's main video out into picture in picture, or puts it
    /// back: the playing one first, then the largest on screen, looking in
    /// shadow DOM and in frames, embedded players included. Run as a user
    /// gesture, which picture in picture needs.
    static func togglePictureInPicture(in tab: Tab) {
        guard let targetId = tab.webContentWrapper?.devToolsTargetId else { return }
        Task { @MainActor in
            guard let session = try? await AppDevToolsPageSession.open(targetId: targetId, timeout: 3) else { return }
            defer { session.close() }
            if try await run(togglePictureInPictureScript, on: session) != "none" { return }
            // No video in the page itself: try its embedded players.
            for frameTarget in await embeddedFrameTargets(of: targetId, pageSession: session).prefix(12) {
                guard let frameSession = try? await AppDevToolsPageSession.open(targetId: frameTarget, timeout: 3) else { continue }
                let result = try? await run(togglePictureInPictureScript, on: frameSession)
                frameSession.close()
                if let result, result != "none" { return }
            }
        }
    }

    private static func run(_ script: String, on session: AppDevToolsPageSession) async throws -> String? {
        let reply = try await session.command("Runtime.evaluate", params: [
            "expression": script, "returnByValue": true, "awaitPromise": true, "userGesture": true, "silent": true
        ], timeout: 5)
        return (reply["result"] as? [String: Any])?["value"] as? String
    }

    private static let togglePictureInPictureScript = """
    (async () => {
      try {
        if (document.pictureInPictureElement) { await document.exitPictureInPicture(); return 'exited'; }
        const videos = [...document.querySelectorAll('video')];
        const shadow = window[Symbol.for('phiPlus.shadowRoots')];
        if (shadow) for (const root of shadow.roots()) videos.push(...root.querySelectorAll('video'));
        for (const frame of document.querySelectorAll('iframe')) {
          try { if (frame.contentDocument) videos.push(...frame.contentDocument.querySelectorAll('video')); } catch (_) {}
        }
        const score = (v) => {
          const r = v.getBoundingClientRect();
          return (v.paused ? 0 : 1e9) + (v.readyState > 0 ? 1e8 : 0) + Math.max(0, r.width) * Math.max(0, r.height);
        };
        const best = videos.filter((v) => v.readyState > 0 || v.currentSrc || v.srcObject).sort((a, b) => score(b) - score(a))[0];
        if (!best) return 'none';
        best.disablePictureInPicture = false;
        best.removeAttribute('disablepictureinpicture');
        await best.requestPictureInPicture();
        return 'entered';
      } catch (e) { return 'failed: ' + e.message; }
    })()
    """

    // MARK: Live changes (the autoplay menus)

    /// Runs `expression` in the tab's page and returns its value.
    static func evaluate(_ expression: String, in tab: Tab) async -> Any? {
        guard let targetId = tab.webContentWrapper?.devToolsTargetId,
              let session = try? await AppDevToolsPageSession.open(targetId: targetId, timeout: 3) else { return nil }
        defer { session.close() }
        let reply = try? await session.command("Runtime.evaluate", params: [
            "expression": expression, "returnByValue": true, "silent": true
        ], timeout: 3)
        return (reply?["result"] as? [String: Any])?["value"]
    }

    // MARK: The script

    /// The scripts the settings ask for, behind the shadow-root registry
    /// they share.
    private static func script(pausing: Bool) -> String {
        var parts = [shadowRegistry]
        if ForkSettings.autoplayControlEnabled { parts.append(ForkAutoplay.script(pausing: pausing)) }
        if ForkSettings.videoPiPButtonEnabled { parts.append(ForkVideoPiPButton.script) }
        return parts.joined(separator: "\n")
    }

    /// Keeps track of every shadow root the page makes (open or closed), so
    /// the scripts can reach media inside web components, where neither
    /// `querySelectorAll` nor a media element's events reach from the
    /// document.
    private static let shadowRegistry = """
    (() => {
      const KEY = Symbol.for('phiPlus.shadowRoots');
      if (window[KEY]) return;
      const refs = new Set(), watchers = new Set();
      const roots = () => {
        const out = [];
        for (const ref of refs) { const root = ref.deref(); if (root) out.push(root); else refs.delete(ref); }
        return out;
      };
      window[KEY] = { roots, onRoot: (fn) => { watchers.add(fn); for (const root of roots()) fn(root); } };
      const native = Element.prototype.attachShadow;
      Element.prototype.attachShadow = function (init) {
        const root = native.call(this, init);
        refs.add(new WeakRef(root));
        for (const fn of watchers) { try { fn(root); } catch (_) {} }
        return root;
      };
    })();
    """
}
