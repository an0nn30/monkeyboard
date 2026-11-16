# Typing sound footprint on iPhone Duo · build 70

Measured November 16, 2026 on a physical iPhone Duo running iOS 27.3. Each pass opened a fresh draft and tapped “we can meet by the lake ” twice on the installed MonkeyBoard extension (48 taps). The haptic and prediction settings stayed the same, Full Access was on, and all four passes used the same keyboard process. The test verified the resulting text and counted requests actually submitted to the sound API.

| Pass | Sound | Playback requests | Before preparing sound (MiB) | Peak sampled at a tap (MiB) | Last tap (MiB) |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | Off | 0/48 | 10.44 | 119.08 | 119.05 |
| 2 | Soft Knock | 48/48 | 105.50 | 110.33 | 110.28 |
| 3 | Soft Knock | 48/48 | 105.83 | 107.25 | 107.20 |
| 4 | Off | 0/48 | 106.11 | 107.56 | 107.45 |

The first Off pass includes cold-start work. Compare the two Soft Knock passes with the last Off pass for warmed-up typing. These are whole-extension physical memory footprints sampled once per tap, not isolated audio allocations or continuous lifetime peaks. The short test does not establish long-session stability.

The measurement probe and its UI test compile only with the Swift condition `MONKEYBOARD_SOUND_BENCHMARK`. The ordinary install omits the probe. The test is `KeyboardTypingTests/testPhysicalTypingSoundFootprint` and restores the original sound selection.
