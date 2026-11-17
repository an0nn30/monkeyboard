// Compiled into the real controller's file by the simulator runner.
private final class EmojiDocument: NSObject, UITextDocumentProxy {
    var text = "key", after = "", selection: String?
    var documentIdentifier = UUID()
    var keyboardType = UIKeyboardType.default
    var isSecureTextEntry = false
    var autocorrectionType = UITextAutocorrectionType.default
    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { after }
    var selectedText: String? { selection }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { !text.isEmpty || !after.isEmpty }
    func insertText(_ value: String) { text += value }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        precondition(offset >= 0 && offset <= after.count)
        text += after.prefix(offset)
        after = String(after.dropFirst(offset))
    }
    func setMarkedText(_ markedText: String, selectedRange: NSRange) { preconditionFailure() }
    func unmarkText() {}
}
private final class EmojiController: KeyboardViewController {
    let doc = EmojiDocument()
    override var textDocumentProxy: any UITextDocumentProxy { doc }
}
extension KeyboardViewController {
    fileprivate func checkEmojiContext(_ doc: EmojiDocument) {
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        _ = view
        model.style = .ios
        model.layer = .letters
        autoCorrect = false
        let savedRecent = UserDefaults.standard.object(forKey: "emoji.recent")
        let savedTones = UserDefaults.standard.object(forKey: "emoji.tones")
        defer {
            UserDefaults.standard.set(savedRecent, forKey: "emoji.recent")
            UserDefaults.standard.set(savedTones, forKey: "emoji.tones")
        }
        func choose(_ glyph: String) {
            insertSuggestedEmoji(glyph, context: emojiCandidateContext?.id ?? UUID())
        }
        func prepare() {
            doc.text = "a key"; doc.after = ""; doc.selection = nil
            doc.keyboardType = .default; doc.isSecureTextEntry = false
            model.layer = .letters; model.emojiMode = .closed
            check(suggestedEmojis(for: "key").map(\.glyph) == ["🔑", "🔐"], "missing key choices")
        }
        prepare()
        choose("🔑")
        check(doc.text == "a 🔑 ", "replacement deleted the wrong span")
        check(lastCorrection == nil && run == nil && sentenceInput == nil, "emoji entered correction learning")
        prepare(); doc.text = "other key"; choose("🔑")
        check(doc.text == "other key", "stale leading context edited text")
        prepare(); doc.documentIdentifier = UUID(); choose("🔑")
        check(doc.text == "a key", "stale document edited text")
        prepare(); doc.after = "board"; choose("🔑")
        check(doc.text == "a key", "inside-word replacement")
        prepare(); doc.selection = "key"; choose("🔑")
        check(doc.text == "a key", "selected text replacement")
        prepare(); model.layer = .numbers; choose("🔑")
        check(doc.text == "a key", "number page replacement")
        for type in [UIKeyboardType.URL, .emailAddress, .numberPad] {
            prepare(); doc.keyboardType = type
            check(suggestedEmojis(for: "key").isEmpty, "emoji in restricted field")
        }
        prepare(); doc.isSecureTextEntry = true
        check(suggestedEmojis(for: "key").isEmpty, "emoji in secure field")
        prepare(); doc.text = "user@key"
        check(suggestedEmojis(for: "key").isEmpty, "emoji inside email-like token")
        prepare(); doc.text = "wave"
        UserDefaults.standard.set(["👋": "👋🏽"], forKey: "emoji.tones")
        check(suggestedEmojis(for: "wave").first?.glyph == "👋🏽", "saved skin tone ignored")
        prepare(); contextGeneration += 1; choose("🔑")
        check(doc.text == "a key", "stale generation edited text")
        prepare(); choose("🍕")
        check(doc.text == "a key", "unoffered emoji edited text")
        prepare()
        let heldContext = emojiCandidateContext!.id
        doc.text = "another key"
        _ = suggestedEmojis(for: "key")
        insertSuggestedEmoji("🔑", context: heldContext)
        check(doc.text == "another key", "held suggestion edited a newly bound context")
        prepare(); doc.after = " next"
        _ = suggestedEmojis(for: "key")
        choose("🔑")
        check(doc.text == "a 🔑 " && doc.after == "next", "caret must move past the reused separator")
        doc.insertText("a")
        check(doc.text == "a 🔑 a", "continued typing must remain separated from emoji")
        prepare(); doc.after = "\nnext"
        _ = suggestedEmojis(for: "key")
        choose("🔑")
        check(doc.text == "a 🔑 " && doc.after == "\nnext", "do not consume the following newline")
        prepare(); doc.text = "key"
        glideWord = GlideWord(origin: GlideContext(document: doc.documentIdentifier, before: "", after: ""),
            separator: "", decoderWinner: "key", word: "key", alternatives: ["key", "tea"])
        refreshSuggestions()
        insertSuggestion("tea")
        check(doc.text == "tea" && emojiCandidateContext?.word == "tea", "glide alternative leaves stale emoji")
        let tea = emojiCandidateContext!.choices[0].glyph
        choose(tea)
        check(doc.text == tea + " " && glideWord == nil, "glide emoji replacement")
        print("PASS: emoji replacement, stale context, field exclusions, and skin tone")
    }
}
@main struct EmojiContextCheck {
    @MainActor static func main() {
        let controller = EmojiController()
        controller.checkEmojiContext(controller.doc)
    }
}
