import UIKit

enum KeyboardStyle: Int, CaseIterable {
    case standard = 0
    case ios = 1

    var title: String { self == .ios ? "iOS" : "Default" }
    static var stored: Self { KeyboardSetting.style.read().flatMap(Self.init(rawValue:)) ?? .standard }
    func save() -> Bool { KeyboardSetting.style.save(UInt8(rawValue)) }

    // Translucent caps let the system keyboard material supply their subtle hue.
    static let iosKeyFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.16) : .white
    }
    static let iosActionFill = iosKeyFill
    static let iosPressedFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.32) : UIColor(white: 0.72, alpha: 1)
    }
    static let iosPreviewFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.36, alpha: 1) : .white
    }
    static let iosSuggestionInk = UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 0.7 : 0.3, alpha: 1)
    }

    // Use the lower 14pt of the extension safe area to match Apple’s wide key baseline.
    func bottomOverlap(for width: CGFloat, safeBottom: CGFloat) -> CGFloat {
        self == .ios && width > 800 ? min(14, max(0, safeBottom)) : 0
    }

    /// Height above the system bottom safe area. Width is the keyboard's safe width.
    func height(for width: CGFloat, compact: Bool) -> CGFloat {
        guard self == .ios else { return (compact ? 193 : 250) + 39 }
        // The system adds a 12pt top inset around third-party keyboard views.
        return width >= 560 ? (width > 800 || compact ? 218 : 320) : (compact ? 204 : 258)
    }
}
