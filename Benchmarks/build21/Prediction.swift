// Runs the same post-blend candidate list used by the keyboard extension.
import Foundation
@main struct Predict {
    struct Row: Decodable { let id: String; let prompt: String }
    static func main() throws {
        let a = CommandLine.arguments
        let decoder = try SentenceDecoder(resources: URL(fileURLWithPath: a[1]))
        let cases = try JSONDecoder().decode([Row].self, from: Data(contentsOf:URL(fileURLWithPath:a[2])))
        let enc = JSONEncoder()
        struct Output: Encodable { let id: String; let guesses: [String] }
        for row in cases {
            try autoreleasepool {
                let result = Output(id:row.id,guesses:try decoder.nextWords(before:row.prompt))
                print(String(decoding:try enc.encode(result),as:UTF8.self))
            }
        }
    }
}
