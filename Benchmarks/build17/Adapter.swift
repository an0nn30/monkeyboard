// Compiled alongside the keyboard controller, only by the simulator benchmark.
// Record the document after each real key handler; drain model work at boundaries.
final class ReplayDocument: NSObject, UITextDocumentProxy {
    var text = ""
    let documentIdentifier = UUID()
    var documentContextBeforeInput: String? { text.isEmpty ? nil : text }
    var documentContextAfterInput: String? { "" }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { !text.isEmpty }
    func insertText(_ value: String) { text += value }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) { preconditionFailure() }
    func setMarkedText(_ markedText: String, selectedRange: NSRange) { preconditionFailure() }
    func unmarkText() {}
}
final class ReplayController: KeyboardViewController {
    let doc = ReplayDocument()
    override var textDocumentProxy: any UITextDocumentProxy { doc }
}
final class ReplayWorker {
    var model: SentenceDecoder!
    func submit<T>(_ work: (SentenceDecoder) throws -> T, completion: (T) -> Void) -> Operation {
        do { completion(try work(model)) } catch { fatalError("Decoder failed: \(error)") }
        return Operation()
    }
}
extension KeyboardViewController {
    func prepare(_ engine: SentenceDecoder, resources: URL) {
        sentenceResources = resources
        decoder.model = engine
        usesTransformer = true
        corrections.preparesTransformerReviews = true
        model.needsGlobe = true
        board.onLetterGeometry = { [weak self] in self?.corrections.neighborMasks = $0 }
        board.frame = CGRect(x: 0, y: 0, width: 393, height: 250)
        board.update(model, returnTitle: nil)
        board.layoutIfNeeded()
    }
    func replay(_ text: String) {
        abandonSentence()
        discardReview()
        lastCorrection = nil
        keptSpelling = nil
        for ch in text + " " {
            press(ch == " " ? .space : ch == "\n" ? .enter : .type(String(ch)))
        }
    }
}
extension KeyboardViewController {
    func replayWithPauses(_ text: String, pause: UInt64) async {
        abandonSentence(); discardReview(); lastCorrection = nil; keptSpelling = nil
        for ch in text + " " {
            press(ch == " " ? .space : ch == "\n" ? .enter : .type(String(ch)))
            try? await Task.sleep(nanoseconds:(ch == " " ? pause : 30) * 1_000_000)
        }
    }
    func settleSentence() async { await sentenceTask?.value }
    func loadedSentenceModel() async -> Bool { await sentenceFinisher.isReady }
}
@main struct Replay {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let engine = try SentenceDecoder(resources: URL(fileURLWithPath: args[1]))
        let keyboard = ReplayController()
        keyboard.prepare(engine, resources:URL(fileURLWithPath:args[1]))
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath:args[2])))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var latency = [Double]()
        for (i, row) in rows.enumerated() {
            let start = ProcessInfo.processInfo.systemUptime
            keyboard.doc.text = ""
            if let pause = ProcessInfo.processInfo.environment["MB_REPLAY_WORD_PAUSE_MS"].flatMap(UInt64.init) {
                await keyboard.replayWithPauses(row.typed, pause:pause)
            } else {
                autoreleasepool { keyboard.replay(row.typed) }
            }
            await keyboard.settleSentence()
            latency.append(1000 * (ProcessInfo.processInfo.systemUptime - start))
            try autoreleasepool {
                precondition(keyboard.doc.text.hasSuffix(" "))
                let bytes = try encoder.encode(["id":row.id,"final":String(keyboard.doc.text.dropLast())])
                print(String(decoding: bytes, as: UTF8.self))
            }
            if i % 20 == 0 { fflush(stdout) }
        }
        if ProcessInfo.processInfo.environment["MB_REQUIRE_SENTENCE_MODEL"] == "1" {
            let ready = await keyboard.loadedSentenceModel()
            precondition(ready,"Integrated sentence model or lexical resource failed to load")
        }
        if ProcessInfo.processInfo.environment["MB_REPLAY_TIMING"] == "1", !latency.isEmpty {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let sorted = latency.sorted()
            let sample = ["median_message_ms":sorted[sorted.count/2], "p95_message_ms":sorted[Int(Double(sorted.count-1)*0.95)],
                          "peak_process_rss_bytes":Double(usage.ru_maxrss)]
            FileHandle.standardError.write(try encoder.encode(sample))
            FileHandle.standardError.write(Data([10]))
        }
    }
    struct Row: Decodable { let id: String; let typed: String }
}
