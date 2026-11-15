import UIKit

struct KeyboardTint: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    var sourceColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    var keyColor: UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        sourceColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        // Limit the brightness of each variant so black and white glyphs stay legible,
        // even when the sampled pixel is nearly black, white, or a saturated yellow.
        let light = UIColor(hue: hue, saturation: min(0.35, saturation * 0.48),
                            brightness: 0.80 + 0.10 * brightness, alpha: 1)
        let dark = UIColor(hue: hue, saturation: min(0.65, saturation * 1.05),
                           brightness: 0.32 + 0.13 * brightness, alpha: 1)
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    static func stored() -> Self? {
        guard let data = KeyboardSetting.accentTint.readData(), data.count == 3 else { return nil }
        let rgb = Array(data)
        return Self(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    static func save(_ tint: Self?) -> Bool {
        guard let tint else { return KeyboardSetting.accentTint.remove() }
        return KeyboardSetting.accentTint.save(Data([tint.red, tint.green, tint.blue]))
    }
}
