// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Fork: brings the last session back after a crash or a forced quit.
///
/// Chromium marks a profile "Crashed" (`profile.exit_type` in its
/// Preferences) while it runs and "Normal" when it exits cleanly. Starting
/// after a crash, it skips restoring the session and opens a new tab instead,
/// so every window came back with only a new tab. Before Chromium starts,
/// `ChromiumLauncher` has each crashed profile marked as cleanly exited,
/// and the session restores as after any quit.
@objc final class ForkCrashRestore: NSObject {
    @objc static func markProfilesCleanlyExited(inUserDataDirectory path: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return }
        for name in names where name == "Default" || name.hasPrefix("Profile ") {
            let file = URL(fileURLWithPath: path).appendingPathComponent(name).appendingPathComponent("Preferences")
            guard let data = try? Data(contentsOf: file),
                  var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  var profile = root["profile"] as? [String: Any],
                  (profile["exit_type"] as? String) == "Crashed" else { continue }
            profile["exit_type"] = "Normal"
            root["profile"] = profile
            guard let updated = try? JSONSerialization.data(withJSONObject: root) else { continue }
            do {
                try updated.write(to: file, options: .atomic)
                AppLogInfo("[ForkCrashRestore] \(name) didn't exit cleanly; its session will be restored")
            } catch {
                AppLogWarn("[ForkCrashRestore] couldn't update \(name): \(error)")
            }
        }
    }
}
