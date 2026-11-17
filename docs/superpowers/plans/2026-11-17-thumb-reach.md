# Thumb Reach Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for this small, already authorized change.

**Goal:** Adjustable thumb reach that preserves iOS key sizes, installed on the Duo simulator.
**Architecture:** Persist a percentage, carry it in KeyboardModel, and shift original split key frames horizontally before building their touch targets. Reuse the existing preview and lifecycle.
**Tech Stack:** SwiftUI, UIKit, keychain preferences, XCTest, simulator layout harness.
**Spec:** docs/superpowers/specs/2026-11-17-thumb-reach-design.md

## Global Constraints
- Simulator testing and installation only.
- Preserve all existing local work; reuse the current checkout and do not publish it.
- Preserve every key’s size, vertical layout, and iOS appearance; no new background.

## Review Focus
- Duplicate Y/B and native G/V layouts: neither bank may overlap or leave bounds.
- Symbols, emoji search, and restored letters use correct hit regions.
- Changing reach must refresh swipe geometry and cached touch regions.
- Zero, joined, Default, and keypad layouts must remain identical.
- Setting survives app/extension relaunch and appears in Appearance previews.

### Task 1: Preference and geometry
**Files:** Shared/KeypressFeedback.swift; Keyboard/KeyboardModel.swift; Keyboard/KeyboardView.swift; Keyboard/KeyboardViewController.swift; App/MonkeyBoardApp.swift; App/AppearanceSettings.swift; UITests/KeyboardComparisonTests.swift; Benchmarks/stability/ios-style.swift.
**Interfaces:** ThumbReachSetting.percent/save(Int), KeyboardModel.thumbReachPercent, slider `thumb-reach`.
- [x] Add an integration test for persisted slider changes, movement of both banks, and typing; observe failure for the missing setting.
- [x] Add geometry checks for 0/50/100%, fixed painted sizes, bounds, gaps, touch centers, both repeat modes, styles, and widths 560/655/801/951.
- [x] Implement preference, slider, horizontal repositioning, cache invalidation, and previews.
- [x] Run simulator geometry harness and focused UIKit tests; expect zero failures.
- [x] Visually inspect Duo portrait and landscape, leave iOS style closer to edges and document results.

## Execution ledger
Pre-flight: one task, no shared interfaces between tasks. User has approved the approach and requested implementation; proceed inline without another approval round. Existing checkout includes shipped and uncommitted work; preserve it and leave this change uncommitted.

- Red: missing-slider UI assertion and 40 expected geometry movement/cache failures before implementation.
- Geometry: `SIMULATOR_UDID=91E9297B-F8FA-4634-8898-AD7315EB6277 bash Benchmarks/stability/ios-style.sh` — zero failures (`final-geometry.log`).
- Live diagnostics found an 801pt root view inside the 951pt landscape display, with zero horizontal safe insets. The outer 75pt margins belong to the host and cannot be reclaimed through public extension APIs. Removed speculative expansion and temporary logging; retained outward movement within the host. Apple: https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface.
- XCTest orientation changes target the folded display while Device Hub can rotate the inner display independently. Removed the misleading two-orientation loop. Direct display-3 captures verify the real portrait and landscape layouts.
- Numeric-field restoration, emoji browsing/search, persisted reach, typing with both spaces, and live Join→Split checks passed during integration. Final simplified build passed `testThumbReachMovesSplitKeysAndPersists` and the opt-in preview setup (`final.xcresult`).
- Read-only review found no remaining geometry issues and recommended retaining system-controlled host width after the live diagnosis.
- Artifacts: `/tmp/monkeyboard-thumb-reach/`.
- Final build installed on the Duo simulator only, left open in portrait with iOS split style and Thumb reach at 75%. Visually checked portrait and landscape; key sizes and styling preserved. No physical-device access, commit, or GitHub push.

## Approved release follow-up

Dustin subsequently requested merging Thumb reach to main, pushing GitHub, and installing on Duo, with all testing on simulators. Build 80 includes Thumb reach and the previously requested numbers-until-Space behavior. Unrelated local work is preserved and excluded from this commit.

The staged release source passed the iOS geometry harness with zero failures and all three simulator tests: `testIOSStylePickerAndTyping`, `testThumbReachMovesSplitKeysAndPersists`, and `testNumericFieldsUseKeypadAndRestoreTextKeyboard` (`/tmp/monkeyboard-thumb-reach/release.xcresult`). The guarded installer verifies both bundle versions, checks origin/main again before installation, and verifies the installed version without launching or testing on the phone.
