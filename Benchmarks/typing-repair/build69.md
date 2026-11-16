# Build 69: short words in context

Build 69 produced the intended text on 20 of 24 messages, compared with 15 for build 68 and 16 for Apple's English keyboard. It recovered five messages that build 68 missed and lost none that build 68 got right. This was a targeted simulator comparison, not an estimate of overall typing accuracy.

| In the installed keyboard | Apple | Build 68 | Build 69 |
|---|---:|---:|---:|
| Messages with a typo made entirely correct | 7/12 | 6/12 | 9/12 |
| Clean messages preserved exactly | 9/12 | 9/12 | 11/12 |
| All messages exactly as intended | 16/24 | 15/24 | 20/24 |
| First set: short words and context | 9/12 | 8/12 | 11/12 |
| Second set: everyday confirmation | 7/12 | 7/12 | 9/12 |

The [per-message results](build69-messages.json) include the input, intended text, and actual output of all three keyboards. Both sets had six typos and six intentional spellings. The first set informed development; the second was written before implementing the candidate and was reserved for confirmation. Its six typo messages and six clean messages are a small check of whether the change transfers to other wording.

Build 69 fixed “Please lock the back dor,” “They repaired the gas leek,” and “The mechanic stopped the oil leek.” It also preserved *bok choy* in two messages where both other keyboards produced *book choy*. All three preserved “The plumber sliced a leek,” “The repair crew shared leek soup,” and the shorthand *rn* and *ur*.

Four messages still missed: *roof leek*, *a roofer sealed the leek*, *at the side dor*, and the name in “Dor is on my team.” On the name, MonkeyBoard 68 and 69 both wrote *Do*; Apple wrote *For*. On *side dor*, build 69 left the typo alone and Apple changed it to *side for*. Both count as misses.

## What changed

At a word boundary, the keyboard can now ask the existing on-device transformer whether a rare short spelling has strong support for a more common alternative. The dictionary supplies candidates with a missing doubled letter or a close homophone; a plausible alternative alone is insufficient to trigger a replacement. A later word can also supply evidence for restoring the literal spelling, as *choy* does for *bok*. This change uses the bundled weights, without adding a model or a table of example-specific fixes.

## How we measured it

XCTest tapped the individual on-screen keys in the same app's Message draft on iPhone Duo simulators running iOS 27.2 (24B91016s). Every message began in an empty field. Each keyboard received a final space and one second to settle. Exact comparison included capitalization and whitespace. The original eight examples, used during development, are excluded from the 24 above: build 69 scored 8/8 on those, versus Apple's previously recorded 7/8.

To repeat the two new sets, use the [existing comparison command](README.md#reproduce) with `testCaptureShortWordsAndContext` and `testCaptureEverydayConfirmation`. Run each method on an Apple keyboard simulator and on each MonkeyBoard build. The JSON attachment records which keyboard was actually active. Simulator tap timing is controlled; the test does not measure thumb accuracy, suggestion acceptance, glide typing, or device crash rates.

## Regression checks

Separately, builds 68 and 69 replayed the same 46 older messages through the simulator keyboard controller (23 typo/clean pairs from the build 54 holdout, taking every sixth distinct sorted pair ID). Their final text was identical on all 46: both fixed 20/23 typo messages and preserved 23/23 clean ones. This replay has no Apple result and is not included in the UI totals.

The final installed simulator extension passed the three focused UI tests for contextual correction and undo, intentional food names, and changing fields during sentence review. A build 69 development candidate also passed the memory-warning replay: it released both models and typed 24 more messages. These checks do not establish stability in other apps on a physical phone.
