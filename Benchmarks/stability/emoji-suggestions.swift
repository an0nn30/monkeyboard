import Foundation
import Darwin

@main struct EmojiSuggestionCheck {
    static func main() throws {
        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let initial = footprint()
        let index = EmojiPredictionIndex(source: source, maximumVersion: 17)
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            if !value { failures += 1; print("FAIL: \(message)") }
        }
        func glyphs(_ word: String) -> [String] { index.matches(word).map(\.glyph) }
        check(glyphs("key") == ["🔑", "🔐"], "key should show the reference pair")
        check(glyphs("KEY") == glyphs("key"), "case-insensitive matches")
        check(glyphs("keys").first == "🔑", "plural keys")
        check(glyphs("coffee").first == "☕", "coffee")
        check(glyphs("pizza").first == "🍕", "pizza")
        check(glyphs("love").first == "❤️", "love")
        for literal in ["", "k", "ke", "cof", "the", "and", "is", "not", "keyhole", "abcxyz", "123"] {
            check(glyphs(literal).isEmpty, "irrelevant or incomplete word: \(literal)")
        }
        let old = EmojiPredictionIndex(source: source, maximumVersion: 15.1)
        check(!old.matches("shovel").contains { $0.glyph == "🪏" }, "unsupported version")
        let wave = try XCTlessUnwrap(index.matches("wave").first { $0.glyph == "👋" })
        check(wave.variants.contains("👋🏽"), "supported skin tones")
        let loaded = footprint()
        let start = Date()
        for _ in 0..<10000 { _ = index.matches("key"); _ = index.matches("coffee") }
        print("Index footprint delta: \(loaded - initial) bytes; 20,000 lookups: \(Date().timeIntervalSince(start))s; footprint after: \(footprint() - initial) bytes")
        print("Emoji suggestion checks: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return info.phys_footprint
    }
    static func XCTlessUnwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "Missing expected emoji", code: 1) }
        return value
    }
}
