import Foundation

struct Layout: Decodable {
    struct Key: Decodable { let letter: String, cx: Double, cy: Double }
    let keys: [Key]
}
struct Gesture: Decodable {
    struct Sample: Decodable { let x: Double, y: Double, t: Double }
    let id: Int, data: [Sample]
}
struct Prediction: Encodable {
    let id: Int, words: [String], milliseconds: Double
}
enum ReplayError: Error { case invalidLayout, rejected(Int) }

func guesses(_ gesture: Gesture, on keys: [MBKeyCenter]) throws -> [String] {
    let raw = gesture.data
    guard let start = raw.first, raw.count >= 2 else { return [] }
    let count = min(256, raw.count)
    let samples = (0..<count).map { i -> MBGlideSample in
        let index = Int((Double(i * (raw.count - 1)) / Double(count - 1)).rounded(.toNearestOrEven))
        let point = raw[index]
        return MBGlideSample(x: Float(point.x * 10), y: Float(point.y * 3), seconds: Float((point.t - start.t) / 1000))
    }
    guard samples.contains(where: { hypot($0.x - samples[0].x, $0.y - samples[0].y) >= 1.3 }) else { return [] }
    var output = [CChar](repeating: 0, count: 128)
    let n = mb_glide_v1(keys, keys.count, samples, count, "", &output, output.count)
    guard n >= 0 else { throw ReplayError.rejected(gesture.id) }
    return String(cString: output).split(separator: "\t").map(String.init)
}

let json = JSONDecoder()
let layout = try json.decode(Layout.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var keys = [MBKeyCenter](repeating: MBKeyCenter(), count: 26)
guard Set(layout.keys.map(\.letter)) == Set("abcdefghijklmnopqrstuvwxyz".map(String.init)) else {
    throw ReplayError.invalidLayout
}
for key in layout.keys {
    keys[Int(key.letter.utf8.first!) - 97] = MBKeyCenter(x: Float(key.cx * 10), y: Float(key.cy * 3))
}
let encoder = JSONEncoder()
while let line = readLine() {
    let gesture = try json.decode(Gesture.self, from: Data(line.utf8))
    let start = DispatchTime.now().uptimeNanoseconds
    let words = try guesses(gesture, on: keys)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    let result = Prediction(id: gesture.id, words: words, milliseconds: elapsed)
    print(String(decoding: try encoder.encode(result), as: UTF8.self))
}
