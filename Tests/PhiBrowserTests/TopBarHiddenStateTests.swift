// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// ⌘S and a playing video both hide the Comfortable top bar; ⌘S always wins,
/// and a video's hide ends with the video.
final class TopBarHiddenStateTests: XCTestCase {
    func testVideoHidesAndBringsTheBarBack() {
        var state = TopBarHiddenState(userHidden: false)
        state.setVideoPlaying(true)
        XCTAssertTrue(state.isHidden)
        state.setVideoPlaying(false)
        XCTAssertFalse(state.isHidden)
    }

    func testCommandSDuringVideoLastsForThatVideo() {
        var state = TopBarHiddenState(userHidden: false)
        state.setVideoPlaying(true)
        XCTAssertFalse(state.setHidden(false), "a choice during a video is not remembered")
        XCTAssertFalse(state.isHidden)
        state.setHidden(true)
        XCTAssertTrue(state.isHidden)
        state.setVideoPlaying(false)
        XCTAssertFalse(state.isHidden, "the bar comes back when the video stops")
        state.setVideoPlaying(true)
        XCTAssertTrue(state.isHidden, "the next video hides it again")
    }

    func testCommandSOutsideVideosIsRemembered() {
        var state = TopBarHiddenState(userHidden: false)
        XCTAssertTrue(state.setHidden(true))
        XCTAssertTrue(state.isHidden)
        state.setVideoPlaying(true)
        state.setHidden(false)
        XCTAssertFalse(state.isHidden)
        state.setVideoPlaying(false)
        XCTAssertTrue(state.isHidden, "back to the user's own choice")
    }
}
