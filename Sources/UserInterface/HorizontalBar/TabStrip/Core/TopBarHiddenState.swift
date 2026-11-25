// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

/// Whether the Comfortable top bar is hidden, from ⌘S and from a video
/// playing in the focused tab (`ForkSettings.hidesTopBarDuringVideo`).
///
/// ⌘S always wins. With no video playing it sets the user's choice, which
/// new windows start with. While a video plays the bar is hidden, and ⌘S
/// shows or hides it for that video only; once the video stops, or another
/// tab is focused, the bar goes back to the user's choice, so a bar shown
/// before the video comes back on its own.
struct TopBarHiddenState: Equatable {
    /// The user's choice outside videos (⌘S), remembered for new windows.
    private(set) var userHidden: Bool
    private(set) var isVideoPlaying = false
    /// ⌘S while a video plays: shown or hidden for that video only.
    private var videoChoice: Bool?

    init(userHidden: Bool) {
        self.userHidden = userHidden
    }

    var isHidden: Bool {
        isVideoPlaying ? (videoChoice ?? true) : userHidden
    }

    /// ⌘S. Returns true when the user's remembered choice changed.
    @discardableResult
    mutating func setHidden(_ hidden: Bool) -> Bool {
        if isVideoPlaying {
            videoChoice = hidden
            return false
        }
        guard userHidden != hidden else { return false }
        userHidden = hidden
        return true
    }

    mutating func setVideoPlaying(_ playing: Bool) {
        guard isVideoPlaying != playing else { return }
        isVideoPlaying = playing
        videoChoice = nil
    }
}
