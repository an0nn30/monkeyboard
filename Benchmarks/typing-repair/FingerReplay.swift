import UIKit
import MonkeyBoardEngine

// A seed fixes the intended text, per-message bias, tap centers and contact ellipses.
private struct RandomStream {
    var state: UInt64
    mutating func unit() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var x = state
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        return (Double((x ^ (x >> 31)) >> 11) + 0.5) / 9_007_199_254_740_992
    }
    mutating func normal() -> Double {
        sqrt(-2 * log(unit())) * cos(2 * .pi * unit())
    }
}

private enum Profile: String, CaseIterable { case center, everyday, edge }
private struct Tap: Encodable {
    let key: String
    let dx, dy, radiusX, radiusY, angle: Double
    var controlX = 0.5, controlY = 0.5
}

private func sample(_ key: String, profile: Profile, bias: CGPoint, rng: inout RandomStream) -> Tap {
    var x = bias.x + 0.22 * rng.normal()
    var y = bias.y + 0.20 * rng.normal()
    if profile == .edge {
        // Straddle either side of a vertical or horizontal edge, including gaps.
        let edge = (rng.unit() < 0.5 ? -1.0 : 1.0) * (0.48 + 0.13 * rng.normal())
        if rng.unit() < 0.6 { x = edge } else { y = edge }
    }
    return Tap(key: key, dx: profile == .center ? 0 : x, dy: profile == .center ? 0 : y,
               radiusX: 7 + 7 * rng.unit(), radiusY: 11 + 8 * rng.unit(), angle: (rng.unit() - 0.5) * 1.2)
}

private let originalSentences = [
    "meet me by the red door", "can you pick up some milk", "we left the keys at home",
    "the train is ten minutes late", "please put my bag in the car", "text me when you get here",
    "i have a book on hold", "could you grab lunch on the way", "i just fed the dog",
    "the kids are still at school", "is there a leek in the soup", "we saw a leak under the sink",
    "the blue bike needs a new tire", "my jacket is on the chair", "did you bring the tickets",
    "come by the quiet cafe", "the next bus goes to the zoo", "please check the front desk",
    "the quiz starts after lunch", "do you want pizza or rice", "i can bring an extra mug",
    "the shop is open till six", "the big box is in the hall", "let us meet by the west gate",
]

private let freshSentences = [
    "maybe i can cook", "we found your blue scarf", "save a seat for us",
    "when i finish we can walk", "the bus will come soon", "leave it near the lamp",
    "can you feed the cat first", "my train arrives at eight", "i can take a later bus",
    "she left her coat upstairs", "grab a towel on your way", "we need one more chair",
    "keep the green folder here", "the coffee is almost ready", "he said i could call",
    "please carry my lunch inside", "your keys are by the plant", "turn left after the bridge",
    "we should pack before dark", "did you order the soup", "this time i remembered",
    "send me a photo of the rug", "please bring the spare charger", "we can share the last slice",
]

private struct Face {
    let key: String
    let rect, control: CGRect
}

private struct Score: Encodable {
    var attempts = 0, pointCorrect = 0, areaCorrect = 0, dropped = 0
    var sharedAreaCorrect = 0, sharedAreaGains = 0, sharedAreaLosses = 0
    var areaGains = 0, areaLosses = 0, multipleFaces = 0, intendedMajority = 0, majorityMissed = 0
    var circularCorrect = 0
    var guardedCorrect = 0, guardedGains = 0, guardedLosses = 0
    var confusions: [String: Int] = [:]
}

private struct Row: Encodable {
    let layout, profile: String
    let seed: UInt64
    let score: Score
    let targets, guardedTargets, circularTargets: [[String]]
    let releases: [[ReplayRelease]]
}
private struct Fixture: Encodable {
    let profile: String
    let seed: UInt64
    let text: String
    let taps: [Tap]
}
private struct Result: Encodable {
    let sentences: [String]
    let results: [Row]
    let fixtures: [Fixture]
    let calibration: [String: Int]
    let disagreements: [EdgeChange]
}

private struct EdgeChange: Encodable {
    let layout, profile: String
    let seed: UInt64
    let sentence, offset: Int
    let intended, point, overlap: String
    let x, y: CGFloat
    let source: String
    let capDistance: CGFloat
    let pointVotes, winnerVotes, coveredVotes: Int
    let insideWindow: Bool
    let guarded: String
}


@main private struct FingerReplay {
    // Equal-area samples of the contact patch. Empty space between visible caps
    // remains empty; a 60% majority means 60% of the entire ellipse.
    static let disk = KeyboardContact.samples
    static func overlap(_ center: CGPoint, _ tap: Tap, _ faces: [Face]) -> [String: Int] {
        KeyboardContact.coverage(at: center, radiusX: tap.radiusX, radiusY: tap.radiusY,
                                 angle: tap.angle, faces: faces.map { ($0.key, $0.rect) })
    }

    static func predictedInitials(_ history: String) -> [Character] {
        guard history.last == " " else { return [] }
        var buffer = [CChar](repeating: 0, count: 256)
        guard mb_rank_v1(String(history.suffix(160)), "", nil, &buffer, buffer.count) >= 0 else { return [] }
        return String(cString: buffer).lowercased().split(separator: "\t").prefix(2).compactMap(\.first)
    }

    static func apply(_ key: String, to history: inout String) {
        if key.count == 1 { history += key }
        else if key == "delete" { if !history.isEmpty { history.removeLast() } }
        else if key == "return" { history += "\n" }
        else if key != "drop" { history = "" }
    }

    @MainActor static func main() throws {
        var inputs = Array(CommandLine.arguments.dropFirst())
        var sentences = originalSentences
        if let flag = inputs.firstIndex(of: "--corpus") {
            guard inputs.indices.contains(flag + 1) else { throw NSError(domain: "Expected a sentence file after --corpus", code: 1) }
            sentences = try String(contentsOfFile: inputs[flag + 1], encoding: .utf8)
                .split(whereSeparator: \.isNewline).map(String.init)
            let alphabet = "abcdefghijklmnopqrstuvwxyz "
            guard !sentences.isEmpty, Set(sentences).count == sentences.count,
                  sentences.allSatisfy({ text in
                      text.first?.isLetter == true && text.last?.isLetter == true &&
                      text.allSatisfy(alphabet.contains) && !text.contains("  ")
                  }) else { throw NSError(domain: "Expected unique lowercase English sentences, one per line", code: 1) }
            inputs.removeSubrange(flag...(flag + 1))
        } else if let flag = inputs.firstIndex(of: "--fresh") {
            sentences = freshSentences
            inputs.remove(at: flag)
        }
        let seeds: [UInt64] = !inputs.isEmpty
            ? try inputs.map { input in
                guard let seed = UInt64(input) else { throw NSError(domain: "Invalid numeric seed: " + input, code: 1) }
                return seed
            } : [1729, 88741]
        // A known two-key contact checks the overlap model independently of UIKit.
        let left = CGRect(x: -30, y: -30, width: 30, height: 60)
        let right = CGRect(x: 0, y: -30, width: 30, height: 60)
        let calibrationTap = Tap(key: "e", dx: 0, dy: 0, radiusX: 12, radiusY: 15, angle: 0)
        let pair = [Face(key: "e", rect: left, control: left), Face(key: "r", rect: right, control: right)]
        let calibration = overlap(CGPoint(x: -1.9, y: 0), calibrationTap, pair)
        let mirrored = overlap(CGPoint(x: 1.9, y: 0), calibrationTap, pair)
        precondition(calibration.values.reduce(0, +) == disk.count &&
                     (0.58...0.62).contains(Double(calibration["e", default: 0]) / Double(disk.count)) &&
                     (0.58...0.62).contains(Double(mirrored["r", default: 0]) / Double(disk.count)))
        var rows = [Row](), fixtures = [Fixture](), changes = [EdgeChange]()
        for (layout, width, split) in [("cover", 466.0, false), ("wide joined", 951.0, false), ("wide split", 951.0, true)] {
            let board = KeyboardView()
            var model = KeyboardModel()
            model.isSplit = split
            board.frame = CGRect(x: 0, y: 0, width: width, height: 289)
            board.update(model, returnTitle: nil)
            board.layoutIfNeeded()
            let buttons = board.subviews.compactMap { $0 as? UIButton }.filter {
                !$0.isHidden && $0.isUserInteractionEnabled && $0.accessibilityIdentifier?.hasPrefix("key-") == true && $0.bounds.width > 0
            }
            func name(_ button: UIButton?) -> String {
                guard let label = button?.accessibilityLabel else { return "drop" }
                return label == "Space" ? " " : label.lowercased()
            }
            let faces = buttons.map { Face(key: name($0), rect: board.keycapFrame(of: $0), control: $0.frame) }
            let letters = Dictionary(grouping: faces, by: \.key)
            let unit = letters["e"]![0].rect
            for seed in seeds {
                for profile in Profile.allCases {
                    var rng = RandomStream(state: seed)
                    var score = Score()
                    var histories = [[String]](), guardedHistories = [[String]](), circularHistories = [[String]]()
                    var releases = [[ReplayRelease]]()
                    for (index, text) in sentences.enumerated() {
                        let bias = CGPoint(x: 0.07 * rng.normal(), y: 0.07 * rng.normal())
                        var scripted = [Tap](), targets = [String](), guardedKeys = [String](), circularKeys = [String](), history = "", circularHistory = ""
                        var points = [ReplayRelease]()
                        for (offset, ch) in (text + " ").enumerated() {
                            let key = String(ch)
                            let matching = letters[key]!
                            // Alternate duplicated keys/bars deterministically without
                            // consuming extra random draws on the split keyboard.
                            let face = matching[(index + offset) % matching.count]
                            let intended = face.rect
                            var tap = sample(key, profile: profile, bias: bias, rng: &rng)
                            let center = CGPoint(x: intended.midX + tap.dx * min(intended.width, unit.width),
                                                 y: intended.midY + tap.dy * intended.height)
                            points.append(ReplayRelease(x: center.x, y: center.y, radius: max(tap.radiusX, tap.radiusY)))
                            tap.controlX = (center.x - face.control.minX) / face.control.width
                            tap.controlY = (center.y - face.control.minY) / face.control.height
                            let assigned = board.replayTarget(at: center)
                            let actual = name(assigned)
                            #if MB_CONTACT_REPLAY
                            board.predictedWordInitials = { predictedInitials(circularHistory) }
                            #if MB_EDGE_PREFIX_REPLAY
                            board.edgeLetterContext = { circularHistory }
                            #endif
                            let circular = name(board.replayContact(at: center, assigned: assigned, radius: max(tap.radiusX, tap.radiusY)))
                            #else
                            let circular = actual
                            #endif
                            apply(circular, to: &circularHistory)
                            circularKeys.append(circular)
                            if circular == key { score.circularCorrect += 1 }
                            targets.append(actual)
                            let areas = overlap(center, tap, faces)
                            let votes = areas[key, default: 0]
                            // Only change the point result when one cap covers more than half the finger.
                            let majority = areas.first { $0.value > disk.count / 2 }?.key
                            let candidate = majority ?? actual
                            // Experiment: ignore air in the gap, require 60% of contacted
                            // caps and at least 25% of the patch covered by keys.
                            let covered = areas.values.reduce(0, +)
                            let shareWinner = KeyboardContact.winner(areas)
                            let shared = shareWinner ?? actual
                            let toolbarMargin = center.y < unit.minY && center.y >= unit.minY - 8
                            let pointLetter = actual == "drop" || toolbarMargin && actual.count > 1 ? nil : actual
                            let guarded = KeyboardContact.preferredLetter(point: pointLetter, winner: shareWinner,
                                predictedInitials: { predictedInitials(history) }) ?? actual
                            guardedKeys.append(guarded)
                            apply(guarded, to: &history)
                            if guarded == key { score.guardedCorrect += 1 }
                            if guarded == key && actual != key { score.guardedGains += 1 }
                            if guarded != key && actual == key { score.guardedLosses += 1 }
                            if shared != actual {
                                let dx = max(intended.minX-center.x, center.x-intended.maxX, 0)
                                let dy = max(intended.minY-center.y, center.y-intended.maxY, 0)
                                changes.append(EdgeChange(layout: layout, profile: profile.rawValue, seed: seed,
                                    sentence: index, offset: offset, intended: key, point: actual, overlap: shared,
                                    x: center.x, y: center.y, source: name(board.hitTest(center, with: nil) as? UIButton),
                                    capDistance: hypot(dx, dy), pointVotes: areas[actual, default: 0],
                                    winnerVotes: areas[shared, default: 0], coveredVotes: covered,
                                    insideWindow: board.bounds.contains(center), guarded: guarded))
                            }
                            if shared == key { score.sharedAreaCorrect += 1 }
                            if shared == key && actual != key { score.sharedAreaGains += 1 }
                            if shared != key && actual == key { score.sharedAreaLosses += 1 }
                            score.attempts += 1
                            if actual == key { score.pointCorrect += 1 }
                            else { score.confusions[key + "→" + actual, default: 0] += 1 }
                            if candidate == key { score.areaCorrect += 1 }
                            if actual == "drop" { score.dropped += 1 }
                            if candidate == key && actual != key { score.areaGains += 1 }
                            if candidate != key && actual == key { score.areaLosses += 1 }
                            if areas.count > 1 { score.multipleFaces += 1 }
                            if votes > disk.count / 2 {
                                score.intendedMajority += 1
                                if actual != key { score.majorityMissed += 1 }
                            }
                            scripted.append(tap)
                        }
                        histories.append(targets)
                        guardedHistories.append(guardedKeys)
                        circularHistories.append(circularKeys)
                        releases.append(points)
                        if layout == "cover", seed == seeds[0], index < (sentences == originalSentences ? 2 : 3) {
                            fixtures.append(Fixture(profile: profile.rawValue, seed: seed, text: text + " ", taps: scripted))
                        }
                    }
                    rows.append(Row(layout: layout, profile: profile.rawValue, seed: seed, score: score, targets: histories, guardedTargets: guardedHistories, circularTargets: circularHistories, releases: releases))
                    if profile == .center {
                        precondition(score.pointCorrect == score.attempts && score.areaCorrect == score.attempts,
                                     "A key-center control failed on " + layout)
                    }
                }
            }
        }
        let json = JSONEncoder()
        json.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try json.encode(Result(sentences: sentences, results: rows, fixtures: fixtures, calibration: calibration, disagreements: changes)))
        FileHandle.standardOutput.write(Data([10]))
    }
}
