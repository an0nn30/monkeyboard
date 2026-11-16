// Compiled with the real controller on the simulator. The document is an
// in-memory English text field. A punctuation key commits each completed sentence.
private extension KeyboardViewController {
    func startReplay(_ document: ReplayDocument, mode: Bool, resources: URL) {
        abandonSentence()
        discardReview()
        nextWordTask?.cancel()
        suggestionTask?.cancel()
        lastCorrection = nil
        keptSpelling = nil
        run = nil
        document.text = ""
        document.autocorrectionType = mode ? .yes : .no
        sentenceResources = resources
        autoCorrect = true
        usesTransformer = true
        corrections.usesSentenceContext = true
        corrections.preparesTransformerReviews = true
        model = KeyboardModel()
        applyAutoCase()
    }

    func sendTarget(_ key: String, nearbyLetters: UInt32 = 0) -> Bool {
        switch key {
        case "drop": break
        case "delete": press(.delete)
        case "shift", "caps lock": press(.shift)
        case "return": press(.enter)
        case " ": press(.space)
        case _ where key.count == 1:
            let letter = Key.type(model.shift == .lower ? key : key.uppercased())
            #if MB_SPATIAL_CORRECTION
            press(letter, nearbyLetters: nearbyLetters)
            #else
            press(letter)
            #endif
        default: return false  // The input surface changed. Count the incomplete message.
        }
        return true
    }

    func checkPronoun(_ doc: ReplayDocument, resources: URL) throws {
        for mode in [false, true] {
            func prepare(_ text: String) {
                startReplay(doc, mode: mode, resources: resources)
                doc.text = text
                applyAutoCase()
            }
            for delimiter in [" ", ",", ".", "!", "?", "\n"] {
                prepare("when i")
                press(delimiter == " " ? .space : delimiter == "\n" ? .enter : .type(delimiter))
                guard doc.text == "when I" + delimiter else { throw CheckFailure(doc.text) }
                press(.delete)
                guard doc.text == "when i" else { throw CheckFailure("Undo: " + doc.text) }
                press(.space)
                guard doc.text == "when i " else { throw CheckFailure("Recommit: " + doc.text) }
            }
            for literal in ["ski", "inside", "api_i", "mail@i", "the variable i"] {
                prepare(literal)
                press(.space)
                guard doc.text == literal + " " else { throw CheckFailure(doc.text) }
            }
            for kind in [UIKeyboardType.URL, .emailAddress] {
                prepare("i")
                doc.keyboardType = kind
                press(.space)
                guard doc.text == "i " else { throw CheckFailure(doc.text) }
                doc.keyboardType = .default
            }
        }
    }

    func settleReplay() async { await sentenceTask?.value }

    func configureReplayLayout(_ layout: String) {
        loadViewIfNeeded()
        // Supply the geometry explicitly, independent of the simulator's hinge or saved preference.
        board.onAvailableWidthChange = nil
        board.removeFromSuperview()
        board.translatesAutoresizingMaskIntoConstraints = true
        model.isSplit = layout == "wide split"
        let frame = CGRect(x: 0, y: 0, width: layout == "cover" ? 466 : 951, height: 289)
        board.frame = frame
        board.update(model, returnTitle: nil)
        board.layoutIfNeeded()
        precondition(board.bounds.size == frame.size, "Keyboard has not reached its test layout")
    }

    func sendRelease(_ point: ReplayRelease) -> Bool {
        board.layoutIfNeeded()
        let (key, mask) = board.resolveReplayRelease(point)
        return sendTarget(key, nearbyLetters: mask)
    }

    func checkOppositeEdges(_ document: ReplayDocument, resources: URL) async throws {
        func releaseAtVEdge(_ side: CGFloat) throws {
            board.layoutIfNeeded()
            guard let v = board.subviews.compactMap({ $0 as? UIButton })
                .first(where: { $0.accessibilityLabel?.lowercased() == "v" && $0.isUserInteractionEnabled }) else {
                throw CheckFailure("Missing V key")
            }
            let face = board.keycapFrame(of: v)
            // Both taps are inside V. The two releases lean toward opposite neighbors.
            _ = sendRelease(ReplayRelease(x: face.midX + side * 0.48 * face.width, y: face.midY, radius: 10))
        }
        for autocorrect in [false, true] {
            for (intended, side) in [("cook", -1.0), ("book", 1.0)] {
                startReplay(document, mode: autocorrect, resources: resources)
                configureReplayLayout("cover")
                for key in "we can " { _ = sendTarget(String(key)) }
                try releaseAtVEdge(side)
                for key in "ook" { _ = sendTarget(String(key)) }
                guard document.text == "We can vook" else { throw CheckFailure("Raw input: " + document.text) }
                _ = sendTarget(".")
                await settleReplay()
                let expected = "We can " + (autocorrect ? intended : "vook") + "."
                guard document.text == expected else { throw CheckFailure("Expected \(expected), observed \(document.text)") }
            }
        }

        // The opening needs the verb on its right. Resolve the W-facing edge
        // of E while preserving the earlier raw spelling for sentence review.
        startReplay(document, mode: true, resources: resources)
        configureReplayLayout("cover")
        for key in "lets " { _ = sendTarget(String(key)) }
        board.layoutIfNeeded()
        guard let e = board.subviews.compactMap({ $0 as? UIButton }).first(where: {
            $0.accessibilityLabel?.lowercased() == "e" && $0.isUserInteractionEnabled
        }) else { throw CheckFailure("Missing E key") }
        let face = board.keycapFrame(of: e)
        _ = sendRelease(ReplayRelease(x: face.midX - 0.48 * face.width, y: face.midY, radius: 10))
        for key in "atch" { _ = sendTarget(String(key)) }
        guard document.text == "Lets eatch" else { throw CheckFailure("Raw input: " + document.text) }
        _ = sendTarget(".")
        guard sentenceInput?.raw == "Lets watch.", let review = sentenceTask else {
            throw CheckFailure("Sentence review lost the preceding text or touch repair: " + (sentenceInput?.raw ?? "<missing>"))
        }
        await review.value
        let deadline = ContinuousClock.now + .seconds(10)
        while document.text != "Let's watch.", pendingReview != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard document.text == "Let's watch." else { throw CheckFailure("Settled text: " + document.text) }

        for (ending, expected) in [(" a room", " a room"), (" a room tomorow", " a room tomorrow")] {
            startReplay(document, mode: true, resources: resources)
            configureReplayLayout("cover")
            for key in "magbe i can " { _ = sendTarget(String(key)) }
            try releaseAtVEdge(-1)
            for key in "ook" + ending + "." { _ = sendTarget(String(key)) }
            await settleReplay()
            guard document.text == "Maybe I can cook" + expected + "." else {
                throw CheckFailure("Full-sentence review after further input: " + document.text)
            }
        }
        #if MB_SPATIAL_CORRECTION
        // A release resolved the third letter of this occurrence. Later
        // spelling evidence may disagree at other letters of the same word.
        var raw = "Fine sard"
        var letters = [Int: Int]()
        guard TouchReplacement(typed: "sard", committed: "sand").apply(to: &raw, protecting: &letters) else {
            throw CheckFailure("Could not record the synthetic substitution")
        }
        for (proposal, expected) in [("Fine said", "Fine sand"), ("Fine send", "Fine send"),
                                     ("Fine sold", "Fine sold"), ("Fine sands", "Fine sands")] {
            let result = SentenceSurface.keepingTouchSpellings(letters, from: raw, in: proposal)
            guard result == expected else { throw CheckFailure("Expected \(expected) for \(proposal), got \(result ?? "<unaligned>")") }
        }
        #endif
    }
}

private struct CheckFailure: Error {
    let observed: String
    init(_ text: String) { observed = text }
}

@main private struct FingerSentences {
    struct Input: Decodable {
        struct Row: Decodable {
            let seed: UInt64
            let profile, layout: String
            let targets, guardedTargets: [[String]]
            let circularTargets: [[String]]?
            let releases: [[ReplayRelease]]?
        }
        let sentences: [String]
        let results: [Row]
    }
    struct Record: Encodable {
        let sentence: Int, seed: UInt64, profile: String, layout: String, mode: String
        let expected, observed: String
        let completed: Bool
    }
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let resources = URL(fileURLWithPath: args[1])
        if args[2] == "--check-direction" {
            let keyboard = ReplayController()
            try await keyboard.checkOppositeEdges(keyboard.doc, resources: resources)
            print("PASS: opposite V edges, autocorrect on and off, and an earlier-word review after a touch repair")
            return
        }
        if args[2] == "--check-pronoun" {
            let keyboard = ReplayController()
            try keyboard.checkPronoun(keyboard.doc, resources: resources)
            print("PASS: standalone pronoun, six delimiters, Backspace, recommit, literal tokens and URL/email fields, autocorrect on and off")
            return
        }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let policy = args[3]
        precondition(["live", "circular", "guarded", "point"].contains(policy))
        let seed = UInt64(args[4])!
        let keyboard = ReplayController()
        let encoder = JSONEncoder()
        for row in input.results where row.seed == seed {
            let histories: [[String]]
            switch policy {
            case "circular": histories = row.circularTargets!
            case "guarded": histories = row.guardedTargets
            default: histories = row.targets
            }
            precondition(histories.count == input.sentences.count)
            for (i, sequence) in histories.enumerated() {
                let sentence = input.sentences[i]
                precondition(sequence.count == sentence.count + 1)
                let words = sentence.components(separatedBy: " ").map { $0 == "i" ? "I" : $0 }
                let canonical = words.joined(separator: " ")
                let expected = canonical.prefix(1).uppercased() + canonical.dropFirst() + "."
                for mode in [false, true] {
                    keyboard.startReplay(keyboard.doc, mode: mode, resources: resources)
                    var complete = true
                    if policy == "live" {
                        keyboard.configureReplayLayout(row.layout)
                        guard let taps = row.releases?[i], taps.count == sequence.count else { throw CheckFailure("Missing release coordinates") }
                        for point in taps.dropLast() {
                            if !keyboard.sendRelease(point) { complete = false; break }
                        }
                    } else {
                        for key in sequence.dropLast() {
                            if !keyboard.sendTarget(key) { complete = false; break }
                        }
                    }
                    if complete { _ = keyboard.sendTarget(".") }
                    await keyboard.settleReplay()
                    let record = Record(sentence: i, seed: seed, profile: row.profile, layout: row.layout,
                                        mode: mode ? "on" : "off", expected: expected, observed: keyboard.doc.text, completed: complete)
                    print(String(decoding: try encoder.encode(record), as: UTF8.self))
                }
            }
            fflush(stdout)
        }
    }
}
