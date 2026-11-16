# Spacebar accuracy and autocorrection undo on iPhone Duo Simulator

See the [build 69 comparison with build 68 and Apple's keyboard](build69.md) for the follow-up on short words, names, and sentence context.

The previous spacebar accepted low taps, but part of the gap between Space and period still produced a period. An installed-extension test reproduced this just one point onto the spacebar side of the gap. The revised spacebar takes its half of the shared gap and the gap above it. Key faces stay in the same position.

The previous keyboard discarded the undo information as soon as another letter was typed. The arrow beside the options button now restores the most recent autocorrection and preserves the delimiter and text typed since then. Immediate Backspace still undoes the accepting keystroke. After typing ahead, Backspace deletes the latest character. The arrow is limited to 48 additional characters and checks the field, selection and surrounding text before editing. Starting another sentence, changing the selection, or making a newer correction can end the opportunity sooner.

## Space and punctuation

The same 106 specified points were sampled on the simulator using the UIKit keyboard view, once with the previous spacebar rectangle and once with the revised rectangle. The layout dimensions were 393 points for the joined cover layout and 900 for wide joined and split layouts. The controls include B and N, intentionally typed punctuation, and three points in the split gutter where a tap should produce nothing.

| Intended target | Previous | Revised |
|---|---:|---:|
| Space on the cover | 9/19 | 19/19 |
| Space on the wide joined layout | 9/19 | 19/19 |
| Space on the wide split layout | 18/32 | 32/32 |
| Deliberate punctuation across layouts | 15/15 | 15/15 |
| B and N across layouts | 18/18 | 18/18 |
| Empty split gutter | 3/3 | 3/3 |

These counts cover the predefined coordinates. They do not estimate the percentage of real thumb taps that would improve. A separate XCUITest checked actual text inserted on each side of the Space/period gap in a hosted keyboard.

In Safari, the two keyboards received four taps each in the same HTML search field with autocorrection disabled. We measured the midpoint between each keyboard’s own Space and period accessibility frames. Both inserted the intended character at the two key centers and one point toward Space. One point toward period, Apple inserted a space and MonkeyBoard inserted a period. The expected character for each point was specified before the test.

## Everyday messages

Apple’s built-in English keyboard and the revised MonkeyBoard typed the same eight messages in the app’s Message draft field on separate iPhone Duo simulators running iOS 27.2 (24B91016s). Each case started in an empty field. XCTest tapped the individual on-screen keys, finished with a space and read the field after one second. The comparison includes capitalization and the final space. The eight examples were chosen for this probe. The exact input, intended text and both outputs are in [messages.json](messages.json).

| Outcome | Apple | MonkeyBoard |
|---|---:|---:|
| Entire message matched intent | 7/8 | 6/8 |
| Message with a typo fully corrected | 3/4 | 2/4 |
| Clean message preserved | 4/4 | 4/4 |

Both keyboards fixed *teh* and *frotn*. Apple also fixed *dor* in “Leave the box by the dor.” Both left *leek* in “The plumber fixed the leek” and preserved it in “I made leek soup.” Both preserved the name *Nori* and the shorthand *rn*. Use new messages for an independent comparison if these examples are used for tuning. XCTest tap timing cannot measure a person's typing speed or time spent repairing text.

## Regression results

Of 52 keyboard UI tests, 44 passed, six failed, and two skipped because they require the unfolded Duo display. The four new spacebar and Undo cases all passed. The haptics test passed after its UI driver scrolled the settings slider into view. The separate memory-pressure replay released both models and typed 24 additional messages.

Each remaining failure reproduced at the same assertion using the archived build 66 simulator app. Three tests expect the keyboard to wait longer than it currently does before changing “landlord us a,” “kidsin,” and “padi.” The other failures were the “to figure ut” correction and full-sentence expectations in the Notes and “directed be a woman” examples. The two skipped UI cases cover split layout switching and tapping or swiping repeated Y and B keys. Wide layout spacebar coordinates were exercised independently above.

## Reproduce

Run the coordinate test on a booted iOS simulator from the repository root. An optional first argument to the script selects a different version of KeyboardView.swift while keeping the sample points fixed.

```sh
SIMULATOR_UDID=<simulator-uuid> Benchmarks/typing-repair/touches.sh
```

Select the English Apple keyboard on one simulator and MonkeyBoard on the other. Run the same test on each destination. Each result bundle contains an everyday-messages JSON attachment that identifies the keyboard actually used and the final text for every case.

```sh
xcodebuild -scheme MonkeyBoard -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -parallel-testing-enabled NO -resultBundlePath "$RESULT_BUNDLE" \
  -only-testing:MonkeyBoardUITests/KeyboardComparisonTests/testCaptureEverydayMessages test
xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" --output-path "$OUTPUT_DIR" --filter '*.json'
```

Use `testCaptureSafariSpaceBoundary` in place of `testCaptureEverydayMessages` to collect the four Safari taps from either keyboard.

The installed-extension regression cases are in [KeyboardTypingTests.swift](../../UITests/KeyboardTypingTests.swift). They cover restoring “fine” after typing “today,” retaining the accepting space on button undo, deleting a later character with Backspace, and invalidating undo on selection changes.
