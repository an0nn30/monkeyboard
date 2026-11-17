import UIKit

final class KeyPreview: UIView {
    private let label = UILabel()
    private let shape = CAShapeLayer()
    private var style = KeyboardStyle.standard

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.addSublayer(shape)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: KeyPreview, _) in
            view.updateFill()
        }
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.14
        shape.shadowRadius = 4
        shape.shadowOffset = CGSize(width: 0, height: 2)
        label.textAlignment = .center
        label.textColor = KeyboardView.ink
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    private func updateFill() {
        shape.fillColor = (style == .ios ? KeyboardStyle.iosPreviewFill : KeyboardView.keyFill)
            .resolvedColor(with: traitCollection).cgColor
    }

    func show(_ character: String, above key: CGRect, in container: UIView, font: KeyboardFont,
              style: KeyboardStyle = .standard) {
        self.style = style
        if style == .ios {
            let width = max(54, min(76, key.width + 24))
            // The extension cannot paint outside its host. Keep the top-row
            // preview detached too, fitting its available toolbar headroom.
            let height = min(72, key.height * 1.5, max(1, key.minY - 3))
            let x = min(max(0, key.midX - width / 2), container.bounds.width - width)
            frame = CGRect(x: x, y: max(0, key.minY - height - 3), width: width, height: height)
            let path = UIBezierPath(roundedRect: bounds, cornerRadius: 15)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateFill()
            shape.path = path.cgPath
            shape.shadowPath = path.cgPath
            shape.shadowOpacity = 0
            CATransaction.commit()
            label.frame = bounds
            label.text = character
            label.font = UIFont.systemFont(ofSize: min(38, height * 0.8))
            return
        }
        shape.shadowOpacity = 0.14
        let size = min(62, max(42, key.height * 1.24), container.bounds.height - key.height)
        let x = min(max(2, key.midX - size / 2), container.bounds.width - size - 2)
        let y = max(0, key.minY - size - 4)
        frame = CGRect(x: x, y: y, width: size, height: size + 4)
        let tip = min(max(8, key.midX - x), size - 8)
        let path = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size), cornerRadius: 11)
        path.move(to: CGPoint(x: tip - 6, y: size - 1))
        path.addLine(to: CGPoint(x: tip, y: size + 4))
        path.addLine(to: CGPoint(x: tip + 6, y: size - 1))
        path.close()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateFill()
        shape.path = path.cgPath
        shape.shadowPath = path.cgPath
        CATransaction.commit()
        label.frame = CGRect(x: 0, y: 0, width: size, height: size)
        label.text = character
        label.font = font.font(ofSize: size * 0.65)
    }
}
