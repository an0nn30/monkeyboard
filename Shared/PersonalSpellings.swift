import CryptoKit
import Foundation
import Security

/// An explicit rejection of one typed spelling. Never attribute an entire sentence
/// undo to a word if more than one word changed, or the restored text wasn't typed.
struct RejectedSpelling {
    let word: String
    let replacement: String

    static func key(_ word: String) -> String? {
        let value = word.lowercased().replacingOccurrences(of: "’", with: "'")
        guard (1...40).contains(value.count), value.first?.isLetter == true, value.last?.isLetter == true,
              value.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
        return value
    }

    init?(_ word: String, _ replacement: String) {
        let parts = replacement.components(separatedBy: " ")
        guard let original = Self.key(word), parts.count <= 3,
              parts.allSatisfy({ Self.key($0) != nil }) else { return nil }
        let normalized = parts.compactMap { Self.key($0) }.joined(separator: " ")
        guard original != normalized else { return nil }
        self.word = word
        self.replacement = normalized
    }

    private static func tokens(_ text: String) -> [String] {
        var result = [String](), word = ""
        for char in text {
            if char.isLetter || char == "'" || char == "’" { word.append(char) }
            else {
                if !word.isEmpty { result.append(word); word = "" }
                result.append(String(char))
            }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }

    static func singleChange(typed: String, before: String, after: String) -> Self? {
        let raw = tokens(typed), old = tokens(before), new = tokens(after)
        let head = zip(old, new).prefix(while: ==).count
        let tail = zip(old.dropFirst(head).reversed(), new.dropFirst(head).reversed()).prefix(while: ==).count
        guard old.count - head - tail == 1, raw.count == old.count, raw[head] == old[head] else { return nil }
        return Self(old[head], new[head..<(new.count - tail)].joined())
    }
}

enum LearningSpeed: Int, CaseIterable {
    case fast = 2, balanced = 3, careful = 5

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .careful: return "Careful"
        }
    }
}

enum SpellingInput: String, Codable {
    case typing, swipe
}

/// One device-only item per input spelling and input method. Until a choice
/// repeats, only fingerprints are kept. A new preference competes with the old
/// one under the same threshold, so a single counterexample can't overwrite it.
enum PersonalSpellings {
    struct Preference: Codable, Equatable, Identifiable {
        let input: SpellingInput
        let original: String
        let preferred: String
        var id: String { account(input, original) }
        var keepsOriginal: Bool { RejectedSpelling.key(original) == RejectedSpelling.key(preferred) }
    }

    struct Snapshot {
        var preferences: [Preference] = []
        var hasPending = false
    }

    private struct State: Codable {
        var learned: Preference?
        var fingerprint: Data?
        var count = 0
    }

    private struct Item {
        let state: State
        let revision: Data?
    }

    private static let service = "dev.dustin.monkeyboard.personal-spellings.v1"
    static let settingsChanged = "dev.dustin.monkeyboard.personal-spellings.settings-changed"
    private static let pendingLimit = 128

    private static func hash(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }
    private static func account(_ input: SpellingInput, _ original: String) -> String {
        let digest = hash(RejectedSpelling.key(original) ?? original).base64EncodedString()
        return input == .typing ? digest : "swipe." + digest
    }
    private static func query(_ account: String? = nil) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                   kSecAttrSynchronizable: false]
        if let account { q[kSecAttrAccount] = account }
        return q
    }

    private static func decode(_ attributes: [CFString: Any]) -> Item? {
        guard let revision = attributes[kSecAttrGeneric] as? Data,
              let data = attributes[kSecValueData] as? Data else { return nil }
        let state: State
        if revision.count == 1 { // Build 62/63 kept-spelling records.
            switch revision.first {
            case 1, 2: state = State(fingerprint: data, count: Int(revision[0]))
            case 3:
                guard let word = String(data: data, encoding: .utf8), RejectedSpelling.key(word) != nil else { return nil }
                state = State(learned: Preference(input: .typing, original: word, preferred: word))
            default: return nil
            }
        } else {
            guard let decoded = try? JSONDecoder().decode(State.self, from: data) else { return nil }
            state = decoded
        }
        return Item(state: state, revision: revision)
    }

    private static func items() -> [[CFString: Any]] {
        var read = query()
        read[kSecReturnAttributes] = true
        read[kSecReturnData] = true
        read[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess else { return [] }
        return result as? [[CFString: Any]] ?? []
    }

    static func snapshot() -> Snapshot {
        var snapshot = Snapshot()
        for attributes in items() {
            guard let state = decode(attributes)?.state else { continue }
            if let learned = state.learned { snapshot.preferences.append(learned) }
            if state.count > 0 { snapshot.hasPending = true }
        }
        snapshot.preferences.sort {
            let order = $0.original.localizedCaseInsensitiveCompare($1.original)
            return order == .orderedSame ? $0.input.rawValue < $1.input.rawValue : order == .orderedAscending
        }
        return snapshot
    }

    private static func read(_ account: String) -> Item? {
        var q = query(account)
        q[kSecReturnData] = true
        q[kSecReturnAttributes] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return Item(state: State(), revision: nil) }
        guard status == errSecSuccess, let attributes = result as? [CFString: Any] else { return nil }
        return decode(attributes)
    }

    private static func write(_ state: State, account: String, replacing revision: Data?) -> OSStatus {
        guard let data = try? JSONEncoder().encode(state) else { return errSecParam }
        let attributes: [CFString: Any] = [kSecAttrGeneric: Data(UUID().uuidString.utf8), kSecValueData: data]
        var target = query(account)
        if let revision {
            target[kSecAttrGeneric] = revision
            return SecItemUpdate(target as CFDictionary, attributes as CFDictionary)
        }
        target[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        target.merge(attributes) { _, new in new }
        return SecItemAdd(target as CFDictionary, nil)
    }

    static func recordUndo(_ rejection: RejectedSpelling, speed: LearningSpeed) -> Preference? {
        let keep = Preference(input: .typing, original: rejection.word, preferred: rejection.word)
        // The same fingerprint as the previous build, so partial counts carry over.
        return record(keep, evidence: rejection.replacement, speed: speed)
    }

    static func recordChoice(_ input: SpellingInput, original: String, chosen: String, speed: LearningSpeed) -> Preference? {
        guard let source = RejectedSpelling.key(original), let target = RejectedSpelling.key(chosen) else { return nil }
        let preference = Preference(input: input, original: source, preferred: target)
        return record(preference, evidence: "choice " + target, speed: speed)
    }

    private static func record(_ preference: Preference, evidence: String, speed: LearningSpeed) -> Preference? {
        let fingerprint = hash(evidence)
        for _ in 0..<3 {
            guard let item = read(preference.id) else { return nil }
            var state = item.state
            if let learned = state.learned, RejectedSpelling.key(learned.preferred) == RejectedSpelling.key(preference.preferred) {
                if state.count == 0 { return learned }
                state.fingerprint = nil
                state.count = 0
            } else {
                state.count = state.fingerprint == fingerprint ? state.count + 1 : 1
                state.fingerprint = fingerprint
                if state.count >= speed.rawValue {
                    state.learned = preference
                    state.fingerprint = nil
                    state.count = 0
                }
            }
            let result = write(state, account: preference.id, replacing: item.revision)
            if result == errSecSuccess {
                if item.revision == nil { prunePending() }
                return state.learned
            }
            // A concurrent insert can be retried. A deletion or edit from
            // Settings wins over stale feedback.
            if result != errSecDuplicateItem { return nil }
        }
        return nil
    }

    private static func prunePending() {
        let pending = items().filter { decode($0)?.state.learned == nil }
        guard pending.count > pendingLimit else { return }
        let oldest = pending.sorted {
            ($0[kSecAttrModificationDate] as? Date ?? .distantPast) < ($1[kSecAttrModificationDate] as? Date ?? .distantPast)
        }
        for item in oldest.prefix(pending.count - pendingLimit) {
            guard let account = item[kSecAttrAccount] as? String, let marker = item[kSecAttrGeneric] else { continue }
            var target = query(account)
            target[kSecAttrGeneric] = marker
            SecItemDelete(target as CFDictionary)
        }
    }

    static func edit(_ preference: Preference, to word: String) -> Bool {
        guard RejectedSpelling.key(word) != nil, let item = read(preference.id),
              item.state.learned == preference, let revision = item.revision else { return false }
        let updated = Preference(input: preference.input, original: preference.original, preferred: word)
        return write(State(learned: updated), account: preference.id, replacing: revision) == errSecSuccess
    }

    static func forget(_ preference: Preference) -> Bool { delete(query(preference.id)) }
    static func reset() -> Bool { delete(query()) }
    private static func delete(_ q: [CFString: Any]) -> Bool {
        let status = SecItemDelete(q as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
