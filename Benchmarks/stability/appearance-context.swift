// Appended to the real controller by appearance-context.sh; only the host proxy is a fake.
private final class AppearanceDocument: NSObject, UITextDocumentProxy {
    var keyboardAppearance = UIKeyboardAppearance.light
    var documentIdentifier = UUID()
    var documentContextBeforeInput: String? { "key" }
    var documentContextAfterInput: String? { "" }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { true }
    func insertText(_ text: String) {}
    func deleteBackward() {}
    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}
}
private final class AppearanceController: KeyboardViewController {
    let doc = AppearanceDocument()
    override var textDocumentProxy: any UITextDocumentProxy { doc }
}
extension KeyboardViewController {
    fileprivate func checkAppearance() {
        func flush(_ view: UIView) {
            view.updateTraitsIfNeeded()
            view.subviews.forEach(flush)
        }
        _ = view
        view.frame = CGRect(x: 0, y: 0, width: 655, height: 291)
        for style in KeyboardStyle.allCases {
            model.style = style
            for appearance in [UIUserInterfaceStyle.light, .dark, .light] {
                view.overrideUserInterfaceStyle = appearance
                flush(view)
                // A live host appearance change need not deliver a new text context.
                if appearance == .light { refreshContext() }
                for layer in [KeyboardModel.Layer.letters, .numbers, .symbols, .keypad] {
                    model.layer = layer
                    updateKeys()
                    flush(view)
                    board.layoutIfNeeded()
                    flush(view)
                    precondition(board.traitCollection.userInterfaceStyle == appearance,
                                 "Keyboard retained a stale appearance override")
                }
                // Even a later edit may still carry the host's previous light value.
                refreshContext()
                flush(view)
                precondition(board.traitCollection.userInterfaceStyle == appearance,
                             "Text refresh restored stale appearance")
            }
        }
        print("PASS: live light/dark/light inheritance, both styles and all keyboard pages")
    }
}
@main struct AppearanceContextCheck {
    @MainActor static func main() {
        let controller = AppearanceController()
        controller.checkAppearance()
    }
}
