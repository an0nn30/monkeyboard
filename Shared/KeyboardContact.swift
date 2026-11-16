import CoreGraphics
import Foundation
#if canImport(MonkeyBoardEngine)
import MonkeyBoardEngine
#endif

/// Fraction of a contact patch landing on each visible key face. Empty space
/// contributes to the coverage floor but cannot vote for a key.
enum KeyboardContact {
    static let samples: [CGPoint] = (0..<128).map { index in
        let radius = sqrt((Double(index) + 0.5) / 128)
        let angle = Double(index) * .pi * (3 - sqrt(5))
        return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
    }

    static func coverage(at center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, angle: CGFloat,
                         faces: [(key: String, rect: CGRect)]) -> [String: Int] {
        let reach = max(radiusX, radiusY)
        let bounds = CGRect(x: center.x - reach, y: center.y - reach, width: 2 * reach, height: 2 * reach)
        let nearby = faces.filter { $0.rect.intersects(bounds) }
        guard !nearby.isEmpty else { return [:] }
        let c = cos(angle), s = sin(angle)
        var votes = [String: Int]()
        for sample in samples {
            let x = sample.x * radiusX, y = sample.y * radiusY
            let point = CGPoint(x: center.x + x*c - y*s, y: center.y + x*s + y*c)
            if let face = nearby.first(where: { $0.rect.contains(point) }) {
                votes[face.key, default: 0] += 1
            }
        }
        return votes
    }

    static func winner(_ votes: [String: Int]) -> String? {
        let covered = votes.values.reduce(0, +)
        guard covered >= samples.count / 4 else { return nil }
        return votes.first { $0.value * 5 >= 3 * covered }?.key
    }

    /// Only decide a perimeter tie when the reported disk reaches two different
    /// letter faces. The stronger continuation must overcome its center offset.
    static func perimeterLetter(at point: CGPoint, radius: CGFloat, assigned: String,
                                faces: [(key: String, rect: CGRect)], masks: [UInt32],
                                context: () -> String?) -> String? {
        #if canImport(MonkeyBoardEngine)
        var offsets = [String: CGFloat]()
        for (key, face) in faces where key.utf8.count == 1 && key.first?.isLetter == true {
            let dx = max(0, face.minX - point.x, point.x - face.maxX)
            let dy = max(0, face.minY - point.y, point.y - face.maxY)
            guard dx * dx + dy * dy <= radius * radius, face.width > 0, face.height > 0 else { continue }
            let x = (point.x - face.midX) / face.width
            let y = (point.y - face.midY) / face.height
            offsets[key] = min(offsets[key] ?? .infinity, x * x + y * y)
        }
        guard offsets.count == 2, let sourceDistance = offsets[assigned],
              let other = offsets.first(where: { $0.key != assigned }),
              let source = assigned.utf8.first, let alternative = other.key.utf8.first,
              masks.count == 26, let text = context() else { return nil }
        let before = text.suffix(64).lowercased()
        guard !before.utf8.contains(0) else { return nil }
        let odds = Double(mb_edge_letter_odds_v1(before, source, alternative, masks))
        // Use key widths and heights so a wider layout scales both axes
        // independently. Require three-to-one combined support to move a tap.
        let spatialOdds = exp((sourceDistance - other.value) / (2 * 0.30 * 0.30))
        return odds > 1 && odds * spatialOdds >= 3 ? other.key : nil
        #else
        return nil
        #endif
    }

    /// A circle loses the actual contact's tilt. Accept a narrower majority only
    /// when the strongest next-word prediction agrees and the point key is unsupported.
    static func preferredCircularLetter(point: String, votes: [String: Int], predictedInitials: () -> [Character]) -> String? {
        if let confident = winner(votes) {
            return preferredLetter(point: point, winner: confident, predictedInitials: predictedInitials)
        }
        let covered = votes.values.reduce(0, +)
        guard covered >= samples.count / 4,
              let contender = votes.first(where: { $0.value * 20 >= 11 * covered })?.key,
              contender != point, contender.count == 1, let letter = contender.first, letter.isLetter,
              let original = point.first else { return point }
        let initials = predictedInitials()
        return initials.first == letter && !initials.contains(original) ? contender : point
    }

    static func preferredLetter(point: String?, winner: String?, predictedInitials: () -> [Character]) -> String? {
        guard let winner, winner.count == 1, let contender = winner.first, contender.isLetter,
              winner != point else { return point }
        guard let point else { return winner }
        guard point.count == 1, let original = point.first, original.isLetter else { return point }
        let initials = predictedInitials()
        return initials.contains(contender) && !initials.contains(original) ? winner : point
    }
}
