import UIKit
import MonkeyBoardEngine

private extension UITextDocumentProxy {
    // During host transitions UIKit can return nil from this nonnull ObjC getter.
    // Read the object before bridging it to Swift's UUID.
    var attachedDocumentID: UUID? {
        perform(#selector(getter: UITextDocumentProxy.documentIdentifier))?.takeUnretainedValue() as? UUID
    }
}

private final class ClickInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController {
    private let board = KeyboardView()
    private var model = KeyboardModel()
    private var prefersSplit = true
    private var preferredHand = OneHandedLayout.fullWidth
    private var hingeClosed: Bool?
    private var allowsOneHanded = true
    private let corrections = WordCorrections()
    private struct WordEdit {
        let document: UUID
        let original: String
        let replacement: String
        let delimiter: String
        let leading: String
        let following: String
    }
    // A review only follows text inserted by this instance of the keyboard.
    private struct PendingReview {
        let id = UUID()
        let document: UUID
        let request: SentenceDecoder.Review
        let anchor: String
        let committed: String
        var suffix: String
    }
    private let decoder = DecoderWorker()
    private var usesTransformer = false
    private var pendingReview: PendingReview?
    private var revisionTask: Operation?
    private var deferredReview: PendingReview?
    private var nextWordTask: Operation?
    private struct GlideContext: Equatable {
        let document: UUID
        let before: String
        let after: String
    }
    private struct GlideWord {
        let origin: GlideContext
        let separator: String
        let word: String
        let alternatives: [String]
        var inserted: String { separator + word }
        var expected: GlideContext {
            GlideContext(document: origin.document, before: String((origin.before + inserted).suffix(160)), after: origin.after)
        }
    }
    private var glideEnabled = true
    private var glideStartGeneration: Int?
    private var glideFieldEligible = false
    private var glideWord: GlideWord?
    private var lastCorrection: WordEdit?
    private var keptSpelling: String?
    private struct OwnedRun {
        let document: UUID
        let anchor: String
        var raw = ""
        var rendered = ""
    }
    private var run: OwnedRun?
    private struct SentenceInput {
        let id = UUID(), document: UUID, anchor: String
        var raw = "", rendered = ""
        var ended = false
    }
    private var sentenceInput: SentenceInput?
    private var sentenceTask: Task<Void, Never>?
    private let sentenceFinisher = SentenceFinisher()
    private var sentenceResources = Bundle.main.resourceURL

    private var autoCorrect = true
    private var returnAfterSymbol = true
    private var openedSymbolsFromLetters = false
    #if MONKEYBOARD_SOUND_BENCHMARK
    private let soundProbe = SoundFootprintProbe()
    #endif
    private let typingSound = TypingSoundPlayer()
    private lazy var feedback = KeypressPlayer(view: board)
    private var strength = KeypressFeedback.initial
    private var lastShift: TimeInterval?
    private var accentColor: UIColor?
    private var keyboardFont = KeyboardFont.system
    private var lastSelectedWordShift: KeyboardModel.Shift?
    private var height: NSLayoutConstraint?
    private var candidateDocument: UUID?
    private var candidateContext = ""
    private var candidatePrefix = ""
    private var candidateGeneration = 0
    private var candidateWords: [String] = []
    private var suggestionTask: DispatchWorkItem?
    private var contextGeneration = 0
    private var contextNeedsSetup = true

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        typingSound.select(.off)
    }

    override func loadView() {
        inputView = ClickInputView(frame: .zero, inputViewStyle: .keyboard)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // UIKit supplies the rounded keyboard material beyond the extension's bounds.
        // Painting another rectangle here exposes its top and bottom edges on Duo.
        view.backgroundColor = .clear
        view.isOpaque = false
        board.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(board)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            board.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            board.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            board.topAnchor.constraint(equalTo: view.topAnchor),
            board.bottomAnchor.constraint(equalTo: safe.bottomAnchor)
        ])
        let height = view.heightAnchor.constraint(equalToConstant: 250 + board.extraHeightBelowKeys)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        self.height = height
        board.configureGlobe = { [weak self] button in
            guard let self else { return }
            button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        board.onLetterGeometry = { [weak self] in self?.corrections.neighborMasks = $0 }
        board.onKey = { [weak self] key in self?.press(key) }
        board.onGlideStart = { [weak self] in
            guard let self, self.glideEnabled, self.glideFieldEligible else { return false }
            self.glideStartGeneration = self.contextGeneration
            return true
        }
        board.onGlide = { [weak self] stroke in self?.commitGlide(stroke) ?? false }
        board.onTouch = { [weak self] key in self?.playFeedback(key.soundKey) }
        board.onWord = { [weak self] word in self?.insertSuggestion(word) }
        board.onDismiss = { [weak self] in self?.dismissKeyboard() }
        board.onExpand = { [weak self] in self?.chooseHand(.fullWidth) }
        board.onAvailableWidthChange = { [weak self] width in self?.applyLayout(width: width) }
        if #available(iOS 27.1, *) {
            board.addInteraction(UIHingeInteraction { [weak self] _, update in
                guard let self else { return }
                let closed: Bool?
                switch update.hinge?.status {
                case .closed: closed = true
                case .fullyOpen, .partiallyOpen: closed = false
                default: closed = nil
                }
                guard closed != self.hingeClosed else { return }
                self.hingeClosed = closed
                self.applyLayout(width: self.board.bounds.width)
            })
        }
        board.onToggleLayout = { [weak self] in
            guard let self else { return }
            let next = !self.prefersSplit
            guard WideKeyboardLayout.setSplit(next) else { return }
            self.prefersSplit = next
            self.applyLayout(width: self.board.bounds.width, animated: true)
        }
        // iOS can load the extension before it attaches a text document.
        board.update(model, returnTitle: nil)
        requestSupplementaryLexicon { [weak self] lexicon in
            DispatchQueue.main.async { self?.corrections.use(lexicon) }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        accentColor = KeyboardTint.stored()?.keyColor
        keyboardFont = .stored
        prefersSplit = WideKeyboardLayout.prefersSplit
        model.repeatSplitLetters = WideKeyboardLayout.repeatsLetters
        preferredHand = OneHandedSetting.storedValue.flatMap(OneHandedLayout.init(rawValue:)) ?? .fullWidth
        glideEnabled = GlideTypingSetting.isEnabled
        autoCorrect = AutoCorrectionSetting.isEnabled
        returnAfterSymbol = ReturnAfterSymbolSetting.isEnabled
        corrections.usesSentenceContext = SentenceScoringSetting.isEnabled
        usesTransformer = corrections.usesSentenceContext && TransformerSetting.isEnabled
        corrections.preparesTransformerReviews = usesTransformer
        applyLayout(width: board.bounds.width)
        let sound = TypingSound.stored
        #if MONKEYBOARD_SOUND_BENCHMARK
        soundProbe.start(in: view, sound: sound, fullAccess: hasFullAccess)
        #endif
        typingSound.select(sound != .off && hasFullAccess ? sound : .off)
        strength = KeypressFeedback.keyboardPercent()
        updateOptionsMenu()
        refreshContext()
        feedback.prepare(strength)
    }

    private func applyLayout(width: CGFloat, animated: Bool = false) {
        guard width > 0 else { return }
        // Remote keyboard hosts may not provide hinge updates. Fall back to
        // the same width boundary that separates the joined and split layouts.
        let cover = hingeClosed ?? (width < KeyboardView.minimumSplitWidth)
        let split = !cover && width >= KeyboardView.minimumSplitWidth && prefersSplit
        let hand = cover ? preferredHand : .fullWidth
        allowsOneHanded = cover
        updateOptionsMenu()
        guard split != model.isSplit || hand != model.oneHanded else { return }
        model.isSplit = split
        model.oneHanded = hand
        updateKeys(animateLayout: animated)
    }

    private func chooseHand(_ hand: OneHandedLayout) {
        guard allowsOneHanded else { return }
        preferredHand = hand
        _ = OneHandedSetting.save(hand.rawValue)
        applyLayout(width: board.bounds.width, animated: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        typingSound.select(.off)
        glideWord = nil
        glideStartGeneration = nil
        abandonSentence()
        run = nil
        board.resetTouches()
        discardReview()
        nextWordTask?.cancel()
        lastCorrection = nil
        keptSpelling = nil
        suggestionTask?.cancel()
        contextNeedsSetup = true
        contextGeneration += 1
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if model.needsGlobe != needsInputModeSwitchKey {
            model.needsGlobe = needsInputModeSwitchKey
            updateKeys()
        }
        let compact = traitCollection.verticalSizeClass == .compact
        height?.constant = (compact ? 193 : 250) + board.extraHeightBelowKeys + view.safeAreaInsets.bottom
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        contextGeneration += 1
        validateReview()
        refreshContext()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        contextGeneration += 1
        validateReview()
        refreshContext()
    }

    private func refreshContext() {
        let proxy = textDocumentProxy
        switch proxy.keyboardAppearance ?? .default {
        case .dark: board.overrideUserInterfaceStyle = .dark
        case .light: board.overrideUserInterfaceStyle = .light
        default: board.overrideUserInterfaceStyle = .unspecified
        }
        glideFieldEligible = allowsWordSuggestions && !insideWord
        let kind = proxy.keyboardType ?? .default
        if contextNeedsSetup || kind != model.keyboardType {
            contextNeedsSetup = false
            openedSymbolsFromLetters = false
            model.keyboardType = kind
            model.layer = .initial(for: kind)
            view.setNeedsLayout()
            model.shift = .lower
            lastShift = nil
            lastSelectedWordShift = nil
            applyAutoCase()
        }
        // Hosts can report a selection through either input delegate callback.
        // Only change Shift on a transition so the user can still toggle it by hand.
        let selectionShift = selectedWordShift()
        if selectionShift != lastSelectedWordShift {
            lastSelectedWordShift = selectionShift
            lastShift = nil
            applyAutoCase(replacing: selectionShift)
        }
        model.needsGlobe = needsInputModeSwitchKey
        updateKeys()
        scheduleSuggestions()
    }

    private func selectedWordShift() -> KeyboardModel.Shift? {
        let proxy = textDocumentProxy
        guard let text = proxy.selectedText else { return nil }
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.contains(where: \.isWhitespace),
              let first = word.first(where: { $0.isUppercase || $0.isLowercase }) else { return nil }
        switch proxy.autocapitalizationType ?? .none {
        case .sentences, .words: return first.isUppercase ? .upper : .lower
        case .allCharacters: return .upper
        default: return .lower
        }
    }

    private func applyAutoCase(replacing selectionShift: KeyboardModel.Shift? = nil) {
        guard model.shift != .locked else { return }
        if let selectionShift {
            model.shift = selectionShift
            return
        }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let upper: Bool
        switch textDocumentProxy.autocapitalizationType ?? .none {
        case .allCharacters: upper = true
        case .words: upper = before.isEmpty || before.last?.isWhitespace == true
        case .sentences:
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            upper = trimmed.isEmpty || before.last?.isNewline == true ||
                (before.last?.isWhitespace == true && trimmed.last.map { ".!?".contains($0) } == true)
        default: upper = false
        }
        model.shift = upper ? .upper : .lower
    }

    private func glideContext() -> GlideContext? {
        let proxy = textDocumentProxy
        guard glideEnabled, model.layer == .letters, allowsWordSuggestions, !insideWord,
              let before = proxy.documentContextBeforeInput ?? (proxy.hasText ? nil : "") else { return nil }
        return GlideContext(document: proxy.documentIdentifier, before: String(before.suffix(160)),
                            after: String((proxy.documentContextAfterInput ?? "").prefix(32)))
    }

    private func commitGlide(_ stroke: GlideStroke) -> Bool {
        defer { glideStartGeneration = nil }
        // A focus or cursor change while the finger is down cancels this input.
        guard glideStartGeneration == contextGeneration, let origin = glideContext() else { return true }
        let keys = stroke.decodingCenters.map { MBKeyCenter(x: Float($0.x/stroke.pitch.width), y: Float($0.y/stroke.pitch.height)) }
        let points = stroke.samples.map { MBGlideSample(x: Float($0.point.x/stroke.pitch.width),
                                                        y: Float($0.point.y/stroke.pitch.height), seconds: Float($0.seconds)) }
        var buffer = [CChar](repeating: 0, count: 128)
        guard !origin.before.utf8.contains(0),
              mb_glide_v1(keys, keys.count, points, points.count, origin.before, &buffer, buffer.count) > 0 else { return false }
        let casing = textDocumentProxy.autocapitalizationType
        let needsSpace = origin.before.last.map { $0.isLetter || $0.isNumber || ".,!?;:)]}".contains($0) } ?? false
        let autoUpper = lastShift == nil && needsSpace && (casing == .words ||
            (casing == .sentences && origin.before.last.map { ".!?".contains($0) } == true))
        let options = String(cString: buffer).split(separator: "\t").map { token -> String in
            let word = String(token)
            if model.shift == .locked { return word.uppercased() }
            if model.shift == .upper || autoUpper || word.hasPrefix("i'") { return word.prefix(1).uppercased() + word.dropFirst() }
            return word
        }
        guard let word = options.first else { return false }
        let receipt = GlideWord(origin: origin, separator: needsSpace ? " " : "", word: word, alternatives: options)
        abandonSentence()
        discardReview()
        run = nil
        lastCorrection = nil
        keptSpelling = nil
        suggestionTask?.cancel()
        nextWordTask?.cancel()
        lastShift = nil
        textDocumentProxy.insertText(receipt.inserted)
        glideWord = receipt
        board.setSuggestions(options)
        applyAutoCase()
        updateKeys()
        return true
    }

    private func handleKeyAfterGlide(_ key: Key) -> Bool {
        guard let receipt = glideWord else { return false }
        guard receipt.expected == glideContext() else { glideWord = nil; return false }
        switch key {
        case .shift: return false
        case .space, .rightSpace, .enter: keptSpelling = receipt.word
        case let .type(mark) where [".", ",", "!", "?", ";", ":"].contains(mark): keptSpelling = receipt.word
        case .delete:
            glideWord = nil
            for _ in receipt.inserted { textDocumentProxy.deleteBackward() }
            applyAutoCase()
            updateKeys()
            scheduleSuggestions()
            return true
        case let .type(letter) where letter.first?.isLetter == true:
            textDocumentProxy.insertText(" ")
        default: break
        }
        glideWord = nil
        return false
    }

    private func press(_ key: Key) {
        if handleKeyAfterGlide(key) { return }
        // Numeric fields edit the host selection literally, including a localized decimal separator.
        if model.layer == .keypad {
            switch key {
            case let .type(value): textDocumentProxy.insertText(value)
            case .delete: textDocumentProxy.deleteBackward()
            default: break
            }
            return
        }
        let snapshot = beginSentenceKey(key)
        defer { if let snapshot { finishSentenceKey(snapshot) } }
        validateReview()
        nextWordTask?.cancel()
        if key != .shift { lastShift = nil }
        if key != .delete { lastCorrection = nil }
        switch key {
        case .shift:
            let now = ProcessInfo.processInfo.systemUptime
            if let lastShift, now - lastShift < 0.36 {
                model.shift = .locked
                self.lastShift = nil
            } else {
                model.shift = model.shift == .lower ? .upper : .lower
                lastShift = now
            }
        case .layer:
            openedSymbolsFromLetters = model.layer == .letters
            model.layer = openedSymbolsFromLetters ? .numbers : .letters
        case .symbols: model.layer = model.layer == .numbers ? .symbols : .numbers
        case .globe: run = nil; advanceToNextInputMode()
        case .delete:
            run = nil
            discardReview()
            let replacementShift = selectedWordShift()
            // Collapsing this selection is part of Delete. Keep its spelling case
            // for the next letter even if the new caret is at the start of a sentence.
            lastSelectedWordShift = nil
            if !undoCorrection() { textDocumentProxy.deleteBackward(); keptSpelling = nil }
            applyAutoCase(replacing: replacementShift)
        case let .type(value):
            if [".", ",", "!", "?", ";", ":"].contains(value) { insertDelimiter(value) }
            else {
                if pendingReview?.suffix.contains(where: { ".!?\n".contains($0) }) == true { discardReview() }
                deferredReview?.suffix += value
                pendingReview?.suffix += value
                recordKey(value)
                textDocumentProxy.insertText(value)
                keptSpelling = nil
            }
            if openedSymbolsFromLetters && returnAfterSymbol {
                model.layer = .letters
                openedSymbolsFromLetters = false
            }
            applyAutoCase()
        case .space, .rightSpace: insertDelimiter(" "); applyAutoCase()
        case .enter: insertDelimiter("\n"); applyAutoCase()
        }
        updateKeys()
        scheduleSuggestions()
    }

    private func updateKeys(animateLayout: Bool = false) {
        let title: String?
        switch textDocumentProxy.returnKeyType ?? .default {
        case .done: title = "Done"
        case .go: title = "Go"
        case .search, .google, .yahoo: title = "Search"
        case .send: title = "Send"
        case .next: title = "Next"
        case .join: title = "Join"
        case .route: title = "Route"
        case .continue: title = "Continue"
        default: title = nil
        }
        board.update(model, returnTitle: title, accentColor: accentColor, font: keyboardFont, animateLayout: animateLayout)
    }

    private func playFeedback(_ key: TypingSoundKey = .regular) {
        feedback.play(strength)
        #if MONKEYBOARD_SOUND_BENCHMARK
        soundProbe.tap(played: typingSound.play(key))
        #else
        typingSound.play(key)
        #endif
    }

    private func updateOptionsMenu() {
        let actions = KeypressFeedback.presets.map { level in
            UIAction(title: level.name, state: level.percent == strength ? .on : .off) { [weak self] _ in
                guard let self else { return }
                guard KeypressFeedback.save(level.percent) else { return }
                self.strength = level.percent
                self.updateOptionsMenu()
                self.playFeedback()
            }
        }
        let value = KeypressFeedback.label(strength)
        let feedback = UIMenu(title: "Keypress Feedback", children: actions)
        feedback.subtitle = value
        var sections = [UIMenuElement]()
        if allowsOneHanded {
            let positions = OneHandedLayout.allCases.map { hand in
                UIAction(title: hand.title, state: hand == preferredHand ? .on : .off) { [weak self] _ in
                    self?.chooseHand(hand)
                }
            }
            sections.append(UIMenu(title: "One-handed typing", options: .displayInline, children: positions))
        }
        sections.append(feedback)
        board.setOptionsMenu(UIMenu(children: sections), feedbackValue: value,
                             showsSplitToggle: !allowsOneHanded && board.bounds.width >= KeyboardView.minimumSplitWidth)
    }

    private func abandonSentence() {
        sentenceTask?.cancel()
        sentenceTask = nil
        sentenceInput = nil
    }

    private struct KeySnapshot {
        var input: SentenceInput
        let leading: String, character: String
    }

    private func beginSentenceKey(_ key: Key) -> KeySnapshot? {
        let c: String
        switch key {
        case let .type(x): c = x
        case .space, .rightSpace: c = " "
        case .enter: c = "\n"
        case .shift, .layer, .symbols: return nil
        default: abandonSentence(); return nil
        }
        let proxy = textDocumentProxy
        guard usesTransformer, autoCorrect, allowsWordSuggestions,
              (proxy.documentContextAfterInput ?? "").isEmpty,
              let before = proxy.documentContextBeforeInput ?? (proxy.hasText ? nil : ""),
              c.count == 1 else { abandonSentence(); return nil }
        let boundary = c.first!.isWhitespace
        if let old = sentenceInput,
           old.document != proxy.documentIdentifier || !before.hasSuffix(old.anchor + old.rendered) ||
           old.raw.utf8.count >= 240 {
            abandonSentence()
        }
        guard let input = sentenceInput ?? (!boundary && c.first!.isLetter &&
                (before.isEmpty || before.last!.isWhitespace || ".!?".contains(before.last!))
                ? SentenceInput(document:proxy.documentIdentifier,anchor:String(before.suffix(24))) : nil)
        else { return nil }
        // A later word can change the result; never apply an old prediction over it.
        if !(input.ended && boundary) { sentenceTask?.cancel() }
        return KeySnapshot(input:input,leading:String(before.dropLast(input.rendered.count)),character:c)
    }

    private func finishSentenceKey(_ snapshot: KeySnapshot) {
        let proxy = textDocumentProxy
        var input = snapshot.input
        guard proxy.documentIdentifier == input.document, let after = proxy.documentContextBeforeInput,
              after.hasPrefix(snapshot.leading) else { abandonSentence(); return }
        input.raw += snapshot.character
        input.rendered = String(after.dropFirst(snapshot.leading.count))
        if ".!?\n".contains(snapshot.character) { input.ended = true }
        else if !snapshot.character.first!.isWhitespace { input.ended = false }
        sentenceInput = input
        if snapshot.character.first!.isWhitespace || input.ended {
            // Keep a pending punctuation review when the next key is just a space.
            if snapshot.input.ended && sentenceTask != nil { return }
            queueSentence(input)
        }
    }

    private func queueSentence(_ input: SentenceInput) {
        let raw = String(input.raw.drop(while: { $0.isWhitespace })).trimmingCharacters(in:.whitespacesAndNewlines)
        let displayed = input.rendered.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let url = sentenceResources, raw.contains(where: { $0.isWhitespace }),
              !displayed.isEmpty, corrections.allowsLearnedEdits(in: raw, leading: input.anchor) else { return }
        let finisher = sentenceFinisher
        sentenceTask = Task { [weak self] in
            if !input.ended {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let next = await finisher.review(raw:raw, displayed:displayed, resources:url, leading:input.anchor)
            guard !Task.isCancelled, next != displayed, let self,
                  var current = self.sentenceInput, current.id == input.id,
                  current.rendered.hasPrefix(displayed), self.autoCorrect, self.usesTransformer,
                  self.allowsWordSuggestions else { return }
            let tail = String(current.rendered.dropFirst(displayed.count))
            let proxy = self.textDocumentProxy
            guard tail.allSatisfy({$0.isWhitespace}), proxy.documentIdentifier == current.document,
                  (proxy.documentContextAfterInput ?? "").isEmpty,
                  proxy.documentContextBeforeInput?.hasSuffix(current.anchor + current.rendered) == true else {return}
            let prefix = zip(displayed,next).prefix(while: { $0==$1 }).count
            let old = String(displayed.dropFirst(prefix))+tail
            let new = String(next.dropFirst(prefix))+tail
            self.discardReview()
            self.run = nil
            for _ in old {proxy.deleteBackward()}
            proxy.insertText(new)
            self.lastCorrection = WordEdit(document:current.document,original:old,replacement:new,delimiter:"",
                                          leading:String((current.anchor+displayed.prefix(prefix)).suffix(32)),following:"")
            current.rendered = next+tail
            self.sentenceInput = current
            self.scheduleSuggestions()
        }
    }

    private func prefix() -> String {
        guard let before = textDocumentProxy.documentContextBeforeInput else { return "" }
        return String(before.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" }.reversed())
    }

    private var allowsWordSuggestions: Bool {
        let proxy = textDocumentProxy
        guard proxy.autocorrectionType != .no, proxy.isSecureTextEntry != true,
              (proxy.selectedText ?? "").isEmpty else { return false }
        switch proxy.keyboardType ?? .default {
        case .default, .asciiCapable, .webSearch, .twitter: break
        default: return false
        }
        let excluded: [UITextContentType] = [.username, .password, .newPassword, .oneTimeCode, .name,
                                            .givenName, .familyName, .nickname, .middleName, .organizationName,
                                            .emailAddress, .URL, .creditCardNumber, .telephoneNumber]
        if let kind = proxy.textContentType, let kind, excluded.contains(kind) { return false }
        return true
    }

    private var insideWord: Bool {
        guard let next = textDocumentProxy.documentContextAfterInput?.first else { return false }
        return next.isLetter || next.isNumber || "_'’@".contains(next)
    }

    private func recordKey(_ value: String) {
        let proxy = textDocumentProxy
        guard usesTransformer, autoCorrect, allowsWordSuggestions,
              (proxy.documentContextAfterInput ?? "").isEmpty,
              // Some UIKit fields return nil, rather than "", until their first
              // character. Only claim that boundary if the host confirms it is empty.
              let before = proxy.documentContextBeforeInput ?? (proxy.hasText ? nil : ""),
              value.count == 1, value.first.map({ $0.isLetter || $0.isNumber || "'’-".contains($0) }) == true else {
            run = nil
            return
        }
        if let old = run, old.document != proxy.documentIdentifier || !before.hasSuffix(old.anchor + old.rendered) { run = nil }
        if run == nil {
            guard before.isEmpty || before.last.map({ $0.isWhitespace || ".!?".contains($0) }) == true else { return }
            run = OwnedRun(document: proxy.documentIdentifier, anchor: String(before.suffix(32)))
        }
        run?.raw += value
        run?.rendered += value
        if (run?.raw.utf8.count ?? 0) > 180 { run = nil }
    }

    private func rememberBoundary(_ word: String, committed: String, delimiter: String) {
        guard [" ", ",", ";", ":"].contains(delimiter), !word.isEmpty, let old = run, old.rendered.hasSuffix(word) else { run = nil; return }
        run?.rendered = String(old.rendered.dropLast(word.count)) + committed + delimiter
        run?.raw += delimiter
        if old.raw.split(separator: " ").count >= 12 { run = nil }
    }

    // Keep the caller's document/ownership checks around every suffix edit. These
    // helpers only see keystrokes entered by this keyboard in the current field.
    private struct SentenceProposal { let text: String; let rawAfterJoin: String? }

    private func proposedSentence(_ span: OwnedRun, word: String, baseline: WordCorrections.Choices) -> SentenceProposal? {
        let prediction = predictedSentence(span, word: word, baseline: baseline)
        guard corrections.allowsLearnedEdits(in: span.raw, leading: span.anchor) else { return prediction }
        let current = prediction?.text ?? span.rendered
        let text = SentenceSurface.restoringContractions(in: span.raw, proposed: current, leading: span.anchor)
        guard text != current else { return prediction }
        // The ordinary commit path handles an active-word-only correction and undo.
        if prediction == nil, span.rendered.hasSuffix(word) {
            let last = baseline.automatic ?? word
            let ordinary = String(span.rendered.dropLast(word.count)) + last
            if text == ordinary { return nil }
            if text.hasSuffix(" " + word), last != word {
                return SentenceProposal(text: String(text.dropLast(word.count)) + last, rawAfterJoin: nil)
            }
        }
        return SentenceProposal(text: text, rawAfterJoin: prediction?.rawAfterJoin)
    }

    private func predictedSentence(_ span: OwnedRun, word: String, baseline: WordCorrections.Choices) -> SentenceProposal? {
        let fallback = corrections.learnedSentence(raw: span.raw, leading: span.anchor, rendered: span.rendered,
                                                   word: word, baseline: baseline)
        let standard = fallback.map { SentenceProposal(text: $0, rawAfterJoin: nil) }
        guard corrections.allowsLearnedEdits(in: span.raw, leading: span.anchor), !word.isEmpty,
              span.raw.hasSuffix(word), span.rendered.hasSuffix(word) else { return standard }
        let raw = span.raw.components(separatedBy: " ")
        let displayed = span.rendered.components(separatedBy: " ")
        guard raw.last == word, displayed.last == word else { return standard }
        if raw.count >= 2, displayed.count == raw.count {
            let i = raw.count - 2, a = raw[i], b = word
            let left = span.anchor + raw[..<i].joined(separator: " ")
            let joined = a + b
            if mb_rejoin53_v1(a, b) == 1,
               mb_keep_literal53_v1(left, a, b, joined) == 0,
               mb_keep_literal53_v1(left + " " + a, b, "", joined) == 0 {
                // Retain independent corrections before the two fragments. Rebase
                // only the consumed boundary so a later review can't recreate it.
                let text = (Array(displayed[..<i]) + [joined]).joined(separator: " ")
                let rebased = (Array(raw[..<i]) + [joined]).joined(separator: " ")
                return SentenceProposal(text: text, rawAfterJoin: rebased)
            }
        }

        // Prefer an existing model's repair. The residual ranker gets the
        // uncorrected tokens with up to two following words, including the
        // current token at punctuation; never align across an earlier split.
        var target = (fallback ?? span.rendered).components(separatedBy: " ")
        guard raw.count == target.count, displayed.count == raw.count else { return standard }
        var changed = false
        for i in max(0, raw.count - 3)..<raw.count {
            let literal = raw[i]
            guard (2...26).contains(literal.utf8.count), literal.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'") }) else { continue }
            let left = span.anchor + target[..<i].joined(separator: " ")
            let right = target[(i + 1)...].joined(separator: " ")
            var out = [CChar](repeating: 0, count: 100)
            let contextual = mb_context53_v1(left, literal, right, &out, out.count) == 1
            if !contextual {
                guard mb_residual53_v1(left, literal, right, &out, out.count) == 1,
                      !corrections.isRecognizedSpelling(literal) else { continue }
            }
            let guess = String(cString: out)
            guard mb_residual_name54_v1(literal, guess) == 0 else { continue }
            guard guess != literal, !guess.isEmpty, mb_keep_literal53_v1(left, literal, right, guess) == 0,
                  mb_literal_supported_v1(left, literal, right, guess) == 0 else { continue }
            let priorChoice = (i == raw.count - 1 && fallback == nil ? baseline.automatic : nil) ?? target[i]
            if priorChoice != literal || displayed[i] != literal {
                // A spelling heuristic can discard half a welded token, e.g. a
                // complete word plus its neighbor. Restore both only if their
                // letters exactly reconstruct the raw input and one of those
                // two words is the complete, previously committed guess.
                let parts = guess.lowercased().split(separator: " ")
                let prior = priorChoice != literal ? priorChoice : displayed[i]
                guard parts.count == 2, parts.joined() == literal.lowercased(),
                      parts.contains(Substring(prior.lowercased())) else { continue }
            }
            target[i] = guess
            changed = true
        }
        if changed {
            // The fallback nil path previously applied the active word's ordinary
            // automatic correction at commit; don't lose it to an earlier repair.
            if fallback == nil, let automatic = baseline.automatic, target.last == word {
                target[target.count - 1] = automatic
            }
            return SentenceProposal(text: target.joined(separator: " "), rawAfterJoin: nil)
        }
        return standard
    }

    private func insertDelimiter(_ delimiter: String) {
        let proxy = textDocumentProxy
        let word = prefix()
        defer { keptSpelling = nil }
        guard autoCorrect, allowsWordSuggestions, !insideWord, word != keptSpelling,
              let before = proxy.documentContextBeforeInput else {
            run = nil
            discardReview()
            proxy.insertText(delimiter)
            return
        }
        let choices = corrections.choices(for: word, before: before, includeCompletions: false)
        if let old = run, !word.isEmpty, old.document == proxy.documentIdentifier,
           before.hasSuffix(old.anchor + old.rendered), (proxy.documentContextAfterInput ?? "").isEmpty,
           let proposal = proposedSentence(old, word: word, baseline: choices) {
            let next = proposal.text
            // Only rewrite the changed suffix. The common prefix stays in place
            // so the host's formatting and undo history survive.
            let common = zip(old.rendered, next).prefix(while: { $0 == $1 }).count
            let prior = String(old.rendered.dropFirst(common)), replacement = String(next.dropFirst(common))
            discardReview()
            if !prior.isEmpty || !replacement.isEmpty {
                let earlierWordChanged = common < max(0, old.rendered.count - word.count)
                lastCorrection = WordEdit(document: old.document, original: prior + (earlierWordChanged ? delimiter : ""), replacement: replacement,
                                          delimiter: delimiter, leading: String((old.anchor + old.rendered.prefix(common)).suffix(32)), following: "")
            }
            for _ in prior { proxy.deleteBackward() }
            proxy.insertText(replacement + delimiter)
            if [" ", ",", ";", ":"].contains(delimiter) && old.raw.split(separator: " ").count < 12 {
                run?.rendered = next + delimiter
                run?.raw = (proposal.rawAfterJoin ?? old.raw) + delimiter
            } else { run = nil }
            return
        }
        if let old = run, old.document != proxy.documentIdentifier || !before.hasSuffix(old.anchor + old.rendered) { run = nil }
        let committed = choices.automatic ?? word
        let leading = before.dropLast(word.count)
        let anchor = String(leading.suffix(32))
        if committed != word {
            lastCorrection = WordEdit(document: proxy.documentIdentifier, original: word, replacement: committed,
                                      delimiter: delimiter, leading: anchor,
                                      following: String((proxy.documentContextAfterInput ?? "").prefix(20)))
        }
        func appendBoundary(to pending: inout PendingReview?) {
            guard let old = pending else { return }
            if !word.isEmpty, old.suffix.hasSuffix(word) {
                pending?.suffix = String(old.suffix.dropLast(word.count)) + committed + delimiter
            } else {
                pending?.suffix += delimiter
            }
        }
        appendBoundary(to: &pendingReview)
        appendBoundary(to: &deferredReview)
        if committed != word {
            for _ in word { proxy.deleteBackward() }
            proxy.insertText(committed + delimiter)
        } else { proxy.insertText(delimiter) }

        rememberBoundary(word, committed: committed, delimiter: delimiter)
        guard usesTransformer else { return }
        let extending = pendingReview != nil
        if delimiter == " ", (!choices.reviewAlternatives.isEmpty || choices.reviewsShortWord), (proxy.documentContextAfterInput ?? "").isEmpty {
            let review = SentenceDecoder.Review(typed: word, leading: String(leading.suffix(4096)),
                                                alternatives: choices.reviewAlternatives, shortWord: choices.reviewsShortWord, missingLetterOnly: choices.missingLetterOnly)
            let entry = PendingReview(document: proxy.documentIdentifier, request: review,
                                      anchor: anchor, committed: committed, suffix: delimiter)
            if extending { deferredReview = entry } else { pendingReview = entry }
        }
        if extending, !word.isEmpty {
            // At a sentence end both the older and the newer candidate have
            // received their final right-hand context.
            requestRevision()
        }
    }

    private func finishReview() {
        revisionTask?.cancel()
        revisionTask = nil
        pendingReview = deferredReview
        deferredReview = nil
        validateReview()
        if let pending = pendingReview, pending.suffix.last.map({ $0.isWhitespace || ".!?".contains($0) }) == true,
           !pending.suffix.trimmingCharacters(in: .whitespaces).isEmpty {
            requestRevision()
        }
    }

    private func discardReview() {
        deferredReview = nil
        revisionTask?.cancel()
        revisionTask = nil
        pendingReview = nil
    }

    private func validateReview() {
        guard let pending = pendingReview else { return }
        let proxy = textDocumentProxy
        if !allowsWordSuggestions || proxy.documentIdentifier != pending.document ||
            !(proxy.documentContextAfterInput ?? "").isEmpty || pending.suffix.count > 80 ||
            proxy.documentContextBeforeInput?.hasSuffix(pending.anchor + pending.committed + pending.suffix) != true {
            discardReview()
        }
    }

    private func requestRevision() {
        guard let pending = pendingReview else { return }
        let right = pending.suffix.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let count = right.split(whereSeparator: { $0.isWhitespace }).count
        guard (1...pending.request.followingWordLimit).contains(count), !right.contains(where: { ".,!?;:\n".contains($0) }) else {
            finishReview()
            return
        }
        revisionTask?.cancel()
        revisionTask = decoder.submit({ model in
            try model.revision(pending.request, committed: pending.committed, following: right)
        }) { [weak self] replacement in
            guard let self else { return }
            self.validateReview()
            guard let current = self.pendingReview, current.id == pending.id,
                  current.suffix.hasPrefix(pending.suffix) else { return }
            guard let replacement,
                  mb_literal_supported_v1(pending.request.leading, pending.request.typed, right, replacement) == 0,
                  (pending.request.typed.lowercased() == replacement.lowercased() || mb_original_name54_v1(pending.request.typed) == 0),
                  mb_keep_literal53_v1(pending.request.leading, pending.request.typed, right, replacement) == 0,
                  replacement.compare(pending.request.typed, options: .diacriticInsensitive) != .orderedSame else {
                if count >= pending.request.followingWordLimit || pending.suffix.last.map({ ".!?".contains($0) }) == true { self.finishReview() }
                return
            }
            self.discardReview()
            let proxy = self.textDocumentProxy
            let oldTail = current.committed + current.suffix
            let newTail = replacement + current.suffix
            for _ in oldTail { proxy.deleteBackward() }
            proxy.insertText(newTail)
            if let full = self.sentenceInput, full.document == current.document, full.rendered.hasSuffix(oldTail) {
                self.sentenceInput?.rendered = String(full.rendered.dropLast(oldTail.count)) + newTail
            }
            if let old = self.run, old.document == current.document, old.rendered.hasSuffix(oldTail) {
                self.run?.rendered = String(old.rendered.dropLast(oldTail.count)) + newTail
            } else { self.run = nil }
            // Restore the old spelling AND everything typed since then on Undo.
            self.lastCorrection = WordEdit(document: current.document, original: oldTail, replacement: newTail,
                                           delimiter: "", leading: current.anchor, following: "")
            self.scheduleSuggestions()
        }
    }

    private func undoCorrection() -> Bool {
        let proxy = textDocumentProxy
        guard let edit = lastCorrection else { return false }
        lastCorrection = nil
        let inserted = edit.replacement + edit.delimiter
        guard proxy.documentIdentifier == edit.document, (proxy.selectedText ?? "").isEmpty,
              proxy.documentContextBeforeInput?.hasSuffix(edit.leading + inserted) == true,
              String((proxy.documentContextAfterInput ?? "").prefix(20)) == edit.following else { return false }
        for _ in inserted { proxy.deleteBackward() }
        proxy.insertText(edit.original)
        keptSpelling = prefix()
        return true
    }

    private func scheduleSuggestions() {
        nextWordTask?.cancel()
        suggestionTask?.cancel()
        guard model.layer != .keypad else { return }
        // Keep dictionary work out of the touch-down and key-commit paths.
        let task = DispatchWorkItem { [weak self] in self?.refreshSuggestions() }
        suggestionTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: task)
    }

    private func refreshSuggestions() {
        let proxy = textDocumentProxy
        guard let document = proxy.attachedDocumentID else {
            candidateDocument = nil
            candidateWords = []
            board.setSuggestions([])
            return
        }
        if let receipt = glideWord {
            if receipt.expected == glideContext() {
                board.setSuggestions(receipt.alternatives)
                return
            }
            glideWord = nil
        }
        candidateDocument = document
        candidateContext = String((proxy.documentContextBeforeInput ?? "").suffix(160))
        candidatePrefix = prefix()
        candidateGeneration = contextGeneration
        candidateWords = []
        if model.layer == .letters && !insideWord && allowsWordSuggestions {
            if candidatePrefix.isEmpty {
                candidateWords = corrections.nextWords(before: candidateContext)
                if usesTransformer {
                    let context = candidateContext
                    nextWordTask = decoder.submit({ try $0.nextWords(before: context) }) { [weak self] words in
                        guard let self, !words.isEmpty, self.allowsWordSuggestions, !self.insideWord,
                              self.model.layer == .letters,
                              self.textDocumentProxy.attachedDocumentID == document,
                              String((self.textDocumentProxy.documentContextBeforeInput ?? "").suffix(160)) == context
                        else { return }
                        self.candidateWords = words
                        self.board.setSuggestions(words)
                    }
                }
            } else if candidatePrefix.count <= 40 {
                let choices = corrections.choices(for: candidatePrefix, before: textDocumentProxy.documentContextBeforeInput ?? "",
                                                  includeCompletions: true)
                candidateWords = [candidatePrefix] + choices.suggestions
            }
        }
        board.setSuggestions(candidateWords)
    }

    private func insertSuggestion(_ word: String) {
        let proxy = textDocumentProxy
        if let receipt = glideWord {
            guard receipt.expected == glideContext(), receipt.alternatives.contains(word) else {
                glideWord = nil
                refreshSuggestions()
                return
            }
            if word != receipt.word {
                for _ in receipt.word { proxy.deleteBackward() }
                proxy.insertText(word)
                glideWord = GlideWord(origin: receipt.origin, separator: receipt.separator,
                                      word: word, alternatives: receipt.alternatives)
            }
            return
        }
        guard allowsWordSuggestions, candidateGeneration == contextGeneration, candidateWords.contains(word),
              candidateDocument == proxy.documentIdentifier,
              candidateContext == String((proxy.documentContextBeforeInput ?? "").suffix(160)), !insideWord,
              prefix() == candidatePrefix, (proxy.selectedText ?? "").isEmpty,
              proxy.documentContextAfterInput?.first?.isLetter != true else { refreshSuggestions(); return }
        abandonSentence()
        run = nil
        discardReview()
        lastCorrection = nil
        keptSpelling = nil
        for _ in candidatePrefix { proxy.deleteBackward() }
        proxy.insertText(word + " ")
        applyAutoCase()
        updateKeys()
        scheduleSuggestions()
    }
}


#if MONKEYBOARD_SOUND_BENCHMARK
// Only compiled for the hardware A/B test. No typed text is inspected or saved.
@MainActor private final class SoundFootprintProbe: UILabel {
    private var taps = 0, submissions = 0
    private var baseline: UInt64 = 0, peak: UInt64 = 0
    private var mode = "", access = false

    func start(in view: UIView, sound: TypingSound, fullAccess: Bool) {
        if superview == nil {
            frame = CGRect(x: 2, y: 2, width: 2, height: 2)
            isAccessibilityElement = true
            accessibilityIdentifier = "sound-footprint-probe"
            accessibilityLabel = "Typing benchmark"
            view.addSubview(self)
        }
        taps = 0; submissions = 0; mode = sound.title; access = fullAccess
        baseline = footprint(); peak = baseline
        publish(baseline)
    }

    func tap(played: Bool) {
        taps += 1
        if played { submissions += 1 }
        let bytes = footprint()
        peak = max(peak, bytes)
        publish(bytes)
    }

    private func publish(_ bytes: UInt64) {
        accessibilityValue = "\(mode)|\(access)|\(getpid())|\(taps)|\(submissions)|\(baseline)|\(peak)|\(bytes)"
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let capacity = Int(n)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
#endif
