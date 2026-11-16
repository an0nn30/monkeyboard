import AudioToolbox
import UIKit

enum TypingSound: UInt8, CaseIterable {
    // Values are persisted in the shared keychain. Keep the native click at 1.
    case off = 0, iOSStyleClick = 7, systemClick = 1, softTap = 2, softKnock = 3,
         hollowTap = 4, crispTick = 5, mechanical = 6

    var title: String {
        switch self {
        case .off: "Off"
        case .iOSStyleClick: "iOS-Style Click"
        case .systemClick: "System Click"
        case .softTap: "Soft Tap"
        case .softKnock: "Soft Knock"
        case .hollowTap: "Hollow Tap"
        case .crispTick: "Crisp Tick"
        case .mechanical: "Mechanical"
        }
    }

    fileprivate var sample: String? {
        switch self {
        case .off, .systemClick: nil
        case .iOSStyleClick: "ios-style-click"
        case .softTap: "soft-tap"
        case .softKnock: "soft-knock"
        case .hollowTap: "hollow-tap"
        case .crispTick: "crisp-tick"
        case .mechanical: "mechanical"
        }
    }

    static var stored: Self {
        KeyboardSetting.typingSound.read().flatMap { Self(rawValue: UInt8($0)) } ?? .off
    }

    func save() -> Bool { KeyboardSetting.typingSound.save(rawValue) }
}

enum TypingSoundKey: String, CaseIterable {
    case regular = "", space = "-space", backspace = "-backspace"
}

final class TypingSoundPlayer {
    private(set) var selection: TypingSound = .off
    private var samples: [TypingSoundKey: SystemSoundID] = [:]

    deinit { for id in samples.values { AudioServicesDisposeSystemSoundID(id) } }

    func select(_ next: TypingSound) {
        guard next != selection else { return }
        for id in samples.values { AudioServicesDisposeSystemSoundID(id) }
        samples.removeAll(keepingCapacity: true)
        selection = next
        guard let name = next.sample else { return }
        for key in TypingSoundKey.allCases {
            guard let url = Bundle.main.url(forResource: name + key.rawValue, withExtension: "wav", subdirectory: "TypingSounds") else { continue }
            var id: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError { samples[key] = id }
        }
    }

    @MainActor @discardableResult func play(_ key: TypingSoundKey = .regular) -> Bool {
        if selection == .systemClick {
            UIDevice.current.playInputClick()
        } else if let id = samples[key] ?? samples[.regular] {
            AudioServicesPlaySystemSound(id)
        } else { return false }
        return true
    }
}
