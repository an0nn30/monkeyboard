// Appended to the real controller only in the simulator regression runner.
extension KeyboardViewController {
    fileprivate func exercisePressure(resources: URL, document: ReplayDocument) async throws {
        sentenceResources = resources
        usesTransformer = true
        corrections.preparesTransformerReviews = true
        let text = "meet me there"
        let literal = await sentenceFinisher.review(raw: text, displayed: text, resources: resources, hasHeadroom: { _ in false })
        guard literal == text, !(await sentenceFinisher.isReady) else { throw Failure("cold load despite insufficient headroom") }
        for c in text { press(c == " " ? .space : .type(String(c))) }
        // Use the production actor and compiled weights; make unloading observable.
        _ = await sentenceFinisher.review(raw: text, displayed: text, resources: resources)
        guard await sentenceFinisher.isReady else { throw Failure("precondition: sentence model did not load") }
        let probe = DecoderProbe()
        decoder.submit({ decoder in
            _ = try decoder.nextWords(before: "on my ")
            return decoder
        }) { decoder in probe.value = decoder; probe.didLoad = true }
        for _ in 0..<200 where !probe.didLoad { try await Task.sleep(nanoseconds: 25_000_000) }
        guard probe.value != nil else { throw Failure("precondition: next-word model did not load") }
        printFootprint("with both models")
        didReceiveMemoryWarning()
        for _ in 0..<200 {
            if !(await sentenceFinisher.isReady), probe.value == nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard !(await sentenceFinisher.isReady) else { throw Failure("sentence model retained after memory warning") }
        guard probe.value == nil else { throw Failure("next-word model retained after memory warning") }
        printFootprint("after memory warning")
        guard !usesTransformer, document.text == text else { throw Failure("warning changed draft or left prediction running") }
        for _ in 0..<3 { didReceiveMemoryWarning() }
        for c in " teh " { press(c == " " ? .space : .type(String(c))) }
        guard document.text.lowercased() == text + " the " else { throw Failure("basic autocorrect failed after warning") }
        press(.delete)
        guard document.text.lowercased() == text + " teh" else { throw Failure("undo failed after warning") }
        for c in " in chat." { press(c == " " ? .space : .type(String(c))) }
        try await Task.sleep(nanoseconds: 600_000_000)
        guard document.text.lowercased() == text + " teh in chat.",
              !(await sentenceFinisher.isReady) else { throw Failure("lost text or model reloaded under pressure") }
        let messages = ["we can meet at noon.", "please call me back.", "see you in the morning.", "on my way home."]
        for i in 0..<24 {
            document.text = ""
            textDidChange(nil)
            for c in messages[i % messages.count] { press(c == " " ? .space : .type(String(c))) }
            try await Task.sleep(nanoseconds: 70_000_000) // let the real suggestion strip update
            guard document.text.lowercased() == messages[i % messages.count], probe.value == nil,
                  !(await sentenceFinisher.isReady) else { throw Failure("compact typing failed in message \(i + 1)") }
        }
        print("PASS: 24 more messages with compact suggestions enabled")
        let otherHost = ReplayController()
        otherHost.viewWillAppear(false)
        guard !otherHost.usesTransformer else { throw Failure("changing hosts re-enabled the models") }
        otherHost.press(.type("a"))
        guard otherHost.doc.text.lowercased() == "a" else { throw Failure("new host cannot type") }
    }
}
private final class DecoderProbe { weak var value: SentenceDecoder?; var didLoad = false }
private func printFootprint(_ stage: String) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
    let capacity = Int(count)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    if status == KERN_SUCCESS { print("\(stage): \(info.phys_footprint / 1_048_576) MiB") }
}
private struct Failure: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
@main struct MemoryPressureCheck {
    @MainActor static func main() async {
        do {
            let controller = ReplayController()
            try await controller.exercisePressure(resources: URL(fileURLWithPath: CommandLine.arguments[1]), document: controller.doc)
            print("PASS: models released; typing, correction and undo survived repeated warnings")
        } catch { print("FAIL:", error); exit(1) }
    }
}
