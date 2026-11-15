import Foundation
@main struct Probe {
    struct Input: Decodable { var id: String; var typed: String }
    static func main() async throws {
        let args = CommandLine.arguments
        let rows = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for r in rows {
            let start = Date()
            let out = await SystemProofreader.suggestion(for: r.typed)
            let ms = Int(-start.timeIntervalSinceNow * 1000)
            print(String(decoding:try e.encode(["id":r.id,"final":out ?? r.typed, "ms":String(ms),"available":String(out != nil)]),as:UTF8.self))
            fflush(stdout)
        }
    }
}
