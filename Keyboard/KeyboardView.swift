import UIKit

/// A control keeps tracking its original finger as it slides across neighboring caps.
private final class KeyButton: UIButton {
    var key = Key.space
    weak var board: KeyboardView?
    var acceptsCurrentTouch = false

    let face = UIView()
    var faceInset = CGSize.zero

    func setFaceColor(_ color: UIColor) {
        if face.superview == nil {
            face.isUserInteractionEnabled = false
            face.layer.cornerRadius = 5
            face.layer.cornerCurve = .continuous
            insertSubview(face, at: 0)
        }
        sendSubviewToBack(face)
        face.backgroundColor = color
        backgroundColor = .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        face.frame = bounds.insetBy(dx: faceInset.width, dy: faceInset.height)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let board else { return false }
        acceptsCurrentTouch = true
        board.begin(self)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let board, acceptsCurrentTouch else { return false }
        board.move(self, to: touch.location(in: board))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard let board, let touch, acceptsCurrentTouch else { return }
        acceptsCurrentTouch = false
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

final class KeyboardView: UIView {
    static let ink = UIColor.label
    static let keyFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.32, alpha: 1) : .white
    }
    private let actionFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1) :
            UIColor(red: 0.75, green: 0.77, blue: 0.81, alpha: 1)
    }
    private let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.29, green: 0.36, blue: 0.47, alpha: 1) :
            UIColor(red: 0.75, green: 0.83, blue: 0.95, alpha: 1)
    }
    private let toolbar = UIStackView()
    private let optionsButton = UIButton(type: .system)
    private let layoutButton = UIButton(type: .system)
    private let expandButton = UIButton(type: .system)
    static let minimumSplitWidth: CGFloat = 560
    private var suggestions: [UIButton] = []
    private var rows: [[UIButton]] = []
    private var keys: [[Key]] = []
    private var displayedModel: KeyboardModel?
    private var displayedReturnTitle: String?
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
    var onKey: ((Key) -> Void)?
    var onTouch: (() -> Void)?
    var onWord: ((String) -> Void)?
    var configureGlobe: ((UIButton) -> Void)?
    var onToggleLayout: (() -> Void)?
    var onExpand: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onAvailableWidthChange: ((CGFloat) -> Void)?
    private var lastAvailableWidth: CGFloat = -1

    init() {
        super.init(frame: .zero)
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
            button.titleLabel?.font = .systemFont(ofSize: 15)
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
        let hideButton = UIButton(type: .system)
        hideButton.tintColor = Self.ink
        hideButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        hideButton.accessibilityLabel = "Hide keyboard"
        hideButton.accessibilityIdentifier = "hide-keyboard"
        hideButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)
        toolbar.addArrangedSubview(hideButton)
        hideButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        expandButton.tintColor = .secondaryLabel
        expandButton.accessibilityLabel = "Restore full-width keyboard"
        expandButton.accessibilityIdentifier = "expand-keyboard"
        expandButton.isHidden = true
        expandButton.addAction(UIAction { [weak self] _ in self?.onExpand?() }, for: .touchUpInside)
        addSubview(expandButton)
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

    func update(_ model: KeyboardModel, returnTitle: String?, animateLayout: Bool = false) {
        guard displayedModel != model || displayedReturnTitle != returnTitle else { return }
        if animateLayout { layoutIfNeeded(); resetTouches() }
        displayedModel = model
        displayedReturnTitle = returnTitle
        expandButton.isHidden = model.oneHanded == .fullWidth
        expandButton.setImage(UIImage(systemName: model.oneHanded == .left ? "chevron.right" : "chevron.left"),
                              for: .normal)
        layoutButton.accessibilityLabel = model.isSplit ? "Join keyboard" : "Split keyboard"
        layoutButton.setImage(UIImage(systemName: model.isSplit ? "keyboard" : "rectangle.split.2x1"),
                              for: .normal)
        let next = model.rows
        // Preserve the control that owns a touch when one-shot shift changes case.
        if rows.map(\.count) != next.map(\.count) || keys.flatMap({ $0 }).contains(.globe) != model.needsGlobe {
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
        for (i, row) in next.enumerated() {
            for (j, key) in row.enumerated() {
                let button = rows[i][j]
                (button as? KeyButton)?.key = key
                var title: String?
                var symbol: String?
                var label: String
                var color = actionFill
                var size: CGFloat = 16
                switch key {
                case let .type(text): title = text; label = text; color = Self.keyFill; size = 23
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
                button.setImage(symbol.flatMap { UIImage(systemName: $0) }, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: size)
                if let cap = button as? KeyButton { cap.setFaceColor(color) }
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
        let typingArea = hand.typingArea(in: bounds)
        let available = typingArea.insetBy(dx: inset, dy: 0)
        let gap: CGFloat = typingArea.width < 360 ? 3 : 4
        let rowGap: CGFloat = bounds.height < 220 ? 5 : 7
        // This strip also provides headroom for top-row previews inside the extension.
        let top = min(61, max(46, bounds.height * 0.23))
        toolbar.frame = CGRect(x: available.minX, y: 0, width: available.width, height: top)
        if hand != .fullWidth {
            let gutterX = hand == .left ? typingArea.maxX : bounds.minX
            let gutterWidth = bounds.width - typingArea.width
            let targetWidth = min(52, gutterWidth)
            expandButton.frame = CGRect(x: gutterX + (gutterWidth - targetWidth) / 2,
                                        y: top + (bounds.height - top - 52) / 2,
                                        width: targetWidth, height: 52)
        }
        let height = max(1, (bounds.height - top - 5 - 3 * rowGap) / 4)
        let split = displayedModel?.isSplit == true
        func weight(_ key: Key) -> CGFloat {
            split && (key == .space || key == .rightSpace) ? key.weight / 2 : key.weight
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
                        cap.faceInset = CGSize(width: gap / 2, height: rowGap / 2)
                        cap.frame = face.insetBy(dx: -gap / 2, dy: -rowGap / 2)
                    } else {
                        (row[j] as? KeyButton)?.faceInset = .zero
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
                let cap = row[right]
                if !split {
                    // Both bars share a destination, with the right bar folding into its half.
                    let space = row[right - 1].frame
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
                    centers.append((Int(ascii) - 97, keycapFrame(of: rows[r][c])))
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

    func keycapFrame(of button: UIButton, presented: Bool = false) -> CGRect {
        let frame = presented && CACurrentMediaTime() < motionEndsAt
            ? button.layer.presentation()?.frame ?? button.frame : button.frame
        let inset = (button as? KeyButton)?.faceInset ?? .zero
        return frame.insetBy(dx: inset.width, dy: inset.height)
    }
    private func visibleFrame(of button: UIButton) -> CGRect { keycapFrame(of: button, presented: true) }

    // One ownership rule for both touch-down and lift-off, even while the
    // layout moves. A visible cap wins; only the narrow space between caps
    // is negotiable. Never grow Delete, the globe, or another action key.
    private func nearestCap(at point: CGPoint) -> UIButton? {
        guard bounds.contains(point), point.y >= toolbar.frame.maxY else { return nil }
        var nearest: UIButton?
        var best = CGFloat.infinity
        for row in rows {
            for cap in row where cap.isUserInteractionEnabled && !cap.isHidden {
                let r = visibleFrame(of: cap)
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
        if let cap = nearestCap(at: point) { return cap }
        if !expandButton.isHidden, visibleFrame(of: expandButton).contains(point) { return expandButton }
        return self
    }

    private func button(at point: CGPoint, from source: KeyButton) -> KeyButton? {
        if case .type = source.key {
            guard let key = nearestCap(at: point) as? KeyButton, case .type = key.key else { return nil }
            return key
        }
        return visibleFrame(of: source).insetBy(dx: -3, dy: -3).contains(point) ? source : nil
    }

    fileprivate func begin(_ source: KeyButton) {
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
        guard let target, case let .type(char) = target.key else {
            previews.removeValue(forKey: id)?.removeFromSuperview()
            return
        }
        let preview = previews[id] ?? KeyPreview()
        if preview.superview == nil { addSubview(preview); previews[id] = preview }
        bringSubviewToFront(preview)
        preview.show(char, above: visibleFrame(of: target), in: self)
    }

    fileprivate func finish(_ source: KeyButton, at point: CGPoint) {
        guard source.superview === self else { return }
        let target = button(at: point, from: source)
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
        held.removeValue(forKey: id)?.alpha = 1
        previews.removeValue(forKey: id)?.removeFromSuperview()
        if deleteOwner == id { stopRepeating() }
    }

    fileprivate func activate(_ key: Key) { onTouch?(); onKey?(key) }

    private func stopRepeating() { repeatDelete?.invalidate(); repeatDelete = nil; deleteOwner = nil }

    func resetTouches() {
        stopRepeating()
        for case let button as KeyButton in rows.joined() { button.acceptsCurrentTouch = false }
        held.values.forEach { $0.alpha = 1 }
        held.removeAll()
        (Array(previews.values) + lingering).forEach { $0.removeFromSuperview() }
        previews.removeAll()
        lingering.removeAll()
    }
}
