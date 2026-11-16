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

## Replaying off-center finger taps

On a booted simulator, run the geometry benchmark with a list of numeric seeds. Each seed fixes all offsets for 24 everyday sentences. The same draws run on the cover, wide joined and wide split layouts.

```sh
SIMULATOR_UDID="$sim" Benchmarks/typing-repair/finger-replay.sh 1729 88741 39863 91009 > geometry.json
python3 Benchmarks/stability/firefox_session.py "$sim" "$xctestrun" "$output" --finger-replay geometry.json
python3 Benchmarks/typing-repair/finger_report.py geometry.json "$output/typing.log" > results.json
```

The center profile checks the controls. The everyday profile samples horizontal and vertical errors plus a consistent bias within each message. The edge profile aims near key boundaries. The generator records an elliptical contact with varying radii and tilt. It compares the production view’s point hit test with two experiments: a majority of the whole contact, or at least 60% of the area that lands on visible caps with at least one quarter of the contact on caps. Gaps and split gutters can therefore matter. The finger sizes and distributions are synthetic assumptions.

The installed test replays a small paired sample using coordinate taps in Firefox. XCTest sends a point. The contact area is computed in the geometry benchmark. A pair of centered controls checks that the host honors autocorrection on and off. Both modes get identical relative offsets, including taps over the edge of a key. The report counts case-insensitive full-message matches, character insertions/deletions/substitutions and clean messages changed. It retains both texts and the number of completed taps if a misplaced touch interrupts typing.

To compare builds, run the generator on both implementations with the same seeds, then run:

```sh
python3 Benchmarks/typing-repair/finger_report.py candidate.json --compare-to baseline.json
```

**First comparison (build 73 vs. the top-row touch-release fix).** Four new seeds (20261118, 778902, 909667, 403121) produced 7,716 taps per profile across the three layouts. Each build received the same 23,148 taps. “Wrong” means a different target was hit; “dropped” means no key was returned.

| Tap profile | Correct before → after | Dropped before → after | Wrong before → after |
| --- | ---: | ---: | ---: |
| Center | 7,716 → 7,716 | 0 → 0 | 0 → 0 |
| Everyday | 7,506 → 7,542 | 53 → 17 | 157 → 157 |
| Near an edge | 5,887 → 6,025 | 404 → 259 | 1,425 → 1,432 |

The separate six-trace Firefox replay used the same screen offsets with autocorrect disabled and enabled. Raw exact messages rose from 2/6 to 3/6; after autocorrect both builds reached 4/6, with no clean message changed on either build. The previously missing “o” in “some milk” now registers even with autocorrect off. The two edge traces still need work.

Contact coverage is estimated against rectangular key faces. Relative to the fixed point selector, the experimental 60% rule recovered nine everyday taps without losing one on these four seeds. On edge taps it recovered 93 but lost seven previously correct taps. This is a benchmark experiment, not the installed keyboard's selection rule or a measurement of human fingertips.

## Rechecking the seven edge regressions

Replay the four archived seeds (20261118, 778902, 909667, 403121) to identify each original loss and gain by layout, seed, sentence and character offset. The JSON includes per-tap target names. `targets` uses the touch center, `guardedTargets` uses the generated ellipse, and `circularTargets` runs the extension's release-time selector with the simulated major radius. A word-start tie uses the previously emitted text. The generator keeps intended characters exclusively for scoring. In the archived replay the ellipse recovers 7/7 and keeps 93/93. The extension's circular estimate recovers 7/7 and keeps 92/93. The remaining tap is 0.5 points outside the compact keyboard.

Use `--fresh` for the separate 24-message corpus. Comparing source snapshots requires the same numeric seeds, layouts, and fixture offsets. Keep each JSON file with its run.

```sh
SIMULATOR_UDID="$sim" KEYBOARD_VIEW_SOURCE="$baseline_view" Benchmarks/typing-repair/finger-replay.sh --fresh 732911 1568843 407633 903221 951007 680017 314159 > base.json
SIMULATOR_UDID="$sim" Benchmarks/typing-repair/finger-replay.sh --fresh 732911 1568843 407633 903221 951007 680017 314159 > candidate.json
python3 Benchmarks/typing-repair/finger_report.py candidate.json --compare-to base.json --contact
SIMULATOR_UDID="$sim" CONTROLLER_SOURCE="$baseline_controller" Benchmarks/typing-repair/finger-sentences.sh base.json point 732911 > base-messages.jsonl
SIMULATOR_UDID="$sim" Benchmarks/typing-repair/finger-sentences.sh candidate.json circular 732911 > candidate-messages.jsonl
python3 Benchmarks/typing-repair/compare_finger_sentences.py base-messages.jsonl candidate-messages.jsonl
SIMULATOR_UDID="$sim" Benchmarks/typing-repair/finger-sentences.sh --check-pronoun
```

Each sentence goes through the key handlers and correction models of an English simulator text field, with autocorrect on and off. A centered period ends each message. Scores include exact displayed case, a separate count ignoring case, character edit distance, and changes to messages the baseline got entirely right. Switching layers interrupts a replay and keeps that trial in the denominator. The Firefox runner installs the build identified by the test configuration, verifies the extension binary and its debug library, and cold-starts the dedicated simulator. Its installed-keyboard test replays the same screen offsets with both host autocorrect settings.

Across the seven fresh seeds, the release-time rule recovered 305 of 12,621 edge taps and preserved every previously correct tap. Eighteen previously empty taps registered a wrong neighbor. It also recovered 24 everyday taps. All centered controls passed.

For the full-sentence replay, seed 732911 generated 216 trials per setting across three layouts and three tap profiles. A sentence counts as exact only when every character and its case match.

| Autocorrect | Previous exact | Revised exact | Previously exact lost | Previous → revised character errors ignoring case |
| --- | ---: | ---: | ---: | ---: |
| Off | 111/216 | 127/216 | 0 | 391 → 354 |
| On | 122/216 | 146/216 | 0 | 277 → 235 |

Every newly exact sentence needed the standalone pronoun capitalized. Ignoring case, both builds got the same 127 sentences exactly right with autocorrect off and the same 146 with it on.

The installed Firefox comparison used three of the fresh sentences and all three tap profiles on the compact layout. Each extension received 366 coordinate taps across both settings. Case-sensitive exact messages rose from 4/9 to 5/9 with autocorrect off and from 4/9 to 5/9 with it on. Both versions produced 14 character errors ignoring case with autocorrect off and 10 with it on. On an edge trace, both still replaced the intended “cook” with “book.”

## Wrong neighbors and directional spelling

To track the original 18 wrong neighbors and 305 gains, replay seeds 732911, 1568843, 407633, 903221, 951007, 680017 and 314159 with `--fresh`. Match each tap by sentence offset, profile, layout and seed across the three revisions. This distinguishes an intended letter recovered from a wrong letter suppressed into a drop.

```sh
python3 Benchmarks/typing-repair/finger_report.py revised.json --compare-to last-release.json \
  --both-contacts --previous-points first-point-reference.json
```

The next set contains 24 new sentences in `neighbors-sentences.txt`. Generate the same releases once, then run both source snapshots against that file. For each of the four seeds, the live replay resolves every point against the keyboard layout and the text actually present in its simulator field at that moment. It carries the direction of a near-boundary touch through to autocorrect on builds that support it. A centered period commits the final word. The installed Firefox test exercises the keyboard extension in a host app using XCTest coordinate taps.

```sh
export SIMULATOR_UDID="$sim"
dir=Benchmarks/typing-repair
"$dir/finger-replay.sh" --corpus "$PWD/$dir/neighbors-sentences.txt" 640517 170493 913867 520661 > "$output/points.json"
for seed in 640517 170493 913867 520661; do
    "$dir/finger-sentences.sh" "$output/points.json" live "$seed"
done > "$output/messages.jsonl"
"$dir/finger-sentences.sh" --check-direction
python3 "$dir/compare_finger_sentences.py" "$baseline/messages.jsonl" "$output/messages.jsonl"
```

For the installed “cook” regression, replay the archived compact-layout edge fixture for “maybe i can cook” with seed 732911 through the Firefox runner. The raw text at the word boundary is `vook`. The directional control also checks the opposite side of V with the same typed text and expects `book`.

The revised release-time selector recovered 14 of the 18 archived wrong neighbors and kept all 305 previously recovered taps. Three remaining misses occur at the same I/O boundary in “green folder” across three layouts. On the fourth, the modeled finger circle misses U in “blue.” On the four fresh seeds there were 6 new correct edge taps and 1 previously correct tap lost out of 7,260. Both builds had 75 drops. All centered taps remained correct, and the everyday profile scored 7,173/7,260 on both.

Firefox replayed the archived failing trace and nine fresh sentence traces on each installed simulator extension. With autocorrect on, the archived message changed from “Maybe I can book” to “Maybe I can cook.” With it off, both recorded “Magbe I can vook.” For the nine fresh Firefox traces, both versions scored 5/9 exact in each mode.

| Full-sentence simulator sample | Autocorrect | Exact before → after | Character errors before → after | Previously exact lost |
| --- | --- | ---: | ---: | ---: |
| 24 sentences, four seeds, 864 trials | Off | 499 → 499 | 1,580 → 1,575 | 0 |
| Same releases | On | 588 → 593 | 1,086 → 1,074 | 0 |
| 16 independent sentences, one seed, 144 trials | Off | 79 → 79 | 294 → 294 | 0 |
| Same releases | On | 89 → 93 | 205 → 199 | 0 |

The 24-sentence comparison exposed a regression during development where a later review could no longer recover “rice” from `tife`. The final guard protects the one substitution indicated by the touch and allows other spelling repairs. Three interrupted trials per version remain in the denominator with autocorrect on. The final version preserved all 578 initially exact raw traces across the two samples. In the independent confirmation, all four newly exact messages recovered “Wipe the dust off the desk.” across different layouts or profiles. Reproduce the confirmation with `neighbors-confirmation.txt` and seed 284957.
