# Build 62: learning from autocorrect undo

MonkeyBoard keeps a spelling after three explicit undos of the same automatic replacement in eligible text fields. Counts follow the original word across messages. If the replacement changes before the threshold, counting starts over for that spelling. Letter case and straight/curly apostrophes are normalized for comparison; the keyboard leaves the user's actual input untouched. Automatic guesses, suggestion taps, glide words, and ordinary deletions are not votes. An undo of an ambiguous multi-word rewrite isn't a vote either.

The app and extension share a local, non-synchronizing, device-only keychain service. The first two undos store fingerprints and a count, not the literal word or the message. At most 128 pending spellings are retained; the oldest pending items are discarded first. A learned entry holds the original spelling. Forgetting a word removes its item; resetting deletes the entire spelling service, including pending counts, without touching other keyboard preferences. Promotions and suppression do not modify the prediction models.

The simulator UI test uses actual key presses in the host draft and restarts the app between corrections. It checks that one undo leaves the list empty and the next occurrence still corrects; the third undo protects a spelling after relaunch; a different typo in the same sentence still corrects; forgetting restores autocorrect; and canceling or confirming reset has the expected effect, including for pending counts. The test skips if the simulator already has spelling memory, and clears its own test data at the end. Run it with MonkeyBoard enabled on a test simulator:

```sh
xcodebuild test -project MonkeyBoard.xcodeproj -scheme MonkeyBoard \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" -parallel-testing-enabled NO \
  -only-testing:MonkeyBoardUITests/KeyboardTypingTests/testRepeatedUndosLearnSpellingsAndForgetOrResetThem
```

The attribution checks run separately on a Mac. They exercise sentence edits that share partial words, word splitting, multiple simultaneous corrections, and previously machine-generated text. They do not write to the keychain.

```sh
swiftc Shared/PersonalSpellings.swift Benchmarks/build62/check-attribution.swift -o /tmp/monkeyboard-check-attribution
/tmp/monkeyboard-check-attribution
```
