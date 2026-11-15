# MonkeyBoard

A native English QWERTY keyboard for iPhone, with flat keycaps, Apple system type, and a borderless character preview. Press a letter to see its preview immediately, slide to correct it, and lift to insert it. The layout uses the keyboard width supplied by iOS as the available space changes.

Build 61 recovers all five longer swipes lost in build 60, including *volleyball*, and keeps all twelve of its new catches. On 8,192 fresh recorded swipes it got 14 more intended words first and lost four, a net gain of ten. [Compare builds 60 and 61](Benchmarks/glide/build61/README.md).

Build 60 recovers the earlier *following* swipe and compares two readings when the finger path points to different long words. On 1,141 fresh longer swipes, it picked 948 correctly on the first try, up from 941. [Compare builds 59 and 60](Benchmarks/glide/build60/README.md).

Build 59 improves recognition of longer glide words. On 821 fresh swipes of seven or more characters, first-choice accuracy went from 74.9% to 81.0%. [Compare builds 58 and 59](Benchmarks/glide/build59/README.md).

Build 58 adds English glide typing. Keep a finger on the first letter, trace through the rest of a word, then lift. Pick another match from the suggestion strip or tap Backspace to remove the word. The next word gets a space automatically, and punctuation attaches to the preceding word. **Keyboard Settings → Glide typing** turns it on or off. See the [recorded-swipe benchmark](Benchmarks/glide/README.md).

Build 57 restores omitted apostrophes as you type. After punctuation or a pause at a word boundary, an on-device English model reviews the sentence and scores nearby spellings in context. Press Backspace immediately after a correction to undo it. See the [contraction tests](Benchmarks/build57/README.md) and [full-sentence benchmark](Benchmarks/build56/README.md) for results.

Some historical benchmarks use a separately supplied `typo_sentences.md` file in S:/C: format. To reproduce those runs, provide your own copy to the corresponding preparation script. The app builds with the model files included here.

## Run on your iPhone Duo

1. Open `MonkeyBoard.xcodeproj` in Xcode. Select the blue MonkeyBoard project, then **Signing & Capabilities**. Select your Apple development team for both **MonkeyBoard** and **MonkeyBoardKeyboard**. A Personal Team works for local development. If Xcode reports an unavailable bundle ID, give the app a unique ID and use that same ID followed by `.keyboard` for the extension.
2. Connect and unlock the Duo. Enable **Settings → Privacy & Security → Developer Mode**, then follow the restart and confirmation prompts.
3. Select the **MonkeyBoard** scheme and your iPhone as the run destination. Press **⌘R**.
4. On the phone, open **Settings → General → Keyboard → Keyboards → Add New Keyboard** and select **MonkeyBoard** under Third-Party Keyboards.
5. Tap the **Message draft** in the app, or open a note. Hold the globe and select **MonkeyBoard**.

## Try it

- With the Duo closed, tap **•••** above the keys and choose **Left Hand** or **Right Hand**. The keys and suggestions slide toward that thumb. Tap the arrow in the empty space (or choose **Full Width** in the menu) to expand again. Your choice is remembered separately from the open layout.
- On wide layouts, the keyboard splits into two thumb-sized groups with a spacebar on each side. The layout button at the right of the suggestion strip slides the keys between split and joined positions. Reduce Motion makes the switch immediate. You can also set **Keyboard Settings → Split on wide screens**.
- Tap the down chevron beneath the bottom-left keys to dismiss the keyboard. Tap the text field to type again. Hold the globe to choose another enabled keyboard, including Emoji.
- Tap Shift for one uppercase letter or double-tap it for Caps Lock. Hold Delete to repeat. Use **123**, then **#+=**, for numbers and symbols.
- In MonkeyBoard, open the gear for **Keyboard Settings**. Move **Firmness** from 0% (off) to 100%, then tap **Try a keypress**. The upper range uses a heavy impact. Tap **••• → Keypress Feedback** on the keyboard for presets. The setting is stored locally on the device. Soft is the default.
- Letters, suggestions, function keys and the character preview adapt to light and dark appearance. The keyboard uses the tinted background that iOS supplies around the keys.
- If you cannot feel feedback on hardware, check **System Haptics** in **Sounds & Haptics**. The extension also exposes iOS’s optional **Allow Full Access** switch in the MonkeyBoard keyboard settings. Typing and local completions work with that switch off. The prototype contains no networking or keystroke logging.
- In English text, Space, Return, and common punctuation accept a close spelling correction. Tap Delete immediately to restore your spelling. You can also tap your original spelling in the first suggestion slot or pick a different suggestion. **Keyboard Settings → Auto-Correction** controls automatic replacement. MonkeyBoard combines Apple’s local spell checker and supplementary lexicon with its offline Rust ranker. Build 10 adds **Use sentence context**: a compact neural model considers earlier words in the current sentence when deciding between nearby spellings. Build 11 also considers the meanings of earlier words: try “the novel goes beside my boog” and “the shoe goes beside my boog”, then press Space. Tap Delete to undo. Switching off sentence context restores build 9’s correction policy. Build 12 includes the trained 15M transformer in the keyboard. Select **Keyboard Settings → Prediction model → Transformer · 15M** (the default) or **Compact**. The transformer uses up to 32 tokens for next-word suggestions. For an uncertain spelling it can use up to three following words to revise text during continuous typing. Try typing “The novel gos beside ”. Tap Delete immediately after the change to restore “gos” and keep “beside ”. Build 14 can wait up to five following words for “leek”. Try “The tenant reported a leek behind the toilet” and tap Space, then try “The tenant reported a leek in the soup”. [See the build 14 typing results](Benchmarks/build14/README.md). Email and URL fields and fields that disable autocorrection keep literal input.

## Run in Simulator

Use the **MonkeyBoard** scheme with the **iPhone Duo** simulator in Xcode 27.2. Enable and select the keyboard as in steps 4 and 5. If the software keyboard is hidden while a text field is focused, use the simulator’s software keyboard toggle. Use a physical iPhone to evaluate haptic strength.

## Build the prediction engine

Install Rust with Cargo and add the iPhone and Apple Silicon simulator targets once:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

An Intel simulator needs `x86_64-apple-ios`. Xcode builds the Rust library automatically; no model download or Full Access is needed on the phone. The build phase looks for Cargo in `$HOME/.cargo/bin` or PATH. Run `cargo test --manifest-path keyboard-engine/Cargo.toml` for the native engine checks.

Build 21 is a simulator research candidate and does not pass its release accuracy gates. See the [training and blind simulator results](Benchmarks/build21/README.md).

See the [build 20 simulator comparison](Benchmarks/build20/README.md) for learned short-word corrections, missing spaces, and preservation of intentional spellings. The previous [build 19 comparison](Benchmarks/build19/README.md) covers missing spaces. Read the [build 11 correction benchmark](Benchmarks/build11/README.md), the [build 10 sentence and touch benchmark](Benchmarks/build10/README.md), the [build 8 side-by-side benchmark](Benchmarks/build8/README.md) for results and reproduction steps and the [model notes](keyboard-engine/MODEL.md) for training data and limitations.
