import Security
import UIKit

/// Preferences in the local keychain access group shared by the app and keyboard.
enum KeyboardSetting: String {
    case accentTint = "accent-tint-srgb"
    case font = "keyboard-font"
    case style = "keyboard-style"
    case typingSound = "typing-sound"
    case firmness = "keypress-firmness"
    case split = "split-wide-layout"
    case repeatSplitLetters = "repeat-split-letters"
    case oneHanded = "one-handed-layout"
    case returnAfterSymbol = "return-after-symbol"
    case learningSpeed = "personal-learning-speed"
    case glideTyping = "glide-typing"
    case autocorrection = "autocorrection"
    case transformer = "decoder-15m"
    case sentenceScoring = "sentence-scoring"

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: "dev.dustin.monkeyboard.settings",
         kSecAttrAccount: rawValue]
    }

    func readData() -> Data? {
        var request = query
        request[kSecReturnData] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func read() -> Int? {
        guard let data = readData(), data.count == 1, let byte = data.first else { return nil }
        return Int(byte)
    }

    func save(_ byte: UInt8, onlyIfMissing: Bool = false) -> Bool {
        save(Data([byte]), onlyIfMissing: onlyIfMissing)
    }

    func remove() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func save(_ data: Data, onlyIfMissing: Bool = false) -> Bool {
        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(item as CFDictionary, nil)
        if result == errSecDuplicateItem {
            if onlyIfMissing { return true }
            return SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecSuccess
        }
        return result == errSecSuccess
    }
}

extension LearningSpeed {
    static var stored: Self { KeyboardSetting.learningSpeed.read().flatMap(Self.init(rawValue:)) ?? .balanced }
    func save() -> Bool { KeyboardSetting.learningSpeed.save(UInt8(rawValue)) }
}

enum WideKeyboardLayout {
    static var prefersSplit: Bool { (KeyboardSetting.split.read() ?? 1) != 0 }
    static var repeatsLetters: Bool { KeyboardSetting.repeatSplitLetters.read() == 1 }
    static func setRepeatLetters(_ enabled: Bool) -> Bool { KeyboardSetting.repeatSplitLetters.save(enabled ? 1 : 0) }
    static func setSplit(_ enabled: Bool) -> Bool { KeyboardSetting.split.save(enabled ? 1 : 0) }
}

enum OneHandedSetting {
    static var storedValue: Int? { KeyboardSetting.oneHanded.read() }
    static func save(_ value: Int) -> Bool { KeyboardSetting.oneHanded.save(UInt8(clamping: value)) }
}

enum ReturnAfterSymbolSetting {
    static var isEnabled: Bool { (KeyboardSetting.returnAfterSymbol.read() ?? 1) != 0 }
    static func save(_ enabled: Bool) -> Bool { KeyboardSetting.returnAfterSymbol.save(enabled ? 1 : 0) }
}

enum GlideTypingSetting {
    static var isEnabled: Bool { (KeyboardSetting.glideTyping.read() ?? 1) != 0 }
    static func save(_ value: Bool) -> Bool { KeyboardSetting.glideTyping.save(value ? 1 : 0) }
}

enum AutoCorrectionSetting {
    static var isEnabled: Bool { (KeyboardSetting.autocorrection.read() ?? 1) != 0 }
    static func save(_ value: Bool) -> Bool { KeyboardSetting.autocorrection.save(value ? 1 : 0) }
}

enum SentenceScoringSetting {
    static var isEnabled: Bool { (KeyboardSetting.sentenceScoring.read() ?? 1) != 0 }
    static func save(_ value: Bool) -> Bool { KeyboardSetting.sentenceScoring.save(value ? 1 : 0) }
}

enum TransformerSetting {
    static var isEnabled: Bool { (KeyboardSetting.transformer.read() ?? 1) != 0 }
    static func save(_ enabled: Bool) -> Bool { KeyboardSetting.transformer.save(enabled ? 1 : 0) }
}

enum KeypressFeedback {
    struct Preset {
        let name: String
        let percent: Int
    }

    static let presets = [Preset(name: "Off", percent: 0), Preset(name: "Soft", percent: 28),
                          Preset(name: "Medium", percent: 55), Preset(name: "Firm", percent: 100)]
    static let initial = 28

    static func storedPercent() -> Int? {
        guard let value = KeyboardSetting.firmness.read(), value <= 100 else { return nil }
        return value
    }

    @discardableResult
    static func save(_ percent: Int, onlyIfMissing: Bool = false) -> Bool {
        KeyboardSetting.firmness.save(UInt8(clamping: min(100, percent)), onlyIfMissing: onlyIfMissing)
    }

    static func keyboardPercent() -> Int {
        if let value = storedPercent() { return value }
        guard let previous = UserDefaults.standard.object(forKey: "feedbackStrength") as? Int,
              presets.indices.contains(previous) else { return initial }
        let migrated = presets[previous].percent
        save(migrated, onlyIfMissing: true)
        return storedPercent() ?? migrated
    }

    static func label(_ percent: Int) -> String {
        presets.first { $0.percent == percent }?.name ?? "\(percent)%"
    }
}

@MainActor
final class KeypressPlayer {
    private weak var view: UIView?
    private var style: UIImpactFeedbackGenerator.FeedbackStyle?
    private var generator: UIImpactFeedbackGenerator?

    init(view: UIView) { self.view = view }

    func prepare(_ percent: Int) {
        guard let view, percent > 0 else { generator = nil; style = nil; return }
        let next: UIImpactFeedbackGenerator.FeedbackStyle
        switch percent {
        case ..<45: next = .soft
        case ..<75: next = .medium
        default: next = .heavy
        }
        if next != style {
            generator = UIImpactFeedbackGenerator(style: next, view: view)
            style = next
        }
        generator?.prepare()
    }

    func play(_ percent: Int) {
        prepare(percent)
        guard percent > 0 else { return }
        generator?.impactOccurred(intensity: CGFloat(percent) / 100)
        generator?.prepare()
    }
}
