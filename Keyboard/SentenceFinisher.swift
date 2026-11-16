import Foundation
import MonkeyBoardEngine

/// One model instance per keyboard, confined to a background actor. The proxy,
/// selection and editing state stay on the main actor.
actor SentenceFinisher {
    private var lexical: Lexical55?
    private var contextual: Contextual55?
    private var loaded = false
    var isReady: Bool { lexical != nil && contextual != nil }

    func releaseForMemoryPressure() {
        lexical = nil
        contextual = nil
        // This worker must not reload if an already queued review reaches it.
        loaded = true
    }

    func review(raw: String, displayed: String, resources: URL, leading: String = "", atPause: Bool = false,
                hasHeadroom: @Sendable (Int) -> Bool = { _ in true }) -> String {
        // Check on the model's own actor immediately before allocation. A cold
        // load needs room for the 94 MiB encoder, its vocabulary and inference.
        guard !Task.isCancelled, hasHeadroom(isReady ? 32 : 144),
              !raw.contains("@"), !raw.contains("://"), !raw.contains("_") else { return displayed }
        if !loaded {
            lexical = Lexical55(resources: resources)
            contextual = Contextual55(resources: resources)
            loaded = true
        }
        guard let lexical, let contextual else { return displayed }
        let allLetters = raw.filter(\.isLetter)
        // A whole shouted message is different from an acronym embedded in a
        // normal sentence. Score the former as ordinary words, then restore case.
        let shouting = allLetters.count >= 8 && allLetters == allLetters.uppercased() &&
                       raw.split(whereSeparator: \.isWhitespace).count >= 3
        let typed = SentenceSurface.Form(shouting ? raw.lowercased() : raw)
        let prior = shouting ? displayed.lowercased() : displayed
        var text = prior
        var originalByWord = [Int:String]()
        var protected = Set<Int>()
        var lockDistance = [Int:Int]()
        if var words = SentenceSurface.correspondence(typed, prior) {
            var boundaryDecisions = [Int: String]()
            let surface = SentenceSurface.Form(prior)
            if !shouting, words == surface.words {
                let ns = prior as NSString
                for i in words.indices.reversed() {
                    // Revisit the last two words and previously changed spellings.
                    guard i >= words.count - 2 || typed.words[i] != words[i] else { continue }
                    let r = surface.ranges[i]
                    let left = ns.substring(to: r.location), right = ns.substring(from: NSMaxRange(r))
                    let literal = typed.words[i]
                    let alternatives = lexical.boundaryAlternatives(for: literal, left: left)
                    guard !alternatives.isEmpty, words[i] == literal || alternatives.contains(words[i]),
                          let chosen = contextual.boundaryChoice(literal: literal, shown: words[i],
                              left: left, right: right, alternatives: alternatives),
                          chosen == literal || (mb_keep_literal53_v1(left, literal, right, chosen) == 0 &&
                              mb_literal_supported_v1(left, literal, right, chosen) == 0) else { continue }
                    boundaryDecisions[i] = chosen
                }
                if atPause, boundaryDecisions.contains(where: { words[$0.key] != $0.value }) {
                    return surface.replace(boundaryDecisions)
                }
            }
            for i in words.indices {
                if let spelling = boundaryDecisions[i] { words[i] = spelling; continue }
                let literal = typed.words[i], committed = words[i]
                let left = words[..<i].joined(separator:" ")
                let right = words[(i+1)...].joined(separator:" ")
                // Honor prior strong repairs; contextual models see all other
                // words in their already repaired form, including both sides.
                if lexical.protects(literal, left:left, right:right) { words[i] = literal }
                else if literal != committed && (lexical.isLiteralProtected(literal) ||
                    (literal.lowercased() == committed.lowercased() && literal.lowercased() != "i") ||
                    (lexical.isEstablished(literal) &&
                     literal.lowercased().filter(\.isLetter) != committed.lowercased().filter(\.isLetter)) ||
                    (!committed.contains(" ") && (mb_original_name54_v1(literal) == 1 ||
                        mb_keep_literal53_v1(left,literal,right,committed) == 1))) {
                    words[i] = literal
                } else if let fix = lexical.repair(literal, left:left, right:right) {
                    words[i] = fix
                }
            }
            text = typed.replace(Dictionary(uniqueKeysWithValues:words.enumerated().compactMap { i, w in
                w == typed.words[i] ? nil : (i,w)
            }))
            var index = 0
            for (i, word) in words.enumerated() {
                let n = SentenceSurface.Form(word).words.count
                let rawWord = typed.words[i]
                if boundaryDecisions[i] != nil || lexical.protects(rawWord,left:words[..<i].joined(separator:" "),right:words[(i+1)...].joined(separator:" ")) {
                    protected.formUnion(index..<index+n)
                }
                if n == 1, rawWord.lowercased() != word.lowercased(), !lexical.isEstablished(rawWord) {
                    originalByWord[index] = rawWord
                    lockDistance[index] = SentenceSurface.dist(rawWord, word)
                } else if n > 1 && word.replacingOccurrences(of:" ",with:"").lowercased() == rawWord.lowercased() {
                    // The keys exactly account for both halves. Don't replace
                    // either half with a different word as a second correction.
                    protected.formUnion(index..<index+n)
                }
                index += n
            }
        }
        guard !Task.isCancelled else { return displayed }
        // Score the next edit in the sentence the user will actually see.
        // Simultaneous guesses based on an earlier typo can corrupt a neighbor.
        var visited = protected
        for _ in 0..<3 {
            if Task.isCancelled { return displayed }
            let f = SentenceSurface.Form(text)
            let byRange = Dictionary(uniqueKeysWithValues:f.ranges.enumerated().map {($0.element,$0.offset)})
            let edits = contextual.edits(in:text, original:{byRange[$0].flatMap { originalByWord[$0] }}, phonetic:lexical.isPhoneticAlternative, candidates:{ token in
                lexical.isLiteralProtected(token) ? [] : lexical.candidates(for:token,limit:96)
            }).compactMap { e -> (Int, Contextual55.Edit)? in
                guard let i=byRange[e.range], !visited.contains(i) else {return nil}
                if let rawWord=originalByWord[i], let d=lockDistance[i],
                   SentenceSurface.dist(rawWord,e.replacement) > d,
                   !lexical.isKeyboardSequence(rawWord,e.replacement) { return nil }
                return (i,e)
            }
            guard let (i,e)=edits.max(by:{$0.1.gain < $1.1.gain}) else {break}
            text = f.replace([i:e.replacement])
            visited.insert(i)
            if edits.count == 1 {break}
        }
        let proposed = shouting ? text.uppercased() : text
        return SentenceSurface.restoringContractions(in: raw, proposed: proposed, leading: leading)
    }
}
