import UIKit

private final class EmojiCell: UICollectionViewCell {
    let glyph = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyph.textAlignment = .center
        contentView.addSubview(glyph)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.frame = contentView.bounds
        glyph.font = .systemFont(ofSize: min(38, floor(min(bounds.width, bounds.height) * 0.84)))
    }

    override var isHighlighted: Bool {
        didSet { glyph.alpha = isHighlighted ? 0.5 : 1 }
    }
}

final class EmojiPickerView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    var onMode: ((KeyboardModel.EmojiMode) -> Void)?
    var onInsert: ((String) -> Void)?
    var onDelete: (() -> Void)?

    private struct Category {
        let id: String, name: String, symbol: String
        let groups: [Int]
    }

    private static let categories = [
        Category(id: "recent", name: "Recently used", symbol: "clock", groups: []),
        Category(id: "smileys", name: "Smileys and people", symbol: "face.smiling", groups: [0, 1]),
        Category(id: "animals", name: "Animals and nature", symbol: "pawprint", groups: [3]),
        Category(id: "food", name: "Food and drink", symbol: "fork.knife", groups: [4]),
        Category(id: "activities", name: "Activities", symbol: "soccerball", groups: [6]),
        Category(id: "travel", name: "Travel and places", symbol: "car", groups: [5]),
        Category(id: "objects", name: "Objects", symbol: "lightbulb", groups: [7]),
        Category(id: "symbols", name: "Symbols", symbol: "heart", groups: [8]),
        Category(id: "flags", name: "Flags", symbol: "flag", groups: [9])
    ]

    private let catalog = EmojiCatalog.shared
    private let flow = UICollectionViewFlowLayout()
    private lazy var grid = UICollectionView(frame: .zero, collectionViewLayout: flow)
    private let search = UIButton(type: .system)
    private let clear = UIButton(type: .system)
    private let done = UIButton(type: .system)
    private let abc = UIButton(type: .system)
    private let delete = UIButton(type: .system)
    private let tabScroll = UIScrollView()
    private var tabs: [UIButton] = []
    private let empty = UILabel()
    private var recent = UserDefaults.standard.stringArray(forKey: "emoji.recent") ?? []
    private var preferred = UserDefaults.standard.dictionary(forKey: "emoji.tones") as? [String: String] ?? [:]
    private var category = 1
    private var results: [String] = []
    private var searching = false
    private(set) var query = ""

    init() {
        super.init(frame: .zero)
        flow.scrollDirection = .horizontal
        flow.minimumLineSpacing = 0
        flow.minimumInteritemSpacing = 0
        grid.backgroundColor = .clear
        grid.showsHorizontalScrollIndicator = false
        if #available(iOS 26.0, *) {
            grid.topEdgeEffect.isHidden = true
            grid.bottomEdgeEffect.isHidden = true
        }
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: "emoji")
        grid.dataSource = self
        grid.delegate = self
        addSubview(grid)

        func configure(_ button: UIButton, _ id: String, _ label: String,
                       _ symbol: String? = nil, action: @escaping () -> Void) {
            button.accessibilityIdentifier = "emoji-" + id
            button.accessibilityLabel = label
            button.tintColor = .label
            if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal) }
            else { button.setTitle(label, for: .normal) }
            button.layer.cornerCurve = .continuous
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            addSubview(button)
        }
        configure(search, "search", "Search Emoji", "magnifyingglass") { [weak self] in self?.onMode?(.search) }
        var style = UIButton.Configuration.plain()
        style.image = UIImage(systemName: "magnifyingglass")
        style.imagePadding = 8
        style.contentInsets = .init(top: 0, leading: 12, bottom: 0, trailing: 10)
        search.configuration = style
        search.contentHorizontalAlignment = .leading
        search.backgroundColor = .tertiarySystemFill
        search.titleLabel?.lineBreakMode = .byTruncatingTail
        configure(clear, "clear", "Clear search", "xmark.circle.fill") { [weak self] in self?.setQuery("") }
        configure(done, "done", "Done") { [weak self] in self?.onMode?(.browse) }
        configure(abc, "abc", "ABC") { [weak self] in self?.onMode?(.closed) }
        configure(delete, "delete", "Delete", "delete.left") { [weak self] in self?.onDelete?() }
        for button in [abc, delete] { button.backgroundColor = .tertiarySystemFill }
        abc.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        tabScroll.showsHorizontalScrollIndicator = false
        addSubview(tabScroll)
        for (index, item) in Self.categories.enumerated() {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16)),
                            for: .normal)
            button.tintColor = .label
            button.accessibilityIdentifier = "emoji-category-" + item.id
            button.accessibilityLabel = item.name
            button.addAction(UIAction { [weak self] _ in self?.selectCategory(index) }, for: .touchUpInside)
            tabScroll.addSubview(button)
            tabs.append(button)
        }
        empty.textColor = .secondaryLabel
        empty.textAlignment = .center
        empty.font = .preferredFont(forTextStyle: .callout)
        addSubview(empty)
        category = recent.contains { catalog.byGlyph[$0] != nil } ? 0 : 1
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func setSearching(_ active: Bool) {
        searching = active
        done.isHidden = !active
        for view in [abc, delete, tabScroll] { view.isHidden = active }
        setQuery("")
        setNeedsLayout()
    }

    func setQuery(_ text: String) {
        query = text
        search.configuration?.title = text.isEmpty ? "Search Emoji" : text
        search.configuration?.baseForegroundColor = text.isEmpty ? .secondaryLabel : .label
        search.accessibilityValue = text.isEmpty ? nil : text
        clear.isHidden = !searching || text.isEmpty
        search.configuration?.contentInsets.trailing = clear.isHidden ? 10 : 36
        refresh()
    }

    private func selectCategory(_ index: Int) {
        category = index
        refresh()
        tabScroll.scrollRectToVisible(tabs[index].frame.insetBy(dx: -3, dy: 0), animated: true)
    }

    private func refresh() {
        let phrase = query.trimmingCharacters(in: .whitespaces)
        if searching && !phrase.isEmpty {
            results = catalog.search(phrase).map { preferred[$0.glyph] ?? $0.glyph }
        } else if category == 0 {
            results = recent.filter { catalog.byGlyph[$0] != nil }
        } else {
            let groups = Self.categories[category].groups
            results = catalog.entries.filter { groups.contains($0.group) }.map { preferred[$0.glyph] ?? $0.glyph }
        }
        empty.text = searching ? "No matching emoji" : "Your recent emoji appear here"
        empty.isHidden = !results.isEmpty
        for (index, tab) in tabs.enumerated() {
            tab.backgroundColor = index == category ? .secondarySystemFill : .clear
            tab.accessibilityTraits = index == category ? [.button, .selected] : .button
        }
        grid.reloadData()
        grid.setContentOffset(.zero, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = bounds.insetBy(dx: 5, dy: 2)
        guard inner.width > 0, inner.height > 0 else { return }
        let header = min(38, floor(inner.height * (searching ? 0.47 : 0.22)))
        let actionWidth: CGFloat = 48
        let searchWidth = inner.width - (searching ? actionWidth + 4 : 0)
        search.frame = CGRect(x: inner.minX, y: inner.minY, width: searchWidth, height: header)
        search.layer.cornerRadius = header / 2
        clear.frame = CGRect(x: search.frame.maxX - 34, y: inner.minY, width: 34, height: header)
        done.frame = CGRect(x: search.frame.maxX + 4, y: inner.minY, width: actionWidth, height: header)
        let footer: CGFloat = searching ? 0 : min(39, floor(inner.height * 0.22))
        let footerY = inner.maxY - footer
        abc.frame = CGRect(x: inner.minX, y: footerY, width: actionWidth, height: footer)
        delete.frame = CGRect(x: inner.maxX - actionWidth, y: footerY, width: actionWidth, height: footer)
        abc.layer.cornerRadius = footer / 2
        delete.layer.cornerRadius = footer / 2
        tabScroll.frame = CGRect(x: abc.frame.maxX + 2, y: footerY, width: max(0, inner.width - 2 * actionWidth - 4), height: footer)
        let tabWidth = max(29, min(45, tabScroll.bounds.width / CGFloat(tabs.count)))
        let tabStart = max(0, (tabScroll.bounds.width - tabWidth * CGFloat(tabs.count)) / 2)
        for (index, tab) in tabs.enumerated() {
            tab.frame = CGRect(x: tabStart + CGFloat(index) * tabWidth, y: 0, width: tabWidth, height: footer)
            tab.layer.cornerRadius = min(footer, tabWidth) / 2
        }
        tabScroll.contentSize = CGSize(width: tabStart + tabWidth * CGFloat(tabs.count), height: footer)
        let gridY = search.frame.maxY + 2
        grid.frame = CGRect(x: inner.minX, y: gridY, width: inner.width, height: max(1, footerY - gridY - 2))
        empty.frame = grid.frame
        let rowCount = searching ? 1 : max(1, min(4, Int(grid.bounds.height / 32)))
        let rowHeight = floor(grid.bounds.height / CGFloat(rowCount))
        let columns = max(1, (grid.bounds.width / 48).rounded())
        let size = CGSize(width: floor(grid.bounds.width / columns), height: max(1, rowHeight))
        if flow.itemSize != size { flow.itemSize = size }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { results.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "emoji", for: indexPath) as! EmojiCell
        let form = results[indexPath.item]
        cell.glyph.text = form
        cell.accessibilityIdentifier = "emoji-" + form
        cell.accessibilityLabel = catalog.byGlyph[form]?.label(for: form)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        insert(results[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, let entry = catalog.byGlyph[results[path.item]],
              !entry.variants.isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            let actions = ([entry.glyph] + entry.variants).map { form in
                UIAction(title: form + "  " + entry.label(for: form)) { [weak self] _ in
                    guard let self else { return }
                    preferred[entry.glyph] = form
                    UserDefaults.standard.set(preferred, forKey: "emoji.tones")
                    insert(form)
                    refresh()
                }
            }
            return UIMenu(title: "Skin tone", children: actions)
        })
    }

    private func insert(_ form: String) {
        onInsert?(form)
        recent.removeAll { $0 == form }
        recent.insert(form, at: 0)
        recent = Array(recent.prefix(32))
        UserDefaults.standard.set(recent, forKey: "emoji.recent")
        if category == 0 && query.isEmpty { refresh() }
    }
}
