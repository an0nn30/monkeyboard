# iOS Suggestions Implementation Plan

> Execute inline using superpowers:executing-plans. The user requested these concrete changes against supplied visual references; proceed with the existing architecture.

**Goal:** Match Apple's suggestion sizing and keyboard baseline, and offer relevant emoji while typing.
**Architecture:** Adjust shared iOS metrics and toolbar geometry; integrate a compact local emoji lookup with context-checked candidate selection.
**Tech Stack:** Swift, UIKit, XCTest, existing emoji TSV.
**Spec:** docs/superpowers/specs/2026-11-17-ios-suggestions-design.md

## Global Constraints
- Simulator tests only. Follow-up user request authorizes device installation/version verification only.
- Preserve local edits from other sessions. Follow-up user request authorizes merging and publishing this work.
- Preserve key sizes, Thumb reach and the transparent system background.
- No new model, network request, or per-key full catalog scan.

## Review Focus
- Stale suggestions after cursor/focus change cannot delete other text.
- Numeric fields, URLs, selection, emoji search and glide alternatives must stay correct.
- Default, joined, split, repeated letters and one-handed layouts keep valid hit targets.
- Emoji insertion cannot train the spelling model with emoji or trigger delayed sentence replacement.
- Local lookup remains small and uses only supported emoji versions.

### Task 1: Layout alignment
- [x] Add simulator geometry assertions for full-width 21pt iOS suggestions and preserved portrait key sizes with less footer space.
- [x] Capture Apple versus MonkeyBoard key frames on the Duo simulator and reproduce the offset.
- [x] Adjust height/footer/toolbar metrics and verify light/dark portrait and landscape.

### Task 2: Emoji predictions
- [x] Add focused tests for key/coffee/pizza, case/plurals, no fragment/function-word matches and compact retained data.
- [x] Build a bounded local lookup from existing emoji TSV; add optional emoji cells to the suggestion row.
- [x] Validate context and replace the typed word on selection without spelling learning.
- [x] Test insertion, continued typing, stale/unsupported contexts, and ordinary word suggestions on simulator.

### Task 3: Final check
- [x] Run affected geometry and integration checks and inspect actual Duo display captures.
- [x] Obtain one read-only final review and resolve important findings.
- [x] Leave the revised iOS style on the Duo simulator and report any coverage limits.

## Ledger
- Root cause: a split-only spacer takes half the bar; iOS suggestion font is 17pt; portrait reserves 39pt below the keys despite hiding the dismiss button. Emoji suggestions currently have no candidate source.
- Reuse the current main checkout, preserving existing local touch/glide work as required by the project and established workflow.

- Geometry RED: 7 expected failures for 17pt hints, the split spacer and hidden footer. Emoji lookup/UI RED: missing index then no emoji buttons. Geometry and index suites now pass.
- Ruling: preserve the supplied phone's 49.75pt caps and align the painted bottom row, rather than matching top-row accessibility frames. Native iOS 27.2 simulator caps are shorter than the supplied phone reference. Both final portrait captures end at y=2634px (878pt), 73pt above the screen bottom. The iOS portrait panel is now 291pt, top47/footer3, shifting all caps down36pt without resizing them.
- `final.xcresult`: five UI tests passed (emoji replacement/continued typing, bottom inset, Thumb reach, emoji picker, numeric-field restoration).
- Local index benchmark: 1,064,960-byte process footprint increase (including two catalog-version indexes); 20,000 lookups in 0.018 seconds, no further footprint increase. Simulator figures are not a physical-device measurement.
- Independent read-only reviewer found three P2 issues; all fixed: hidden-cell equal-width constraint conflict, caret before reused whitespace, held emoji rebound to a different document context. Added simulator regressions for caret/newline and immutable touch receipts. Also fixed changing a glide alternative leaving old emoji choices. Context and geometry suites are green after fixes.
- Ruling: this is deterministic local word/tag matching, not Apple's private contextual emoji ranking. No additional model or network request; full picker catalog remains lazy.
- Artifacts: `/tmp/monkeyboard-suggestions/`. All testing is on simulators; no physical-device operation, release commit, or push.
- Final review regressions: `review-final.xcresult` passed both emoji typing and Thumb reach UI tests. `compact-green.log` passed geometry after limiting the portrait adjustment to noncompact heights. The latest simulator app build succeeded and was installed on the primary Duo simulator.
- Visual captures inspected: `portrait-light.png`, `portrait-dark.png`, `landscape-light.png`, `landscape-dark.png`. Larger full-width hints and emoji choices are legible in both appearances and orientations. Left the primary Duo simulator unfolded in portrait, with `Key` and its two emoji suggestions visible.
- Appearance follow-up: reproduced stale light caps while the system material changed to dark. The controller copied a stale resolved `textDocumentProxy.keyboardAppearance` into a fixed board override. Removed that override and inherit UIKit's live keyboard traits. The simulator regression fails with the old override and passes without it; visually checked light → dark → light and continued typing. A temporary UIKit simulator host also verified explicit dark fields in a light system and explicit light fields in a dark system. No physical-device testing.
- Release validation: index-only source export passed appearance inheritance, emoji context replacement and iOS geometry checks. Build 81 passed emoji typing on the regression simulator and baseline/Thumb reach on the primary Duo simulator (`/tmp/monkeyboard-appearance/primary.xcresult`). The secondary simulator first ran folded, then exposed invalid off-screen XCTest coordinates when unfolded; the primary simulator completed both layout checks. Independent final review approved the staged changes. Physical access is limited to the guarded installer and version verification.
