import UIKit

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
    private var lastCorrection: WordEdit?
    private var keptSpelling: String?
    private var autoCorrect = true
    private var returnAfterSymbol = true
    private var openedSymbolsFromLetters = false
    private lazy var feedback = KeypressPlayer(view: board)
    private var strength = KeypressFeedback.initial
    private var lastShift: TimeInterval?
    private var height: NSLayoutConstraint?
    private var candidateDocument: UUID?
    private var candidateContext = ""
    private var candidatePrefix = ""
    private var candidateGeneration = 0
    private var candidateWords: [String] = []
    private var suggestionTask: DispatchWorkItem?
    private var contextGeneration = 0
    private var contextNeedsSetup = true

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
        let height = view.heightAnchor.constraint(equalToConstant: 250)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        self.height = height
        board.configureGlobe = { [weak self] button in
            guard let self else { return }
            button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        board.onLetterGeometry = { [weak self] in self?.corrections.neighborMasks = $0 }
        board.onKey = { [weak self] key in self?.press(key) }
        board.onTouch = { [weak self] in self?.playFeedback() }
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
        prefersSplit = WideKeyboardLayout.prefersSplit
        preferredHand = OneHandedSetting.storedValue.flatMap(OneHandedLayout.init(rawValue:)) ?? .fullWidth
        autoCorrect = AutoCorrectionSetting.isEnabled
        returnAfterSymbol = ReturnAfterSymbolSetting.isEnabled
        corrections.usesSentenceContext = SentenceScoringSetting.isEnabled
        usesTransformer = corrections.usesSentenceContext && TransformerSetting.isEnabled
        corrections.preparesTransformerReviews = usesTransformer
        applyLayout(width: board.bounds.width)
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
        let compact = traitCollection.verticalSizeClass == .compact
        height?.constant = (compact ? 193 : 250) + view.safeAreaInsets.bottom
        if model.needsGlobe != needsInputModeSwitchKey {
            model.needsGlobe = needsInputModeSwitchKey
            updateKeys()
        }
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
        scheduleSuggestions()
    }

    private func refreshContext() {
        let proxy = textDocumentProxy
        switch proxy.keyboardAppearance ?? .default {
        case .dark: board.overrideUserInterfaceStyle = .dark
        case .light: board.overrideUserInterfaceStyle = .light
        default: board.overrideUserInterfaceStyle = .unspecified
        }
        let kind = proxy.keyboardType ?? .default
        if contextNeedsSetup || kind != model.keyboardType {
            contextNeedsSetup = false
            openedSymbolsFromLetters = false
            model.keyboardType = kind
            model.layer = [.numbersAndPunctuation, .numberPad, .decimalPad, .asciiCapableNumberPad].contains(kind) ? .numbers : .letters
            model.shift = .lower
            lastShift = nil
            applyAutoCase()
        }
        model.needsGlobe = needsInputModeSwitchKey
        updateKeys()
        scheduleSuggestions()
    }

    private func applyAutoCase() {
        guard model.shift != .locked else { return }
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

    private func press(_ key: Key) {
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
        case .globe: advanceToNextInputMode()
        case .delete:
            discardReview()
            if !undoCorrection() { textDocumentProxy.deleteBackward(); keptSpelling = nil }
            applyAutoCase()
        case let .type(value):
            if [".", ",", "!", "?", ";", ":"].contains(value) { insertDelimiter(value) }
            else {
                if pendingReview?.suffix.contains(where: { ".!?\n".contains($0) }) == true { discardReview() }
                deferredReview?.suffix += value
                pendingReview?.suffix += value
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
        board.update(model, returnTitle: title, animateLayout: animateLayout)
    }

    private func playFeedback() {
        feedback.play(strength)
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

    private func insertDelimiter(_ delimiter: String) {
        let proxy = textDocumentProxy
        let word = prefix()
        defer { keptSpelling = nil }
        guard autoCorrect, allowsWordSuggestions, !insideWord, word != keptSpelling,
              let before = proxy.documentContextBeforeInput else {
            discardReview()
            proxy.insertText(delimiter)
            return
        }
        let choices = corrections.choices(for: word, before: before, includeCompletions: false)
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

        guard usesTransformer else { return }
        let extending = pendingReview != nil
        if delimiter == " ", !choices.reviewAlternatives.isEmpty, (proxy.documentContextAfterInput ?? "").isEmpty {
            let review = SentenceDecoder.Review(typed: word, leading: String(leading.suffix(4096)),
                                                alternatives: choices.reviewAlternatives)
            let entry = PendingReview(document: proxy.documentIdentifier, request: review,
                                      anchor: anchor, committed: committed, suffix: delimiter)
            if extending { deferredReview = entry } else { pendingReview = entry }
        }
        if extending, !word.isEmpty { requestRevision() }
    }

    private func finishReview() {
        revisionTask?.cancel()
        revisionTask = nil
        pendingReview = deferredReview
        deferredReview = nil
        validateReview()
        if let pending = pendingReview, pending.suffix.last?.isWhitespace == true,
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
            guard let replacement else {
                if count >= pending.request.followingWordLimit { self.finishReview() }
                return
            }
            self.discardReview()
            let proxy = self.textDocumentProxy
            let oldTail = current.committed + current.suffix
            let newTail = replacement + current.suffix
            for _ in oldTail { proxy.deleteBackward() }
            proxy.insertText(newTail)
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
        keptSpelling = edit.original
        return true
    }

    private func scheduleSuggestions() {
        nextWordTask?.cancel()
        suggestionTask?.cancel()
        // Keep dictionary work out of the touch-down and key-commit paths.
        let task = DispatchWorkItem { [weak self] in self?.refreshSuggestions() }
        suggestionTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: task)
    }

    private func refreshSuggestions() {
        let proxy = textDocumentProxy
        candidateDocument = proxy.documentIdentifier
        candidateContext = String((proxy.documentContextBeforeInput ?? "").suffix(160))
        candidatePrefix = prefix()
        candidateGeneration = contextGeneration
        candidateWords = []
        if model.layer == .letters && !insideWord && allowsWordSuggestions {
            if candidatePrefix.isEmpty {
                candidateWords = corrections.nextWords(before: candidateContext)
                if usesTransformer {
                    let context = candidateContext
                    let document = candidateDocument
                    nextWordTask = decoder.submit({ try $0.nextWords(before: context) }) { [weak self] words in
                        guard let self, !words.isEmpty, self.allowsWordSuggestions, !self.insideWord,
                              self.model.layer == .letters, self.textDocumentProxy.documentIdentifier == document,
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
        guard allowsWordSuggestions, candidateGeneration == contextGeneration, candidateWords.contains(word),
              candidateDocument == proxy.documentIdentifier,
              candidateContext == String((proxy.documentContextBeforeInput ?? "").suffix(160)), !insideWord,
              prefix() == candidatePrefix, (proxy.selectedText ?? "").isEmpty,
              proxy.documentContextAfterInput?.first?.isLetter != true else { refreshSuggestions(); return }
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
