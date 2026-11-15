import UIKit

private extension Key {
    var isSpace: Bool { self == .space || self == .rightSpace }
}

/// A control keeps tracking its original finger as it slides across neighboring caps.
private final class KeyButton: UIButton {
    var key = Key.space
    weak var board: KeyboardView?
    var acceptsCurrentTouch = false

    private let face = UIView()
    var faceInsets = UIEdgeInsets.zero

    func setFaceColor(_ color: UIColor, radius: CGFloat = 5) {
        if face.superview == nil {
            face.isUserInteractionEnabled = false
            face.layer.cornerCurve = .continuous
            // UIKit lazily inserts its image view when the key changes layers.
            // Keep the painted cap behind all button content, including new symbols.
            face.layer.zPosition = -1
            insertSubview(face, at: 0)
        }
        face.layer.cornerRadius = radius
        face.backgroundColor = color
        backgroundColor = .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        face.frame = bounds.inset(by: faceInsets)
        if key.isSpace { titleLabel?.center.y = face.frame.midY }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let board else { return false }
        acceptsCurrentTouch = true
        board.begin(self, at: touch.location(in: board), time: touch.timestamp)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let board, acceptsCurrentTouch else { return false }
        if board.isTracing(self) {
            for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                board.sample(self, at: sample.location(in: board), time: sample.timestamp)
            }
        }
        board.move(self, to: touch.location(in: board))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard let board, let touch, acceptsCurrentTouch else { return }
        acceptsCurrentTouch = false
        board.sample(self, at: touch.location(in: board), time: touch.timestamp)
        board.finish(self, at: touch.location(in: board))
    }

    override func cancelTracking(with event: UIEvent?) {
        acceptsCurrentTouch = false
        board?.cancel(self)
    }

    override func accessibilityActivate() -> Bool {
        board?.activate(key)
        return true
    }
}

/// Coordinates stay in view space for drawing and are scaled by the actual
/// key pitches for decoding. Only the currently held stroke is retained.
final class GlideStroke {
    typealias Sample = (point: CGPoint, seconds: TimeInterval)
    let centers: [CGPoint]
    let pitch: CGSize
    let startTime: TimeInterval
    let bounds: CGRect
    private(set) var samples: [Sample]
    private(set) var isGlide = false
    private var distance: CGFloat = 0
    private var reach: CGFloat = 0

    init?(centers: [CGPoint], point: CGPoint, time: TimeInterval, bounds: CGRect) {
        guard centers.count == 26 else { return nil }
        // W and Q share a bank in every layout, as do A and Q.
        let horizontal = abs(centers[22].x - centers[16].x)
        let vertical = abs(centers[0].y - centers[16].y)
        guard horizontal > 4, vertical > 4 else { return nil }
        self.centers = centers
        pitch = CGSize(width: horizontal, height: vertical)
        startTime = time
        samples = [(point, 0)]
        self.bounds = bounds
    }

    func append(_ point: CGPoint, time: TimeInterval) {
        guard let last = samples.last, time >= startTime + last.seconds - 0.000001 else { return }
        let step = hypot((point.x-last.point.x)/pitch.width, (point.y-last.point.y)/pitch.height)
        guard step >= 0.035 else { return }
        distance += step
        let first = samples[0].point
        reach = max(reach, hypot((point.x-first.x)/pitch.width, (point.y-first.y)/pitch.height))
        if samples.count == 256 {
            samples = samples.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
        }
        samples.append((point, max(last.seconds,time-startTime)))
        if distance >= 1.6 && reach >= 1.3 { isGlide = true }
    }
}

final class KeyboardView: UIView {
    static let ink = UIColor.label
    static let keyFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.32, alpha: 1) : .white
    }
    private let actionFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1) :
            UIColor(red: 0.75, green: 0.77, blue: 0.81, alpha: 1)
    }
    private let defaultAccent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.29, green: 0.36, blue: 0.47, alpha: 1) :
            UIColor(red: 0.75, green: 0.83, blue: 0.95, alpha: 1)
    }
    private let toolbar = UIStackView()
    private let optionsButton = UIButton(type: .system)
    private let layoutButton = UIButton(type: .system)
    private let hideButton = UIButton(type: .system)
    private let expandButton = UIButton(type: .system)
    private let keypadGlobe = UIButton(type: .custom)
    static let minimumSplitWidth: CGFloat = 560
    private static let bottomMargin: CGFloat = 5
    private static let spaceHitDepth: CGFloat = 16
    private static let footerHeight: CGFloat = 44
    // Decimal pads with a separate globe already allocate a footer within the keypad height.
    var extraHeightBelowKeys: CGFloat {
        if displayedModel?.layer == .keypad { return keypadGlobe.isHidden ? Self.footerHeight : 0 }
        return Self.footerHeight - Self.bottomMargin
    }
    private var suggestions: [UIButton] = []
    private var rows: [[UIButton]] = []
    private var keys: [[Key]] = []
    private var displayedModel: KeyboardModel?
    private var displayedReturnTitle: String?
    private var displayedAccent: UIColor?
    private var displayedFont = KeyboardFont.system
    private var held: [ObjectIdentifier: KeyButton] = [:]
    private var previews: [ObjectIdentifier: KeyPreview] = [:]
    private var lingering: [KeyPreview] = []
    private var repeatDelete: Timer?
    private var deleteOwner: ObjectIdentifier?
    private var repeated = false
    private var motionEndsAt: CFTimeInterval = 0
    var onLetterGeometry: (([UInt32]) -> Void)?
    private var geometryArea = CGRect.null
    private var geometrySplit: Bool?
    private var letterCenters = [CGPoint](repeating: .zero, count: 26)
    var onKey: ((Key) -> Void)?
    var onTouch: (() -> Void)?
    var onGlideStart: (() -> Bool)?
    var onGlide: ((GlideStroke) -> Bool)?
    private var activeFingers = Set<ObjectIdentifier>()
    private var glideOwner: ObjectIdentifier?
    private var stroke: GlideStroke?
    private let trail = GlideTrail()
    var onWord: ((String) -> Void)?
    var configureGlobe: ((UIButton) -> Void)? {
        didSet { configureGlobe?(keypadGlobe) }
    }
    var onToggleLayout: (() -> Void)?
    var onExpand: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onAvailableWidthChange: ((CGFloat) -> Void)?
    private var lastAvailableWidth: CGFloat = -1

    init() {
        super.init(frame: .zero)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: KeyboardView, _) in
            view.trail.setAccent(view.displayedAccent, traits: view.traitCollection)
        }
        // The system draws one tinted surface through the extension and its outer margins.
        isOpaque = false
        // The extension is hosted in a remote surface. Fully transparent
        // pixels between caps can be passed through before UIView.hitTest.
        backgroundColor = UIColor.secondarySystemFill.withAlphaComponent(0.025)
        toolbar.axis = .horizontal
        toolbar.alignment = .fill
        addSubview(toolbar)
        optionsButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        optionsButton.tintColor = .secondaryLabel
        optionsButton.accessibilityLabel = "Keyboard options"
        optionsButton.accessibilityIdentifier = "keyboard-options"
        optionsButton.showsMenuAsPrimaryAction = true
        toolbar.addArrangedSubview(optionsButton)
        optionsButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        for index in 0..<3 {
            let button = UIButton(type: .system)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.setTitleColor(Self.ink, for: .normal)
            button.accessibilityIdentifier = "suggestion-\(index)"
            button.addAction(UIAction { [weak self, weak button] _ in
                if let word = button?.currentTitle { self?.onWord?(word) }
            }, for: .touchUpInside)
            toolbar.addArrangedSubview(button)
            if let first = suggestions.first {
                button.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true
            }
            suggestions.append(button)
        }
        layoutButton.tintColor = Self.ink
        layoutButton.accessibilityIdentifier = "toggle-split-layout"
        layoutButton.isHidden = true
        layoutButton.addAction(UIAction { [weak self] _ in self?.onToggleLayout?() }, for: .touchUpInside)
        toolbar.addArrangedSubview(layoutButton)
        let buttonWidth = layoutButton.widthAnchor.constraint(equalToConstant: 44)
        buttonWidth.priority = .defaultHigh
        buttonWidth.isActive = true
        hideButton.tintColor = .secondaryLabel
        let chevron = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        hideButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: chevron), for: .normal)
        hideButton.accessibilityLabel = "Hide keyboard"
        hideButton.accessibilityIdentifier = "hide-keyboard"
        hideButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)
        addSubview(hideButton)
        expandButton.tintColor = .secondaryLabel
        expandButton.accessibilityLabel = "Restore full-width keyboard"
        expandButton.accessibilityIdentifier = "expand-keyboard"
        expandButton.isHidden = true
        expandButton.addAction(UIAction { [weak self] _ in self?.onExpand?() }, for: .touchUpInside)
        addSubview(expandButton)
        keypadGlobe.setImage(UIImage(systemName: "globe"), for: .normal)
        keypadGlobe.tintColor = Self.ink
        keypadGlobe.accessibilityLabel = "Next keyboard"
        keypadGlobe.accessibilityIdentifier = "key-Next keyboard"
        keypadGlobe.isHidden = true
        addSubview(keypadGlobe)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func setOptionsMenu(_ menu: UIMenu, feedbackValue: String, showsSplitToggle: Bool) {
        optionsButton.menu = menu
        optionsButton.accessibilityValue = feedbackValue
        layoutButton.isHidden = !showsSplitToggle
    }

    func setSuggestions(_ words: [String]) {
        for (index, button) in suggestions.enumerated() {
            let word = index < words.count ? words[index] : nil
            button.setTitle(word, for: .normal)
            button.isEnabled = word != nil
            button.accessibilityElementsHidden = word == nil
        }
    }

    func update(_ model: KeyboardModel, returnTitle: String?, accentColor: UIColor? = nil,
                font: KeyboardFont = .system, animateLayout: Bool = false) {
        guard displayedModel != model || displayedReturnTitle != returnTitle ||
              displayedAccent != accentColor || displayedFont != font else { return }
        if displayedModel == nil || displayedFont != font {
            let suggestionFont = font.font(ofSize: 15)
            for button in suggestions { button.titleLabel?.font = suggestionFont }
        }
        displayedFont = font
        if displayedModel == nil || displayedAccent != accentColor {
            trail.setAccent(accentColor, traits: traitCollection)
        }
        displayedAccent = accentColor
        let accent = accentColor ?? defaultAccent
        let keypad = model.layer == .keypad
        let wasKeypad = displayedModel?.layer == .keypad
        if animateLayout { layoutIfNeeded(); resetTouches() }
        displayedModel = model
        displayedReturnTitle = returnTitle
        toolbar.isHidden = keypad
        // Decimal takes the lower-left cell. Keep the system keyboard switch
        // available below the grid on hosts that require an in-extension globe.
        keypadGlobe.isHidden = !(keypad && model.keyboardType == .decimalPad && model.needsGlobe)
        expandButton.isHidden = model.oneHanded == .fullWidth
        expandButton.setImage(UIImage(systemName: model.oneHanded == .left ? "chevron.right" : "chevron.left"),
                              for: .normal)
        layoutButton.accessibilityLabel = model.isSplit ? "Join keyboard" : "Split keyboard"
        layoutButton.setImage(UIImage(systemName: model.isSplit ? "keyboard" : "rectangle.split.2x1"),
                              for: .normal)
        let next = model.rows
        // Preserve the control that owns a touch when one-shot shift changes case.
        if keypad != wasKeypad || rows.map(\.count) != next.map(\.count)
            || keys.last?.firstIndex(of: .globe) != next.last?.firstIndex(of: .globe) {
            resetTouches()
            rows.flatMap { $0 }.forEach { $0.removeFromSuperview() }
            rows = next.map { row in
                row.map { key in
                    let button: UIButton
                    if key == .globe {
                        button = UIButton(type: .custom)
                        configureGlobe?(button)
                    } else {
                        let cap = KeyButton(type: .custom)
                        cap.board = self
                        button = cap
                    }
                    button.layer.cornerRadius = 5
                    button.layer.cornerCurve = .continuous
                    button.isExclusiveTouch = false
                    button.tintColor = Self.ink
                    button.setTitleColor(Self.ink, for: .normal)
                    button.titleLabel?.adjustsFontSizeToFitWidth = true
                    button.titleLabel?.minimumScaleFactor = 0.65
                    addSubview(button)
                    return button
                }
            }
        }
        keys = next
        let characterFont = font.font(ofSize: keypad ? 25 : 23)
        let actionFont = keypad ? characterFont : font.font(ofSize: 16)
        lazy var legendFont = font.font(ofSize: 9, weight: .semibold)
        for (i, row) in next.enumerated() {
            for (j, key) in row.enumerated() {
                let button = rows[i][j]
                (button as? KeyButton)?.key = key
                var title: String?
                var symbol: String?
                var label: String
                var color = actionFill
                var keyFont = actionFont
                switch key {
                case let .type(text): title = text; label = text; color = Self.keyFill; keyFont = characterFont
                case .shift:
                    symbol = model.shift == .locked ? "capslock.fill" : (model.shift == .upper ? "shift.fill" : "shift")
                    label = model.shift == .locked ? "Caps Lock" : "Shift"
                    if model.shift != .lower { color = accent }
                case .delete: symbol = "delete.left"; label = "Delete"
                case .layer: title = model.layer == .letters ? "123" : "ABC"; label = title!
                case .symbols: title = model.layer == .numbers ? "#+=" : "123"; label = title!
                case .globe: symbol = "globe"; label = "Next keyboard"
                case .space, .rightSpace: title = "space"; label = "Space"; color = Self.keyFill
                case .enter:
                    title = returnTitle; symbol = returnTitle == nil ? "return" : nil
                    label = returnTitle ?? "Return"; color = accent
                }
                button.setTitle(title, for: .normal)
                if keypad {
                    // UIKit's number pad uses phone legends as labels; each key inserts only its digit.
                    let legends = ["", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ"]
                    let legend = i < 3 ? legends[i * 3 + j] : ""
                    let digit = title?.first?.isWholeNumber == true
                    color = digit ? Self.keyFill : .clear
                    if let title, !legend.isEmpty {
                        let caption = NSMutableAttributedString(string: title, attributes: [.font: characterFont])
                        caption.append(NSAttributedString(string: "\n" + legend, attributes: [
                            .font: legendFont, .kern: 1.3
                        ]))
                        button.titleLabel?.numberOfLines = 2
                        button.titleLabel?.textAlignment = .center
                        button.setAttributedTitle(caption, for: .normal)
                    } else {
                        button.setAttributedTitle(nil, for: .normal)
                    }
                }
                button.setImage(symbol.flatMap { UIImage(systemName: $0) }, for: .normal)
                button.titleLabel?.font = keyFont
                if let cap = button as? KeyButton { cap.setFaceColor(color, radius: keypad ? 9 : 5) }
                else { button.backgroundColor = color }
                button.accessibilityLabel = label
                button.accessibilityIdentifier = "key-" + label
                if key == .rightSpace {
                    button.isUserInteractionEnabled = model.isSplit
                    button.isAccessibilityElement = model.isSplit
                    button.accessibilityElementsHidden = !model.isSplit
                    button.accessibilityIdentifier = "key-Space-right"
                } else if model.isSplit && key == .space {
                    button.accessibilityIdentifier = "key-Space-left"
                }
            }
        }
        setNeedsLayout()
        if animateLayout && !UIAccessibility.isReduceMotionEnabled {
            let duration = 0.26
            motionEndsAt = CACurrentMediaTime() + duration
            UIView.animate(withDuration: duration, delay: 0,
                           options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
                self.layoutIfNeeded()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastAvailableWidth {
            lastAvailableWidth = bounds.width
            resetTouches()
            onAvailableWidthChange?(bounds.width)
        }
        guard !rows.isEmpty else { return }
        let inset: CGFloat = 4
        let hand = displayedModel?.oneHanded ?? .fullWidth
        let keypad = displayedModel?.layer == .keypad
        let typingArea = hand.typingArea(in: bounds.inset(by: UIEdgeInsets(
            top: 0, left: 0, bottom: keypad ? Self.footerHeight : extraHeightBelowKeys, right: 0)))
        let available = typingArea.insetBy(dx: inset, dy: 0)
        let footerY = bounds.maxY - Self.footerHeight
        hideButton.frame = CGRect(x: available.minX, y: footerY, width: 44, height: Self.footerHeight)
        keypadGlobe.frame = CGRect(x: available.maxX - 44, y: footerY, width: 44, height: Self.footerHeight)
        let gap: CGFloat = typingArea.width < 360 ? 3 : 4
        let rowGap: CGFloat = typingArea.height < 220 ? 5 : 7
        // This strip also provides headroom for top-row previews inside the extension.
        let top: CGFloat = keypad ? 0 : min(61, max(46, typingArea.height * 0.23))
        toolbar.frame = CGRect(x: available.minX, y: 0, width: available.width, height: top)
        if hand != .fullWidth {
            let gutterX = hand == .left ? typingArea.maxX : bounds.minX
            let gutterWidth = bounds.width - typingArea.width
            let targetWidth = min(52, gutterWidth)
            expandButton.frame = CGRect(x: gutterX + (gutterWidth - targetWidth) / 2,
                                        y: top + (typingArea.height - top - 52) / 2,
                                        width: targetWidth, height: 52)
        }
        if keypad {
            layoutKeypad(in: typingArea)
            return
        }
        let height = max(1, (typingArea.height - top - Self.bottomMargin - 3 * rowGap) / 4)
        let split = displayedModel?.isSplit == true
        func weight(_ key: Key) -> CGFloat {
            split && key.isSpace ? key.weight / 2 : key.weight
        }
        for (i, row) in rows.enumerated() {
            let y = top + CGFloat(i) * (height + rowGap)
            func place(_ indices: Range<Int>, from start: CGFloat, width: CGFloat) {
                var x = start
                let visible = indices.filter { split || keys[i][$0] != .rightSpace }
                let net = width - CGFloat(visible.count - 1) * gap
                let total = visible.reduce(0) { $0 + weight(keys[i][$1]) }
                for j in visible {
                    let capWidth = net * weight(keys[i][j]) / total
                    let face = CGRect(x: x, y: y, width: capWidth, height: height)
                    // Extend the actual control frame as well as local hit testing:
                    // the remotely hosted keyboard uses control regions to deliver touches.
                    if let cap = row[j] as? KeyButton, case .type = cap.key {
                        cap.faceInsets = UIEdgeInsets(top: rowGap / 2, left: gap / 2, bottom: rowGap / 2, right: gap / 2)
                        cap.frame = face.insetBy(dx: -gap / 2, dy: -rowGap / 2)
                    } else if let cap = row[j] as? KeyButton, cap.key.isSpace {
                        let depth = min(Self.spaceHitDepth, max(0, bounds.maxY - face.maxY))
                        cap.faceInsets = UIEdgeInsets(top: 0, left: 0, bottom: depth, right: 0)
                        cap.frame = CGRect(x: face.minX, y: face.minY, width: face.width, height: face.height + depth)
                    } else {
                        (row[j] as? KeyButton)?.faceInsets = .zero
                        row[j].frame = face
                    }
                    x += capWidth + gap
                }
            }
            if let displayedModel, displayedModel.isSplit {
                // Cap thumb reach on the inner display and stagger the home row.
                let bank = min(260, available.width * 0.44)
                let cut = displayedModel.splitIndex(row: i, count: row.count)
                let stagger = i == 1 ? (bank + gap) / 10 : 0
                place(0..<cut, from: available.minX + stagger, width: bank)
                place(cut..<row.count, from: available.maxX - bank + stagger, width: bank - 2 * stagger)
            } else {
                let indent = i == 1 ? (available.width + gap) / 20 : 0
                place(row.indices, from: available.minX + indent, width: available.width - 2 * indent)
            }
            if let right = keys[i].firstIndex(of: .rightSpace) {
                let leftBar = row[right - 1]
                // Keep the shortcut control for the join animation. In split mode
                // its comma keycap and the gap beside it belong to the left spacebar.
                let shortcutIndex = right - 2
                let shortcut = row[shortcutIndex]
                let absorbsComma = split && keys[i][shortcutIndex] == .type(",")
                shortcut.alpha = absorbsComma ? 0 : 1
                shortcut.isUserInteractionEnabled = !absorbsComma
                shortcut.isAccessibilityElement = !absorbsComma
                if absorbsComma {
                    leftBar.frame = leftBar.frame.union(keycapFrame(of: shortcut))
                }
                let cap = row[right]
                if !split {
                    // Both bars share a destination, with the right bar folding into its half.
                    let space = leftBar.frame
                    (cap as? KeyButton)?.faceInsets = (leftBar as? KeyButton)?.faceInsets ?? .zero
                    cap.frame = CGRect(x: space.midX, y: space.minY, width: space.width / 2, height: space.height)
                }
                cap.alpha = split ? 1 : 0
            }
        }
        if displayedModel?.layer == .letters, geometryArea != typingArea || geometrySplit != split {
            geometryArea = typingArea
            geometrySplit = split
            var centers: [(Int, CGRect)] = []
            for (r, line) in keys.enumerated() {
                for (c, key) in line.enumerated() {
                    guard case let .type(text) = key, let ascii = text.lowercased().utf8.first,
                          (97...122).contains(ascii) else { continue }
                    let index = Int(ascii) - 97
                    let frame = keycapFrame(of: rows[r][c])
                    centers.append((index, frame))
                    letterCenters[index] = CGPoint(x: frame.midX, y: frame.midY)
                }
            }
            var masks = [UInt32](repeating: 0, count: 26)
            for (i, a) in centers {
                for (j, b) in centers where i != j {
                    let x = (a.midX - b.midX) / ((a.width + b.width) / 2 + gap)
                    let y = (a.midY - b.midY) / (a.height + rowGap)
                    if x*x + y*y <= 1.65 { masks[i] |= 1 << j }
                }
            }
            onLetterGeometry?(masks)
        }
    }

    private func layoutKeypad(in area: CGRect) {
        let grid = area.insetBy(dx: 5, dy: 6)
        let cellWidth = grid.width / 3
        let cellHeight = grid.height / 4
        for (r, row) in rows.enumerated() {
            for (c, button) in row.enumerated() {
                // On integer pads without an in-extension globe the first cell stays empty.
                let column = c + 3 - row.count
                button.frame = CGRect(x: grid.minX + CGFloat(column) * cellWidth,
                                      y: grid.minY + CGFloat(r) * cellHeight, width: cellWidth, height: cellHeight)
                (button as? KeyButton)?.faceInsets = UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
            }
        }
    }

    private func controlFrame(of button: UIButton, presented: Bool) -> CGRect {
        presented && CACurrentMediaTime() < motionEndsAt
            ? button.layer.presentation()?.frame ?? button.frame : button.frame
    }

    func keycapFrame(of button: UIButton, presented: Bool = false) -> CGRect {
        controlFrame(of: button, presented: presented).inset(by: (button as? KeyButton)?.faceInsets ?? .zero)
    }
    private func visibleFrame(of button: UIButton) -> CGRect { keycapFrame(of: button, presented: true) }

    private func hitFrame(of button: UIButton) -> CGRect {
        if let cap = button as? KeyButton, cap.key.isSpace {
            return controlFrame(of: cap, presented: true)
        }
        return visibleFrame(of: button)
    }

    // Use the same target at touch-down and lift-off, including during layout animations.
    private func nearestCap(at point: CGPoint) -> UIButton? {
        guard bounds.contains(point), point.y >= toolbar.frame.maxY else { return nil }
        var nearest: UIButton?
        var best = CGFloat.infinity
        for row in rows {
            for cap in row where cap.isUserInteractionEnabled && !cap.isHidden {
                if displayedModel?.layer == .keypad {
                    if cap.frame.contains(point) { return cap }
                    continue
                }
                let r = hitFrame(of: cap)
                if r.contains(point) { return cap }
                guard let key = cap as? KeyButton, case .type = key.key else { continue }
                let dx = max(r.minX - point.x, point.x - r.maxX, 0)
                let dy = max(r.minY - point.y, point.y - r.maxY, 0)
                guard dx <= 4, dy <= 4 else { continue }
                let distance = dx * dx + dy * dy
                if distance < best { nearest = cap; best = distance }
            }
        }
        return nearest
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, bounds.contains(point),
              !rows.isEmpty, point.y >= toolbar.frame.maxY else { return super.hitTest(point, with: event) }
        if !keypadGlobe.isHidden, keypadGlobe.frame.contains(point) { return keypadGlobe }
        if visibleFrame(of: hideButton).contains(point) { return hideButton }
        if let cap = nearestCap(at: point) { return cap }
        if !expandButton.isHidden, visibleFrame(of: expandButton).contains(point) { return expandButton }
        return self
    }

    private func button(at point: CGPoint, from source: KeyButton) -> KeyButton? {
        if case .type = source.key {
            guard let key = nearestCap(at: point) as? KeyButton, case .type = key.key else { return nil }
            return key
        }
        let frame = displayedModel?.layer == .keypad ? source.frame : hitFrame(of: source)
        return frame.insetBy(dx: -3, dy: -3).contains(point) ? source : nil
    }

    private func endStroke() {
        stroke = nil
        glideOwner = nil
    }

    private func cancelStroke() {
        if let stroke { trail.cancel(stroke) }
        endStroke()
    }

    private func beginStroke(_ source: KeyButton, point: CGPoint, time: TimeInterval) {
        guard displayedModel?.layer == .letters, CACurrentMediaTime() >= motionEndsAt,
              case let .type(text) = source.key, text.count == 1, text.first?.isLetter == true,
              onGlideStart?() == true else { return }
        guard !letterCenters.contains(.zero),
              let path = GlideStroke(centers: letterCenters, point: point, time: time, bounds: bounds) else { return }
        stroke = path
        glideOwner = ObjectIdentifier(source)
    }

    fileprivate func isTracing(_ source: KeyButton) -> Bool { glideOwner == ObjectIdentifier(source) }

    fileprivate func sample(_ source: KeyButton, at point: CGPoint, time: TimeInterval) {
        guard isTracing(source), let stroke else { return }
        guard bounds == stroke.bounds else { cancelStroke(); return }
        stroke.append(point, time: time)
    }

    fileprivate func begin(_ source: KeyButton, at point: CGPoint, time: TimeInterval) {
        activeFingers.insert(ObjectIdentifier(source))
        if activeFingers.count == 1 { beginStroke(source, point: point, time: time) }
        else { cancelStroke() }
        lingering.forEach { $0.removeFromSuperview() }
        lingering.removeAll()
        onTouch?()
        track(source, target: source)
        if source.key == .delete {
            stopRepeating()
            let owner = ObjectIdentifier(source)
            deleteOwner = owner
            repeated = false
            repeatDelete = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
                guard let self, self.deleteOwner == owner else { return }
                self.repeated = true
                self.onKey?(.delete)
                self.repeatDelete = Timer.scheduledTimer(withTimeInterval: 0.075, repeats: true) { [weak self] _ in
                    self?.onKey?(.delete)
                }
            }
        }
    }

    fileprivate func move(_ source: KeyButton, to point: CGPoint) {
        if isTracing(source), let stroke, stroke.isGlide {
            track(source, target: nil)
            trail.follow(stroke, in: self)
            return
        }
        let target = button(at: point, from: source)
        if source.key == .delete && target == nil { stopRepeating() }
        track(source, target: target)
    }

    private func track(_ source: KeyButton, target: KeyButton?) {
        let id = ObjectIdentifier(source)
        if held[id] === target { return }
        held[id]?.alpha = 1
        held[id] = target
        target?.alpha = 0.72
        guard displayedModel?.layer != .keypad, let target, case let .type(char) = target.key else {
            previews.removeValue(forKey: id)?.removeFromSuperview()
            return
        }
        let preview = previews[id] ?? KeyPreview()
        if preview.superview == nil { addSubview(preview); previews[id] = preview }
        bringSubviewToFront(preview)
        preview.show(char, above: visibleFrame(of: target), in: self, font: displayedFont)
    }

    fileprivate func finish(_ source: KeyButton, at point: CGPoint) {
        guard source.superview === self else { return }
        let target = button(at: point, from: source)
        if isTracing(source), let path = stroke, path.isGlide {
            endStroke()
            cancel(source)
            guard let target, case let .type(text) = target.key, text.first?.isLetter == true else { return }
            if onGlide?(path) != true { onKey?(target.key) }
            return
        }
        track(source, target: target)
        let id = ObjectIdentifier(source)
        let alreadyDeleted = source.key == .delete && repeated
        if let preview = previews.removeValue(forKey: id) {
            lingering.append(preview)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self, weak preview] in
                preview?.removeFromSuperview()
                self?.lingering.removeAll { $0 === preview }
            }
        }
        cancel(source)
        if let target, !alreadyDeleted { onKey?(target.key) }
    }

    fileprivate func cancel(_ source: KeyButton) {
        let id = ObjectIdentifier(source)
        activeFingers.remove(id)
        if isTracing(source) { cancelStroke() }
        held.removeValue(forKey: id)?.alpha = 1
        previews.removeValue(forKey: id)?.removeFromSuperview()
        if deleteOwner == id { stopRepeating() }
    }

    fileprivate func activate(_ key: Key) { onTouch?(); onKey?(key) }

    private func stopRepeating() { repeatDelete?.invalidate(); repeatDelete = nil; deleteOwner = nil }

    func resetTouches() {
        endStroke()
        trail.clear()
        activeFingers.removeAll()
        stopRepeating()
        for case let button as KeyButton in rows.joined() { button.acceptsCurrentTouch = false }
        held.values.forEach { $0.alpha = 1 }
        held.removeAll()
        (Array(previews.values) + lingering).forEach { $0.removeFromSuperview() }
        previews.removeAll()
        lingering.removeAll()
    }
}
