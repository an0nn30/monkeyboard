# Keyboard extension memory pressure (build 66)

Two build 65 exits on the Duo at 16:33:38 and 16:34:10 local time on November 15 were recorded by iOS as `JETSAM_REASON_MEMORY_PERPROCESSLIMIT`. In the second instance UIKit delivered memory warnings about 25 seconds before termination. iOS also logged that it had reached its quota for saved memory reports. Looking only for a new keyboard crash file missed the cause.

The keyboard now cancels optional prediction work on a warning, releases both Core ML models on their owning queues, and continues with ordinary word correction and suggestions. The reduced-memory mode lasts for the process, including a new host controller. No preference or learned spelling is changed. Physical devices also check their current process memory allowance before optional prediction: 48 MiB of remaining space for next-word or short review work, 144 MiB for a cold full-sentence review and 32 MiB once it is loaded. At less than 24 MiB remaining the keyboard takes the same path as a warning. These are conservative admission budgets, not a claim about the Duo's memory ceiling.

Run the regression on a booted simulator with the app installed:

```sh
SIMULATOR_UDID=<simulator-uuid> Benchmarks/stability/pressure.sh
```

The runner substitutes a local text document for the host and uses the real key handlers, workers and compiled models. It warms both models, calls UIKit's memory-warning callback, checks that both are released, and exercises correction, Undo, repeated messages and a second host. With build 65 the sentence model remained loaded after the warning. Simulator memory figures describe the test process; they do not measure physical-device headroom or establish a crash rate. Installed-extension UI coverage also exercises sentence correction and Undo, switching Safari fields, and glide typing.

Run UI tests of unpersonalized behavior on a fresh simulator. The correction test deliberately undoes “goes” and the glide test picks “too” instead of “to”; repeated runs can teach those exact preferences. We verified both preferences on the reused test simulator without resetting any spelling memory. A personalized keyboard preserving those choices is expected.

In the build 66 synthetic pressure replay the process footprint was 110 MiB with both models loaded and 102 MiB just after releasing them. The runner separately verifies object release and continued typing; the memory allocator and framework caches need not return every byte immediately.

## Installed keyboard transition suite

The suite taps the installed extension and Apple's own keyboards in the MonkeyBoard draft, Messages, and Safari. It checks the host's actual text and selected keyboard at each checkpoint. The Messages case edits and clears an unsent simulator draft. The Safari cases use local HTML forms.

| Scenario | Checks in one pass |
|---|---|
| Apple English and MonkeyBoard | Six round trips, typing with each keyboard and preserving the complete draft |
| Apple's emoji picker | Three visits via the iOS keyboard menu, returning to MonkeyBoard and typing after each |
| MonkeyBoard emoji picker | Six cycles of search, category browsing, insertion or deletion, and return to letters |
| Joined and split layouts | Ten layout changes, space from the active layout, emoji entry and return |
| Sound changes | All eight settings, verifying the loaded preset, inserted and deleted text, and playback submission counters |
| Uninterrupted typing | Eight passes through a 20-character phrase, checking text and extension process ID throughout |
| Background and foreground | Five round trips through Safari, the Home Screen and the app, tracking two independent drafts |
| Two ordinary Safari fields | Six focus changes during emoji search, checking that search input and edits stay in the right field |
| Safari numeric and secure fields | Four loops through text, numeric and password fields, checking the expected iOS keyboard handoff |
| Apple-only Safari control | Four loops through the same text, numeric and password fields using Apple's keyboards |
| Messages compose field | Four rounds mixing emoji, Apple's keyboard and MonkeyBoard, with the draft checked after each round |

Use dedicated, booted simulator UUIDs. Enable MonkeyBoard, Apple English and Emoji in iOS keyboard settings. Turn off **Device → Keyboard → Simulate Hardware Keyboard** in Device Hub so the software keyboard appears when the field receives focus. Full Access on the test simulator exercises sound submissions. With Full Access off, the sound test expects zero submissions for each preset. The split test requires the open Duo or an iPhone simulator with a wide landscape keyboard. Set the second UUID if the main simulator uses the cover display.

```sh
SIMULATOR_UDID=<main-uuid> WIDE_SIMULATOR_UDID=<wide-uuid> \
  STABILITY_RUNS=1 Benchmarks/stability/transitions.sh
```

Increase `STABILITY_RUNS` to repeat the UI suite. The runner prints its results directory and saves each Xcode result bundle, test log and summary. A five-minute limit per case captures persistent stalls. After the UI runs it exercises memory pressure, saves per-simulator termination logs and checks for abnormal exits and matching crash reports. The exit report lists SIGKILL entries with an undetermined cause for review. Inspect the failed XCTest activity to see the transition, keyboard and field involved. Physical-device memory limits and audible output require device testing.

### Build 72 bug hunt · November 16, 2026

On iOS 27.2, all nine cover tests and the wide-layout test passed in the first full run. The ten split/join transitions also passed on the unfolded Duo. The sound test counted three playback submissions per enabled preset and zero for Off with Full Access enabled. With Full Access disabled, it counted zero for all eight settings.

The repeat run passed nine of the ten original scenarios. On a second Duo, the third numeric-to-password transition repeatedly waited 60 seconds for Safari animations and hit the five-minute limit. Apple's secure keyboard appeared, and samples of both Safari and MonkeyBoard showed their main threads waiting in their run loops. One run after reopening Safari passed all four mixed-keyboard round trips in 61 seconds. A later fresh launch reproduced the wait.

The added Apple-only control reproduced the five-minute timeout on a Duo and passed in 58 seconds on the Pro Max. The control now starts Safari in a fresh process to isolate it from previous tests. It passed all four rounds in 64 seconds on the Duo that previously timed out with Apple. To investigate, run `testSafariFieldChangesDuringEmojiSearchAndSecureInput` and `testSafariSystemKeyboardControlAcrossSecureFields` from Xcode's Test navigator. Compare the last field transition in the activity logs. No MonkeyBoard crash report accompanied the stalls. The unclassified SIGKILL entries across the two complete suite runs coincided with simulator app installations.

In a separate diagnostic run, we deliberately aborted the simulator extension during the second typing passage. XCTest failed on the next MonkeyBoard key it tried to tap. The exit checker independently found the fatal signal and the matching crash report. Reopening the draft and selecting MonkeyBoard again allowed all 160 taps to pass. This deliberate failure is excluded from normal stability totals.

### Continuous typing in third-party apps

For Firefox, install Mozilla’s simulator build (`org.mozilla.ios.Fennec`) on the same simulator as MonkeyBoard. Build the UI tests with the benchmark flag shown above. Run this with the simulator UUID, the resulting simulator `.xctestrun`, and a new output directory.

```sh
python3 Benchmarks/stability/firefox_session.py "$SIMULATOR_UDID" "$XCTESTRUN" "$RESULTS_DIR"
```

The default is ten minutes. A loopback-only page holds the draft. The test taps visible letter and space keys, checks the accumulated text after each phrase ignoring case, and records the extension PID when the benchmark probe is present. An unexpected keyboard change or PID change fails the session. The runner saves the typing checkpoints, filtered simulator log and XCTest result bundle on disk.

The Discord case is opt-in. It expects an unlocked device displaying an empty Discord message composer and the explicit test environment value `MONKEYBOARD_HOST_SESSION=discord`. It stops if it cannot identify the editor or sees an existing draft. Its result bundle can contain screenshots of the open conversation.

Pass `--with-messages --seconds 720` to run the simulator-only Messages/Firefox session. Use a dedicated simulator with Messages available. The test picks a fictional number in the 202-555-01xx range and stops before typing if a draft contains anything other than verified text from a prior run of this test. It alternates unfinished sentences between Messages and the local Firefox form, checking both drafts after foregrounding and every 20 taps while typing. Keyboard selection is allowed only during setup. The runner saves timestamped checkpoints, simulator extension logs, and a 15-second window on either side of a detected failure where logs are available. A different PID on returning to an app is recorded separately from an unexpected restart during typing.

On November 16, the build 73 Messages/Firefox run completed 12:34 of typing, including 976 key taps in Messages, 442 in Firefox and 22 mid-sentence host switches. All 104 draft checks passed. MonkeyBoard kept the same observed process ID, neither host required refocusing, and no fallback, abnormal extension exit, or matching crash report was recorded. The drafts were unsent. This run preceded the top-row touch-release fix; it is simulator evidence rather than a physical-device crash rate.

A shorter repeat with the touch-release fix returned from Firefox to Messages with both drafts intact, then hit XCTest's four-minute limit while waiting for Messages animations. A simulator screenshot during the wait showed MonkeyBoard and the expected next letter. Count this repeat as incomplete.
