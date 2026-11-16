import XCTest

final class KeyboardTypingTests: XCTestCase {
    private func letter(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier ==[c] %@", "key-" + text)).firstMatch
    }
    // Enable MonkeyBoard in the device's keyboard settings before running the suite.
    private func selectMonkeyBoard(in app: XCUIApplication) {
        let feedback = app.buttons["keyboard-options"]
        for _ in 0..<3 {
            if feedback.waitForExistence(timeout: 4) { return }
            let globe = app.buttons["Next keyboard"].firstMatch
            if globe.exists { globe.tap() }
        }
        XCTAssertTrue(feedback.waitForExistence(timeout: 5), "Enable MonkeyBoard in Settings before testing.")
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSwitchingKeyboardsDoesNotShowAppleKeysBehindTheToolbar() throws {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)

        func checkSurface(_ name: String) throws {
            let toolbar = app.buttons["keyboard-options"]
            let frame = toolbar.frame
            let shot = app.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            // An empty band above the suggestion text should show only the keyboard
            // material. Apple's QWERTY row underneath creates repeated high-contrast
            // cap edges even when the accessibility tree reports only MonkeyBoard.
            let screen = app.frame
            let image = try XCTUnwrap(shot.image.cgImage)
            let scale = CGFloat(image.width) / screen.width
            let y = (frame.minY + frame.height * 0.30 - screen.minY) * scale
            let band = try XCTUnwrap(image.cropping(to: CGRect(x: CGFloat(image.width) * 0.10,
                y: y.rounded(), width: CGFloat(image.width) * 0.80, height: 1)))
            var samples = [UInt8](repeating: 0, count: band.width)
            try samples.withUnsafeMutableBytes { buffer in
                let ctx = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: band.width,
                    height: 1, bitsPerComponent: 8, bytesPerRow: band.width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
                ctx.draw(band, in: CGRect(x: 0, y: 0, width: band.width, height: 1))
            }
            let step = max(1, Int((scale * 1.5).rounded()))
            var edges = 0, previous = Int(samples[0])
            for i in stride(from: step, to: samples.count, by: step) {
                let next = Int(samples[i])
                if abs(next - previous) > 15 { edges += 1 }
                previous = next
            }
            print("PRESENTATION \(name) screen=\(screen) toolbar=\(frame) edges=\(edges)")
            XCTAssertLessThan(edges, 10, "A second row of keycaps is visible behind the toolbar.")
        }
        try checkSurface("MonkeyBoard on first focus")
        app.buttons["hide-keyboard"].tap()
        let picker = openSoundPicker(in: app)
        let original = try XCTUnwrap(picker.value as? String)
        addTeardownBlock {
            app.launch()
            self.chooseSound(original, picker: self.openSoundPicker(in: app), app: app)
        }
        chooseSound(original == "Soft Tap" ? "Hollow Tap" : "Soft Tap", picker: picker, app: app)
        // Return without relaunching: the reported overlap occurred after auditioning a sound.
        let back = app.buttons["BackButton"]
        if back.exists { back.tap() } else {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.48))
            start.press(forDuration: 0.06, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.48)))
        }
        XCTAssertTrue(draft.waitForExistence(timeout: 4), "Return to the same draft after selecting a sound")
        draft.tap()
        selectMonkeyBoard(in: app)
        try checkSurface("MonkeyBoard after picking a sound")
        let ownGlobe = app.buttons["key-Next keyboard"]
        let systemGlobe = app.buttons["Next keyboard"].firstMatch
        (ownGlobe.exists ? ownGlobe : systemGlobe).tap()
        let appleQ = app.keys.matching(NSPredicate(format: "label ==[c] %@", "q")).firstMatch
        if !appleQ.waitForExistence(timeout: 2), systemGlobe.exists { systemGlobe.tap() }
        XCTAssertTrue(appleQ.waitForExistence(timeout: 4), "Switch to the English system keyboard")
        XCTAssertFalse(app.buttons["keyboard-options"].exists)
        selectMonkeyBoard(in: app)
        try checkSurface("MonkeyBoard after switching from Apple")
        app.buttons["hide-keyboard"].tap()
        draft.tap()
        XCTAssertTrue(app.buttons["keyboard-options"].waitForExistence(timeout: 4))
        try checkSurface("MonkeyBoard after reopening")
        letter("k", in: app).tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "k")
    }

    private func openSoundPicker(in app: XCUIApplication) -> XCUIElement {
        app.buttons["keyboard-settings"].tap()
        let picker = app.buttons["typing-sound"]
        for _ in 0..<5 where !picker.isHittable { app.swipeUp() }
        return picker
    }

    private func chooseSound(_ title: String, picker: XCUIElement, app: XCUIApplication) {
        picker.tap()
        app.buttons[title].firstMatch.tap()
        XCTAssertEqual(picker.value as? String, title)
    }

    func testTypingSoundPickerPersistsAndTypes() throws {
        let app = XCUIApplication()
        app.launch()
        let picker = openSoundPicker(in: app)
        let original = try XCTUnwrap(picker.value as? String)
        addTeardownBlock {
            app.launch()
            self.chooseSound(original, picker: self.openSoundPicker(in: app), app: app)
        }
        for name in ["System Click", "iOS-Style Click", "Soft Tap", "Crisp Tick", "Mechanical", "Hollow Tap", "Soft Knock", "Off", "Soft Knock"] {
            chooseSound(name, picker: picker, app: app)
        }
        app.launch()
        XCTAssertEqual(openSoundPicker(in: app).value as? String, "Soft Knock")
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        letter("k", in: app).tap()
        let space = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["key-Space", "key-Space-left"])).firstMatch
        space.tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "k ")
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "k")
    }

    #if MONKEYBOARD_SOUND_BENCHMARK
    func testPhysicalTypingSoundFootprint() throws {
        let app = XCUIApplication()
        app.launch()
        let original = try XCTUnwrap(openSoundPicker(in: app).value as? String)
        addTeardownBlock {
            app.launch()
            self.chooseSound(original, picker: self.openSoundPicker(in: app), app: app)
        }
        for mode in ["Off", "Soft Knock", "Soft Knock", "Off"] {
            app.launch()
            chooseSound(mode, picker: openSoundPicker(in: app), app: app)
            app.launch()
            let draft = app.textViews["draft"]
            draft.tap()
            selectMonkeyBoard(in: app)
            let probe = app.descendants(matching: .any)["sound-footprint-probe"].firstMatch
            XCTAssertTrue(probe.waitForExistence(timeout: 5))
            let initial = try XCTUnwrap(probe.value as? String)
            print("SOUND_START \(initial)")
            if mode != "Off" {
                XCTAssertTrue(initial.hasPrefix(mode + "|true|"), "Allow Full Access on the phone to measure actual playback: " + initial)
            }
            let passage = "we can meet by the lake "
            // Capture the key centers once. Tap the actual keyboard, including spaces.
            var centers: [Character: XCUICoordinate] = [:]
            for char in Set(passage) {
                let key = char == " " ? app.buttons.matching(NSPredicate(format: "identifier IN %@", ["key-Space", "key-Space-left"])).firstMatch : letter(String(char), in: app)
                XCTAssertTrue(key.exists)
                centers[char] = key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            }
            let text = passage + passage
            for char in text { centers[char]!.tap() }
            let result = try XCTUnwrap(probe.value as? String)
            print("SOUND_RESULT \(result)")
            let fields = result.components(separatedBy: "|")
            XCTAssertEqual(fields.count, 8)
            XCTAssertEqual(Int(fields[3]), text.count)
            XCTAssertEqual(Int(fields[4]), mode == "Off" ? 0 : text.count)
            XCTAssertGreaterThan(Int(fields[5]) ?? 0, 0)
            XCTAssertEqual((draft.value as? String)?.lowercased(), text)
        }
    }
    #endif

    func testEmojiPickerSearchInsertionRecentsAndReturn() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        let smiley = app.buttons["key-Emoji"]
        XCTAssertTrue(smiley.exists, "The keyboard needs a dedicated emoji key.")
        smiley.tap()
        app.buttons["emoji-category-food"].tap()
        app.cells["emoji-🍇"].tap()
        XCTAssertEqual(draft.value as? String, "🍇")

        app.buttons["emoji-search"].tap()
        for character in "monkey" { letter(String(character), in: app).tap() }
        XCTAssertEqual(draft.value as? String, "🍇", "Search text stays inside the picker.")
        app.cells["emoji-🐒"].tap()
        XCTAssertEqual(draft.value as? String, "🍇🐒")
        app.buttons["emoji-done"].tap()
        app.buttons["emoji-category-recent"].tap()
        XCTAssertTrue(app.cells["emoji-🐒"].exists)
        app.buttons["emoji-category-smileys"].tap()
        let picker = XCTAttachment(screenshot: app.screenshot())
        picker.name = "Emoji picker in the keyboard"
        picker.lifetime = .keepAlways
        add(picker)
        app.buttons["emoji-delete"].tap()
        app.buttons["emoji-abc"].tap()
        letter("x", in: app).tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "🍇x")
        smiley.tap()
        XCTAssertTrue(app.cells["emoji-🐒"].exists)
    }

    func testEmojiSkinToneAndEditingSearch() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        app.buttons["key-Emoji"].tap()
        app.buttons["emoji-search"].tap()
        for character in "zzzz" { letter(String(character), in: app).tap() }
        XCTAssertTrue(app.staticTexts["No matching emoji"].exists)
        app.buttons["emoji-clear"].tap()
        for character in "thumbs upx" {
            if character == " " {
                let left = app.buttons["key-Space-left"]
                (left.exists ? left : app.buttons["key-Space"]).tap()
            } else { letter(String(character), in: app).tap() }
        }
        app.buttons["key-Delete"].tap()
        XCTAssertEqual(app.buttons["emoji-search"].value as? String, "thumbs up")
        let thumb = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "thumbs up")).firstMatch
        thumb.press(forDuration: 0.8)
        app.buttons["👍🏽  thumbs up, medium skin tone"].tap()
        XCTAssertEqual(draft.value as? String, "👍🏽")
        app.buttons["emoji-done"].tap()
        app.buttons["emoji-category-recent"].tap()
        XCTAssertTrue(app.cells["emoji-👍🏽"].exists)
        app.buttons["emoji-delete"].tap()
        XCTAssertEqual(draft.value as? String ?? "", "")
    }

    func testAppearanceFontUpdatesPreviewAndLiveKey() throws {
        let app = XCUIApplication()
        let picker = app.buttons["keyboard-font-picker"]
        func openAppearance() {
            app.buttons["keyboard-settings"].tap()
            app.buttons["appearance-settings"].tap()
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
        }
        func choose(_ name: String) {
            picker.tap()
            app.buttons[name].tap()
            XCTAssertEqual(picker.value as? String, name)
        }
        func keyFace() throws -> Data {
            app.launch()
            app.textViews["draft"].tap()
            selectMonkeyBoard(in: app)
            let image = try XCTUnwrap(letter("w", in: app).screenshot().image.cgImage)
            let center = CGRect(x: image.width / 4, y: image.height / 4,
                                width: image.width / 2, height: image.height / 2)
            let glyph = try XCTUnwrap(image.cropping(to: center))
            return try XCTUnwrap(UIImage(cgImage: glyph).pngData())
        }

        app.launch()
        openAppearance()
        let original = try XCTUnwrap(picker.value as? String)
        XCTAssertFalse(original.isEmpty)
        addTeardownBlock {
            app.launch()
            openAppearance()
            choose(original)
        }
        choose("System")
        let system = try keyFace()
        app.buttons["hide-keyboard"].tap()
        openAppearance()
        let preview = app.cells.containing(.staticText, identifier: "Light").firstMatch
        let systemPreview = preview.screenshot().pngRepresentation
        for font in ["Monospaced", "Rounded", "Serif"] {
            choose(font)
            XCTAssertNotEqual(systemPreview, preview.screenshot().pngRepresentation, "\(font) preview should redraw.")
        }
        let serif = try keyFace()
        XCTAssertNotEqual(system, serif, "The selected font should change the visible letter.")
        app.buttons["hide-keyboard"].tap()
        openAppearance()
        XCTAssertEqual(picker.value as? String, "Serif")
    }

    func testNumericFieldsUseKeypadAndRestoreTextKeyboard() throws {
        let host = XCUIApplication()
        host.launch()
        host.textViews["draft"].tap()
        selectMonkeyBoard(in: host)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        // Use a real host's input traits and change focus without dismissing its keyboard.
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>input{display:block;font-size:18px;margin:12px}</style>
        <input aria-label="Integer" inputmode="numeric">
        <input aria-label="Amount" inputmode="decimal">
        <input aria-label="Name" type="text">
        """
        let url = try XCTUnwrap(URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString()))
        safari.open(url)
        let amount = safari.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 10))
        amount.tap()
        let shot = XCTAttachment(screenshot: safari.screenshot())
        shot.name = "Decimal keypad"
        shot.lifetime = .keepAlways
        add(shot)

        func key(_ value: String) -> XCUIElement { safari.buttons["key-" + value] }
        XCTAssertTrue(key("1").waitForExistence(timeout: 3), "Enable and select MonkeyBoard before running.")
        XCTAssertFalse(key("ABC").exists)
        XCTAssertFalse(safari.buttons["keyboard-options"].exists)
        let separator = Locale.current.decimalSeparator ?? "."
        for value in ["1", separator, "5", "Delete", "2"] { key(value).tap() }
        XCTAssertEqual(amount.value as? String, "1" + separator + "2")
        let whole = safari.textFields["Integer"]
        whole.tap()
        XCTAssertFalse(key(separator).exists)
        XCTAssertFalse(key("Space").exists)
        XCTAssertGreaterThan(key("4").frame.minY, key("1").frame.minY)
        XCTAssertEqual(key("0").frame.midX, key("2").frame.midX, accuracy: 2)
        for value in ["0", "9", "8"] { key(value).tap() }
        XCTAssertEqual(whole.value as? String, "098")
        key("Delete").press(forDuration: 0.85)
        XCTAssertEqual(whole.value as? String ?? "", "")
        let hide = safari.buttons["hide-keyboard"]
        XCTAssertGreaterThanOrEqual(hide.frame.minY, key("0").frame.maxY)
        hide.tap()
        XCTAssertTrue(key("0").waitForNonExistence(timeout: 3))
        safari.textFields["Name"].tap()
        XCTAssertTrue(letter("a", in: safari).waitForExistence(timeout: 3))
        key("123").tap()
        XCTAssertTrue(key("#+=").exists)
    }

    func testSymbolPagesShowActionIconsAndRespectReturnSetting() throws {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        func key(_ title: String) -> XCUIElement { app.buttons["key-" + title] }
        func checkIcons() throws {
            for title in ["Delete", "Return"] {
                // Inspect the middle of the painted key. Its accessibility label
                // still exists when an opaque key face covers the glyph.
                let image = try XCTUnwrap(key(title).screenshot().image.cgImage)
                let center = CGRect(x: CGFloat(image.width) * 0.2, y: CGFloat(image.height) * 0.2,
                                    width: CGFloat(image.width) * 0.6, height: CGFloat(image.height) * 0.6)
                let crop = try XCTUnwrap(image.cropping(to: center))
                let gray = try XCTUnwrap(CGContext(data: nil, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue))
                gray.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                let pixels = UnsafeBufferPointer(start: try XCTUnwrap(gray.data).assumingMemoryBound(to: UInt8.self),
                                                 count: crop.width * crop.height)
                XCTAssertGreaterThan(Int(pixels.max()!) - Int(pixels.min()!), 45, "\(title) icon is blank")
            }
        }
        key("123").tap()
        try checkIcons()
        key("Delete").tap()
        key("#+=").tap()
        try checkIcons()
        key("=").tap()
        XCTAssertTrue(letter("a", in: app).exists)
        key("123").tap()
        key("5").tap()
        XCTAssertTrue(letter("a", in: app).exists)
        XCTAssertEqual(draft.value as? String, "=5")

        func changeSetting(_ enabled: Bool) {
            app.buttons["hide-keyboard"].tap()
            app.buttons["keyboard-settings"].tap()
            let toggle = app.switches["return-after-symbol"]
            XCTAssertEqual(toggle.value as? String, enabled ? "0" : "1")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
        }
        changeSetting(false)
        app.terminate()
        app.launch()
        draft.tap()
        selectMonkeyBoard(in: app)
        key("123").tap()
        key("7").tap()
        key("8").tap()
        key("Delete").tap()
        key("Return").tap()
        key("#+=").tap()
        key("[").tap()
        key("]").tap()
        XCTAssertEqual(draft.value as? String, "7\n[]")
        XCTAssertTrue(key("ABC").exists)
        changeSetting(true)
    }

    func testTypingWithInstalledExtension() throws {
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["keyboard-settings"]
        settings.tap()
        let slider = app.sliders["firmness-slider"]
        app.swipeUp()
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        slider.adjust(toNormalizedSliderPosition: 0.84)
        let chosen = try XCTUnwrap(slider.value as? String)
        XCTAssertTrue(chosen.contains("%"))
        let preview = app.buttons["Try a keypress"]
        if !preview.isHittable { app.swipeUp() }
        preview.tap()
        let back = app.buttons["BackButton"]
        if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
        let draft = app.textViews["draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        func key(_ title: String) -> XCUIElement { app.buttons["key-" + title] }
        func space() -> XCUIElement {
            let left = key("Space-left")
            return left.exists ? left : key("Space")
        }
        func letter(_ lower: String) -> XCUIElement {
            self.letter(lower, in: app)
        }
        selectMonkeyBoard(in: app)
        XCTAssertTrue(space().waitForExistence(timeout: 5), "Enable MonkeyBoard in Settings before testing.")
        let first = letter("h")
        let initial = first.label
        first.tap()
        letter("i").tap()
        space().tap()
        key("123").tap()
        key("2").tap()
        key("Delete").tap()
        key("123").tap()
        key("7").tap()
        XCTAssertEqual(draft.value as? String, initial + "i 7")
        let q = letter("q")
        q.press(forDuration: 0.2, thenDragTo: letter("w"))
        XCTAssertEqual(draft.value as? String, initial + "i 7w")

        key("Delete").tap()
        letter("h").tap()
        letter("e").tap()
        let completion = app.buttons["suggestion-1"]
        XCTAssertTrue(completion.waitForExistence(timeout: 3))
        let word = completion.label
        XCTAssertTrue(word.lowercased().hasPrefix("he"))
        completion.tap()
        XCTAssertEqual(draft.value as? String, initial + "i 7" + word + " ")

        let feedback = app.buttons["keyboard-options"]
        XCTAssertEqual(feedback.value as? String, chosen)
        let keyboard = XCTAttachment(screenshot: app.screenshot())
        keyboard.name = "Keyboard in host app"
        keyboard.lifetime = .keepAlways
        add(keyboard)
        let presets = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Keypress Feedback")).firstMatch
        feedback.tap()
        presets.tap()
        app.buttons["Firm"].tap()
        XCTAssertEqual(feedback.value as? String, "Firm")
        feedback.tap()
        presets.tap()
        app.buttons["Soft"].tap()
        XCTAssertEqual(feedback.value as? String, "Soft")
        app.buttons["hide-keyboard"].tap()
        XCTAssertTrue(feedback.waitForNonExistence(timeout: 3))
        settings.tap()
        if !slider.isHittable { app.swipeUp() }
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        XCTAssertEqual(slider.value as? String, "28%")
    }

    func testDoubleTappingAWordUsesItsCaseForReplacement() throws {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        if letter("r", in: app).label == "r" { app.buttons["key-Shift"].tap() }
        typePhrase("red fox. ", in: app)
        XCTAssertEqual(draft.value as? String, "Red fox. ")
        XCTAssertEqual(letter("c", in: app).label, "C")

        let start = draft.coordinate(withNormalizedOffset: .zero)
        let secondWord = start.withOffset(CGVector(dx: 52, dy: 20))
        secondWord.doubleTap()
        XCTAssertEqual(letter("c", in: app).label, "c")
        typePhrase("cat", in: app)
        XCTAssertEqual(draft.value as? String, "Red cat. ")

        secondWord.doubleTap()
        app.buttons["key-Shift"].tap()
        typePhrase("sam", in: app)
        XCTAssertEqual(draft.value as? String, "Red Sam. ")
        secondWord.doubleTap()
        XCTAssertEqual(letter("b", in: app).label, "B")

        let firstWord = start.withOffset(CGVector(dx: 18, dy: 20))
        firstWord.doubleTap()
        XCTAssertEqual(letter("b", in: app).label, "B")
        app.buttons["key-Shift"].tap()
        typePhrase("red", in: app)
        XCTAssertEqual(draft.value as? String, "red Sam. ")
        firstWord.doubleTap()
        app.buttons["key-Delete"].tap()
        // UIKit can remove the adjoining space when deleting a selected word.
        let remainder = try XCTUnwrap(draft.value as? String)
        XCTAssertEqual(remainder.trimmingCharacters(in: .whitespaces), "Sam.")
        typePhrase("big", in: app)
        XCTAssertEqual(draft.value as? String, "big" + remainder)
    }

    func testTapBelowSpacebarInsertsSpace() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        var expected = draft.value as? String ?? ""
        func checkLowTaps() {
            let spacebars = app.buttons.matching(NSPredicate(format: "label == 'Space'")).allElementsBoundByIndex
            XCTAssertFalse(spacebars.isEmpty)
            // Return shares the painted bottom edge with Space.
            let bottomRow = app.buttons["key-Return"].frame
            for space in spacebars {
                letter("a", in: app).tap()
                expected += "a "
                origin.withOffset(CGVector(dx: space.frame.midX, dy: bottomRow.maxY + 10)).tap()
                XCTAssertEqual((draft.value as? String)?.lowercased(), expected.lowercased())
            }
            origin.withOffset(CGVector(dx: bottomRow.midX, dy: bottomRow.maxY + 10)).tap()
            XCTAssertEqual((draft.value as? String)?.lowercased(), expected.lowercased())
        }
        let toggle = app.buttons["toggle-split-layout"]
        if toggle.exists {
            checkLowTaps()
            toggle.tap()
            defer { toggle.tap() }
            checkLowTaps()
        } else {
            for layout in ["Left Hand", "Right Hand", "Full Width"] {
                app.buttons["keyboard-options"].tap()
                app.buttons[layout].tap()
                checkLowTaps()
            }
        }
    }

    func testSpaceAndPeriodOnEitherSideOfTheirGap() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        let toggle = app.buttons["toggle-split-layout"]
        let initialLayout = toggle.exists ? toggle.label : nil
        defer { if let initialLayout, toggle.label != initialLayout { toggle.tap() } }
        for pass in 0..<(initialLayout == nil ? 1 : 2) {
            if pass == 1 { toggle.tap() }
            let period = app.buttons["key-."]
            let edge = period.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            let original = draft.value as? String ?? ""
            // The punctuation control starts halfway through the inter-key gap.
            edge.withOffset(CGVector(dx: -1, dy: 0)).tap()
            XCTAssertEqual(draft.value as? String, original + " ")
            edge.withOffset(CGVector(dx: 1, dy: 0)).tap()
            period.tap()
            XCTAssertEqual(draft.value as? String, original + " ..")
        }
    }

    func testUndoEarlierCorrectionAfterTypingAhead() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("can you fine anything ", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "can you find anything ")
        typePhrase("today", in: app)
        let undo = app.buttons["undo-autocorrection"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "can you fine anything today")
        typePhrase(" please.", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "can you fine anything today please.")
        XCTAssertFalse(undo.exists)
    }

    func testBackspaceDeletesTypedAheadTextAndUndoKeepsTheSpace() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("my keybaord ab", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "my keyboard ab")
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "my keyboard a")
        app.buttons["undo-autocorrection"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "my keybaord a")
    }

    func testCorrectionUndoExpiresWhenSelectionChanges() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("put teh mug", in: app)
        let undo = app.buttons["undo-autocorrection"]
        XCTAssertTrue(undo.waitForExistence(timeout: 4))
        let before = draft.value as? String
        draft.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).doubleTap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 3))
        XCTAssertEqual(draft.value as? String, before)
    }

    func testTapInLetterGapInsertsNearestLetter() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        // The button includes half the 4pt visual gap on each side. These
        // fractions land 1pt inside its touch target, outside the painted cap.
        let e = letter("e", in: app), r = letter("r", in: app)
        e.coordinate(withNormalizedOffset: CGVector(dx: 1 - 1 / e.frame.width, dy: 0.5)).tap()
        r.coordinate(withNormalizedOffset: CGVector(dx: 1 / r.frame.width, dy: 0.5)).tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "er")
    }

    func testSameTypoDependsOnSentenceAndCanBeUndone() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        let left = app.buttons["key-Space-left"]
        let space = left.exists ? left : app.buttons["key-Space"]
        func type(_ text: String) {
            for ch in text {
                if ch == " " { space.tap() }
                else { letter(String(ch), in: app).tap() }
            }
        }
        type("the novel goes beside my boog")
        app.buttons["key-."].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "the novel goes beside my book.")
        type(" the shoe goes beside my boog ")
        XCTAssertEqual((draft.value as? String)?.lowercased(), "the novel goes beside my book. the shoe goes beside my boot ")
        app.buttons["key-Delete"].tap()
        XCTAssertTrue((draft.value as? String)?.hasSuffix("my boog") == true)
    }

    func testTypingSurvivesFieldChangesDuringSentenceReview() throws {
        let host = XCUIApplication()
        host.launch()
        host.textViews["draft"].tap()
        selectMonkeyBoard(in: host)

        let browser = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>input{display:block;font-size:18px;margin:12px}</style>
        <input aria-label="First message"><input aria-label="Second message">
        """
        let url = try XCTUnwrap(URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString()))
        browser.open(url)
        let first = browser.textFields["First message"], second = browser.textFields["Second message"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        typePhrase("the novel gos ", in: browser)
        let original = try XCTUnwrap(first.value as? String)
        second.tap()
        typePhrase("on my way", in: browser)
        XCTAssertEqual((second.value as? String)?.lowercased(), "on my way")
        XCTAssertEqual(first.value as? String, original)

        browser.buttons["hide-keyboard"].tap()
        XCTAssertTrue(browser.buttons["hide-keyboard"].waitForNonExistence(timeout: 5))
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(browser.buttons["hide-keyboard"].waitForExistence(timeout: 5))
        typePhrase("here", in: browser)
        XCTAssertEqual((first.value as? String)?.lowercased(), original.lowercased() + "here")
        XCTAssertEqual((second.value as? String)?.lowercased(), "on my way")
    }

    func testTransformerRevisitsAnEarlierWordAndPreservesTheCaret() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        let splitSpace = app.buttons["key-Space-left"]
        let space = splitSpace.exists ? splitSpace : app.buttons["key-Space"]
        func type(_ text: String) {
            for ch in text {
                if ch == " " { space.tap() } else { letter(String(ch), in: app).tap() }
            }
        }
        type("the novel gos ")
        XCTAssertEqual((draft.value as? String)?.lowercased(), "the novel gos ")
        type("beside ")
        let revised = NSPredicate(format: "value ==[c] %@", "the novel goes beside ")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: revised, object: draft)],
                                      timeout: 8), .completed, "Final draft: \(draft.value as? String ?? "<unavailable>")")
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "the novel gos beside ")
        type("my book")
        app.buttons["key-."].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "the novel gos beside my book.")
    }

    func testTransformerRevisesPaidAndKeepsLeekInSoup() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        let splitSpace = app.buttons["key-Space-left"]
        let space = splitSpace.exists ? splitSpace : app.buttons["key-Space"]
        func type(_ text: String) {
            for ch in text {
                if ch == " " { space.tap() } else { letter(String(ch), in: app).tap() }
            }
        }
        type("she already padi ")
        XCTAssertEqual((draft.value as? String)?.lowercased(), "she already padi ")
        type("for ")
        let corrected = NSPredicate(format: "value ==[c] %@", "she already paid for ")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: corrected, object: draft)],
                                      timeout: 8), .completed)
        type("the tickets")
        app.buttons["key-."].tap()
        type(" i put a leek in the soup")
        app.buttons["key-."].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "she already paid for the tickets. i put a leek in the soup.")
    }

    private func tapComma(in app: XCUIApplication) {
        let comma = app.buttons["key-,"].firstMatch
        if !comma.exists { app.buttons["key-123"].tap() }
        comma.tap()
    }

    private func typePhrase(_ text: String, in app: XCUIApplication) {
        let splitSpace = app.buttons["key-Space-left"]
        let space = splitSpace.exists ? splitSpace : app.buttons["key-Space"]
        for ch in text {
            switch ch {
            case " ": space.tap()
            case ",":
                tapComma(in: app)
                if app.buttons["key-ABC"].exists { app.buttons["key-ABC"].tap() }
            default: letter(String(ch), in: app).tap()
            }
        }
    }

    func testSentenceModelDistinguishesASeatFromFlowers() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("a wooden bench. we bought a bench of tulips.", in: app)
        let finished = NSPredicate { _, _ in
            (draft.value as? String)?.lowercased() == "a wooden bench. we bought a bunch of tulips."
        }
        let repaired = XCTNSPredicateExpectation(predicate:finished, object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[repaired],timeout:12), .completed,
                       "The same spelling should survive the seating context and change in the flower context; got \(draft.value ?? "")")
    }

    func testLeakByTheSinkAndLeekInSoup() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("there is a leek under the ", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "there is a leek under the ")
        typePhrase("sink ", in: app)
        let revised = NSPredicate(format: "value ==[c] %@", "there is a leak under the sink ")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: revised, object: draft)],
                                      timeout: 6), .completed)
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "there is a leek under the sink ")
        typePhrase("today", in: app)
        app.buttons["key-."].tap()
        typePhrase(" there is a leek in the soup ", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "there is a leek under the sink today. there is a leek in the soup ")
    }

    func testDictionarySpaceAndIntentionalWholeWord() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("the little doglaughed ", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "the little dog laughed ")
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "the little doglaughed")
        typePhrase(" today. we tried papermaking.", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "the little doglaughed today. we tried papermaking.")
    }

    func testMeetingPlaceResolvesMissingSpaceAndUndo() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("we metin ", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "we metin ")
        typePhrase("phoenix.", in: app)
        let fixed = NSPredicate(format: "value ==[c] %@", "we met in phoenix.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: fixed, object: draft)],
                                      timeout: 6), .completed)
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "we metin phoenix.")
    }

    func testShortWordReplacementsPreserveDeliberateBe() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("out od milk. it must be ready be noon.", in: app)
        let fixed = NSPredicate(format: "value ==[c] %@", "out of milk. it must be ready by noon.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: fixed, object: draft)],
                                      timeout: 6), .completed)
    }

    func testParentheticalByWaitsForBothWords() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("sorry, be the ", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "sorry, be the ")
        typePhrase("way.", in: app)
        let fixed = NSPredicate(format: "value ==[c] %@", "sorry, by the way.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: fixed, object: draft)],
                                      timeout: 6), .completed)
    }

    func testDeletingLowercaseSelectionKeepsReplacementLowercase() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        // Deliberately start with a lowercase word. The new insertion point is
        // a sentence start, but replacing this selected spelling should stay lowercase.
        if app.buttons["key-Shift"].exists && letter("q", in: app).label == "Q" {
            app.buttons["key-Shift"].tap()
        }
        typePhrase("red fox", in: app)
        XCTAssertEqual(draft.value as? String, "red fox")
        let origin = draft.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: 18, dy: 20)).doubleTap()
        app.buttons["key-Delete"].tap()
        XCTAssertFalse((draft.value as? String)?.contains("red") ?? true)
        letter("b", in: app).tap()
        XCTAssertTrue((draft.value as? String)?.hasPrefix("b") == true)
    }

    func testStraightDoubleQuoteOn123Page() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        app.buttons["key-123"].tap()
        let quote = app.buttons["key-\""]
        XCTAssertTrue(quote.exists)
        quote.tap()
        XCTAssertEqual(draft.value as? String, "\"")
    }

    func testTrainedContextPreservesTenseAndMeaning() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("it was directed be a woman. if it had a bar. cheese in all three.", in: app)
        let expected = "it was directed by a woman. if it had a bar. cheese in all three."
        let fixed = NSPredicate(format: "value ==[c] %@", expected)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: fixed, object: draft)], timeout: 6), .completed)
    }

    func testLearnedShortWordsInTheTypingField() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("the statement if work. my coworker id getting ready.", in: app)
        let fixed = NSPredicate(format: "value ==[c] %@", "the statement of work. my coworker is getting ready.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: fixed, object: draft)],
                                      timeout: 6), .completed)
        typePhrase(" bring my id badge if you can.", in: app)
        XCTAssertTrue((draft.value as? String)?.hasSuffix("my id badge if you can.") == true)
    }

    func testLandlordCopulaAfterNounAndUndo() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("my landlord us a ", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "my landlord us a ")
        typePhrase("barista.", in: app)
        let fixed = NSPredicate(format: "value ==[c] %@", "my landlord is a barista.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: fixed, object: draft)],
                                      timeout: 6), .completed)
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "my landlord us a barista.")
        typePhrase(" my landlord sent us a map.", in: app)
        XCTAssertTrue((draft.value as? String)?.lowercased().hasSuffix("my landlord sent us a map.") == true)
    }

    func testMissingSpaceAfterNextWordAndUndo() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("pick up the kidsin ", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "pick up the kidsin ")
        typePhrase("the ", in: app)
        let fixed = NSPredicate(format: "value ==[c] %@", "pick up the kids in the ")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: fixed, object: draft)],
                                      timeout: 6), .completed)
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "pick up the kidsin the ")
        typePhrase("morning. the code is kidsin for today.", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "pick up the kidsin the morning. the code is kidsin for today.")
    }

    func testAnotherAfterTestAndUndo() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("this is amanor ", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "this is amanor ")
        typePhrase("test.", in: app)
        let fixed = NSPredicate(format: "value ==[c] %@", "this is another test.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: fixed, object: draft)],
                                      timeout: 6), .completed)
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "this is amanor test.")
        typePhrase(" the code is amanor test.", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "this is amanor test. the code is amanor test.")
    }

    func testIntentionalFoodNameStaysTyped() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("want to grab pad thai after work.", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "want to grab pad thai after work.")
    }

    func testNotesSentenceAndMissingSpaceUndo() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("lets try yhid out and see what were got.", in: app)
        let corrected = NSPredicate(format: "value ==[c] %@", "let's try this out and see what we've got.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: corrected, object: draft)],
                                      timeout: 8), .completed)
        typePhrase(" help me find mykeys ", in: app)
        XCTAssertTrue((draft.value as? String)?.hasSuffix("my keys ") == true)
        app.buttons["key-Delete"].tap()
        XCTAssertTrue((draft.value as? String)?.hasSuffix("mykeys") == true)
    }

    func testTenantReportAndVegetableBySameFixture() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)

        typePhrase("the tenant reported a leek behind the ", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "the tenant reported a leek behind the ")
        typePhrase("toilet.", in: app)
        let corrected = NSPredicate(format: "value ==[c] %@", "the tenant reported a leak behind the toilet.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: corrected, object: draft)],
                                      timeout: 6), .completed)
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "the tenant reported a leek behind the toilet.")
        typePhrase(" i dropped a leek behind the toilet.", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(),
                       "the tenant reported a leek behind the toilet. i dropped a leek behind the toilet.")
    }

    func testSentenceCorrectionCommitsAndUndoesInHost() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        let left = app.buttons["key-Space-left"]
        let space = left.exists ? left : app.buttons["key-Space"]
        for word in ["my", "dsd"] {
            for ch in word { letter(String(ch), in: app).tap() }
            space.tap()
        }
        XCTAssertEqual((draft.value as? String)?.lowercased(), "my dad ")
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "my dsd")
    }

    func testLearningSpeedTypingAndSwipePreferences() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Exercises reset only on a simulator with empty spelling memory.")
        #else
        let app = XCUIApplication()
        let draft = app.textViews["draft"]
        let reset = app.buttons["reset-spellings"]
        let speed = app.segmentedControls["learning-speed"]
        func memory() {
            app.launch()
            app.buttons["keyboard-settings"].tap()
            let link = app.buttons["personal-spellings"]
            for _ in 0..<4 where !link.isHittable { app.swipeUp() }
            link.tap()
        }
        func freshDraft() {
            app.launch()
            draft.tap()
            selectMonkeyBoard(in: app)
        }
        func space() {
            let left = app.buttons["key-Space-left"]
            (left.exists ? left : app.buttons["key-Space"]).tap()
        }
        func suggestion(_ word: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[c] %@",
                                             "suggestion-", word)).firstMatch
        }
        func swipeTo() {
            letter("t", in: app).press(forDuration: 0.12, thenDragTo: letter("o", in: app))
        }
        func expect(_ word: String) {
            XCTAssertEqual((draft.value as? String)?.lowercased(), word)
        }
        func typeTypo() {
            for ch in "teh" { letter(String(ch), in: app).tap() }
        }
        memory()
        try XCTSkipIf(reset.isEnabled, "Preserve existing user spelling memory.")
        let originalSpeed = try XCTUnwrap(["Fast", "Balanced", "Careful"].first { speed.buttons[$0].isSelected })
        addTeardownBlock {
            memory()
            if reset.isEnabled {
                reset.tap()
                app.alerts.buttons["Reset"].tap()
            }
            speed.buttons[originalSpeed].tap()
        }
        speed.buttons["Fast"].tap()
        app.launch()
        app.buttons["keyboard-settings"].tap()
        enableForTest("glide-typing", inSettingsOf: app)
        enableForTest("auto-correction", inSettingsOf: app)

        freshDraft()
        swipeTo()
        suggestion("too").tap()
        app.buttons["key-Delete"].tap()
        memory()
        XCTAssertFalse(reset.isEnabled, "Deleting a swipe discards its feedback")

        freshDraft()
        swipeTo()
        for word in ["too", "to", "too"] { suggestion(word).tap() }
        space()
        expect("too ")
        memory()
        XCTAssertTrue(reset.isEnabled)
        XCTAssertFalse(app.buttons["edit-spelling-swipe-to"].exists, "One gesture is one choice")
        freshDraft()
        swipeTo()
        expect("to")
        suggestion("too").tap()
        space()
        freshDraft()
        swipeTo()
        expect("too")
        app.buttons["key-Delete"].tap()
        for ch in "to" { letter(String(ch), in: app).tap() }
        space()
        expect("to ")

        memory()
        XCTAssertTrue(app.buttons["edit-spelling-swipe-to"].exists)
        speed.buttons["Careful"].tap()
        for count in 1...5 {
            freshDraft()
            typeTypo()
            let pick = suggestion("the")
            XCTAssertTrue(pick.waitForExistence(timeout: 3))
            pick.tap()
            expect("the ")
            if count == 4 {
                memory()
                XCTAssertFalse(app.buttons["edit-spelling-teh"].exists)
            }
        }
        memory()
        app.buttons["edit-spelling-teh"].tap()
        let field = app.textFields["preferred-spelling"]
        field.tap()
        field.typeText("n")
        app.buttons["Save"].tap()
        freshDraft()
        typeTypo()
        space()
        expect("then ")
        memory()
        app.buttons["forget-spelling-swipe-to"].tap()
        XCTAssertFalse(app.buttons["edit-spelling-swipe-to"].exists)
        XCTAssertTrue(app.buttons["edit-spelling-teh"].exists)
        freshDraft()
        swipeTo()
        expect("to")
        memory()
        reset.tap()
        app.alerts.buttons["Reset"].tap()
        XCTAssertTrue(speed.buttons["Careful"].isSelected)
        XCTAssertFalse(reset.isEnabled)
        freshDraft()
        swipeTo()
        expect("to")
        app.buttons["key-Delete"].tap()
        typeTypo()
        space()
        expect("the ")
        #endif
    }

    func testRepeatedUndosLearnSpellingsAndForgetOrResetThem() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Spelling-memory reset is tested only on a simulator.")
        #else
        let app = XCUIApplication()
        let draft = app.textViews["draft"]
        func openMemory() {
            app.launch()
            app.buttons["keyboard-settings"].tap()
            let link = app.buttons["personal-spellings"]
            for _ in 0..<4 where !link.isHittable { app.swipeUp() }
            link.tap()
        }
        func freshDraft() {
            app.launch()
            draft.tap()
            selectMonkeyBoard(in: app)
        }
        func typeWord(_ text: String) {
            for ch in text { letter(String(ch), in: app).tap() }
        }
        func space() {
            let left = app.buttons["key-Space-left"]
            (left.exists ? left : app.buttons["key-Space"]).tap()
        }
        func expect(_ text: String) {
            XCTAssertEqual((draft.value as? String)?.lowercased(), text)
        }
        func reject(_ typed: String, _ corrected: String) {
            freshDraft()
            typeWord(typed)
            space()
            expect(corrected + " ")
            app.buttons["key-Delete"].tap()
            expect(typed)
        }
        let reset = app.buttons["reset-spellings"]
        openMemory()
        try XCTSkipIf(reset.isEnabled, "This test needs empty spelling memory; preserve existing user data.")
        let speeds = app.segmentedControls["learning-speed"].buttons
        let originalSpeed = try XCTUnwrap(["Fast", "Balanced", "Careful"].first { speeds[$0].isSelected })
        speeds["Balanced"].tap()
        addTeardownBlock {
            openMemory()
            if reset.isEnabled {
                reset.tap()
                app.alerts.buttons["Reset"].tap()
            }
            speeds[originalSpeed].tap()
        }
        app.launch()
        app.buttons["keyboard-settings"].tap()
        enableForTest("auto-correction", inSettingsOf: app)

        // One rejected correction does not become a preferred spelling.
        reject("teh", "the")
        openMemory()
        XCTAssertTrue(app.staticTexts["no-learned-spellings"].exists)
        XCTAssertTrue(reset.isEnabled, "Reset should clear pending evidence too")
        reject("teh", "the")
        reject("teh", "the")

        freshDraft()
        typeWord("teh")
        space()
        expect("teh ")
        typeWord("agian")
        app.buttons["key-."].tap()
        expect("teh again.")
        let unchanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (draft.value as? String)?.lowercased() != "teh again."
        }, object: nil)
        unchanged.isInverted = true
        wait(for: [unchanged], timeout: 1.6)

        openMemory()
        let forget = app.buttons["forget-spelling-teh"]
        XCTAssertTrue(forget.exists)
        forget.tap()
        XCTAssertTrue(app.staticTexts["no-learned-spellings"].exists)
        reject("teh", "the")   // Forget restores normal autocorrect.

        // A reset must remove both an established word and a pending rejection.
        reject("agian", "again")
        reject("agian", "again")
        reject("agian", "again")
        openMemory()
        XCTAssertTrue(app.buttons["forget-spelling-agian"].exists)
        reset.tap()
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["forget-spelling-agian"].exists)
        reset.tap()
        app.alerts.buttons["Reset"].tap()
        XCTAssertTrue(app.staticTexts["no-learned-spellings"].exists)
        XCTAssertFalse(reset.isEnabled)
        freshDraft()
        typeWord("agian")
        space()
        expect("again ")
        reject("teh", "the")
        reject("teh", "the")
        freshDraft()
        typeWord("teh")
        space()
        expect("the ")
        #endif
    }

    func testWordCorrectionAndUndo() throws {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        let left = app.buttons["key-Space-left"]
        let space = left.exists ? left : app.buttons["key-Space"]
        func typeWord(_ text: String) {
            for character in text { letter(String(character), in: app).tap() }
        }
        typeWord("teh")
        XCTAssertEqual(app.buttons["suggestion-1"].label.lowercased(), "the")
        space.tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "the ")
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "teh")
        space.tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "teh ")
        typeWord("keybaord")
        tapComma(in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "teh keyboard,")
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "teh keybaord")
        if app.buttons["key-ABC"].exists { app.buttons["key-ABC"].tap() }
        space.tap()
        typeWord("teh")
        app.buttons["suggestion-0"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "teh keybaord teh ")
    }

    func testLowercaseNameIsNotReplacedByAnotherName() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        if letter("n", in: app).label == "N" { app.buttons["key-Shift"].firstMatch.tap() }
        typePhrase("navid still has the tin.", in: app)
        XCTAssertEqual(draft.value as? String, "navid still has the tin.")
    }

    func testRejoinsMistypedSpaceWithoutRewritingNearbyName() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("call senthil about the mir ror.", in: app)
        let expected = NSPredicate(format: "value ==[c] %@", "call senthil about the mirror.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: draft)],
                                      timeout: 5), .completed, "Final text: \(draft.value ?? "<empty>")")
    }

    func testLaterContextKeepsAnAlreadyCorrectedSpelling() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("diid ", in: app)
        if letter("i", in: app).label != "I" { app.buttons["key-Shift"].firstMatch.tap() }
        typePhrase("i leave my lugagge next to the ticket machine.", in: app)
        let expected = NSPredicate(format: "value ==[c] %@", "did i leave my luggage next to the ticket machine.")
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: draft)], timeout: 5)
        XCTAssertEqual(result, .completed, "Final text: \(draft.value ?? "<empty>")")
    }

    func testRejoiningWordPreservesIndependentCorrection() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("add zucchini too the sho pping list.", in: app)
        let expected = NSPredicate(format: "value ==[c] %@", "add zucchini to the shopping list.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: draft)],
                                      timeout: 5), .completed)
    }

    func testContrastUsesContextForHerdAndPreservesAnIntentionalHerd() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("he herd the front door close. the herd moved on.", in: app)
        let correct = NSPredicate(format: "value ==[c] %@", "he heard the front door close. the herd moved on.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: correct, object: draft)],
                                      timeout: 5), .completed)
    }

    func testContextRepairsEarlierRealWordWithoutLosingTheFollowingWordOnUndo() {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        typePhrase("can you fine ", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "can you fine ")
        typePhrase("anything ", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "can you find anything ")
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "can you fine anything ")
        typePhrase("today.", in: app)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "can you fine anything today.")
    }

    func testCorrectionsUsePreviouslyCorrectedWord() throws {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        let left = app.buttons["key-Space-left"]
        let space = left.exists ? left : app.buttons["key-Space"]
        for word in ["to", "figurr", "ut"] {
            for ch in word { letter(String(ch), in: app).tap() }
            space.tap()
        }
        XCTAssertEqual((draft.value as? String)?.lowercased(), "to figure out ")
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "to figure ut")
    }

    func testDroppedApostrophesAtSpaceAndAfterSentenceReview() throws {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        if letter("i", in: app).label == "i" { app.buttons["key-Shift"].tap() }
        typePhrase("id ", in: app)
        XCTAssertEqual(draft.value as? String, "I'd ")
        app.buttons["key-Delete"].tap()
        XCTAssertEqual(draft.value as? String, "Id")
        typePhrase(" ", in: app)
        XCTAssertEqual(draft.value as? String, "Id ")
        typePhrase("said theyd go if itd help.", in: app)
        let expected = "Id said they'd go if it'd help."
        let finished = NSPredicate { _, _ in draft.value as? String == expected }
        let seen = XCTNSPredicateExpectation(predicate: finished, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [seen], timeout: 8), .completed)
        XCTAssertEqual(draft.value as? String, expected)
    }

    func testTextingContractionAndUndo() throws {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        let left = app.buttons["key-Space-left"]
        let space = left.exists ? left : app.buttons["key-Space"]
        let initial = letter("i", in: app).label
        letter("i", in: app).tap()
        letter("m", in: app).tap()
        space.tap()
        XCTAssertEqual(draft.value as? String, "I'm ")
        app.buttons["key-Delete"].tap()
        XCTAssertEqual(draft.value as? String, initial + "m")
        space.tap()
        XCTAssertEqual(draft.value as? String, initial + "m ")
        for ch in "ive" { letter(String(ch), in: app).tap() }
        typePhrase(",", in: app)
        XCTAssertEqual(draft.value as? String, initial + "m I've,")
    }

    func testAutomaticReplacementInBothLayoutsAndContextSuggestions() throws {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        func typeWord(_ word: String) {
            for character in word { letter(String(character), in: app).tap() }
        }
        func expect(_ text: String) {
            XCTAssertEqual((draft.value as? String)?.lowercased(), text)
        }
        func space(right: Bool = false) {
            let split = app.buttons[right ? "key-Space-right" : "key-Space-left"]
            (split.exists ? split : app.buttons["key-Space"]).tap()
        }
        typeWord("agian")
        space(right: true)
        expect("again ")
        app.buttons["key-Delete"].tap()
        expect("agian")
        space()
        expect("agian ")
        let toggle = app.buttons["toggle-split-layout"]
        if toggle.exists { toggle.tap() }
        typeWord("differnet")
        typePhrase(",", in: app)
        expect("agian different,")
        space()
        typeWord("thank")
        space()
        typeWord("you")
        space()
        typeWord("so")
        space()
        let much = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[c] %@", "suggestion-", "much")).firstMatch
        XCTAssertTrue(much.waitForExistence(timeout: 3))
        much.tap()
        expect("agian different, thank you so much ")
        if toggle.exists { toggle.tap() }
    }

    // Establish the preferences a gesture test relies on, preserving the prior settings.
    private func enableForTest(_ identifier: String, inSettingsOf app: XCUIApplication) {
        func control() -> XCUIElement {
            let toggle = app.switches[identifier]
            if !toggle.isHittable { app.swipeUp() }
            XCTAssertTrue(toggle.isHittable)
            return toggle
        }
        let toggle = control()
        guard toggle.value as? String == "0" else {
            XCTAssertEqual(toggle.value as? String, "1")
            return
        }
        addTeardownBlock {
            app.launch()
            app.buttons["keyboard-settings"].tap()
            let restored = control()
            if restored.value as? String == "1" {
                restored.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            }
            XCTAssertEqual(restored.value as? String, "0")
        }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
    }

    func testGlideInsertionAlternativesSpacingAndUndo() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["keyboard-settings"].tap()
        enableForTest("glide-typing", inSettingsOf: app)
        let back = app.buttons["BackButton"]
        if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)

        func glide(_ first: String, _ last: String) {
            letter(first, in: app).press(forDuration: 0.12, thenDragTo: letter(last, in: app))
        }
        func expect(_ text: String) {
            XCTAssertEqual((draft.value as? String)?.lowercased() ?? "", text)
        }

        glide("t", "o")
        expect("to")
        let too = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ==[c] %@",
                                                  "suggestion-", "too")).firstMatch
        XCTAssertTrue(too.waitForExistence(timeout: 2))
        too.tap()
        expect("too")
        glide("g", "o")
        expect("too go")
        app.buttons["key-Delete"].tap()
        expect("too")
        glide("t", "o")
        expect("too to")
        app.buttons["key-."].tap()
        expect("too to.")
        glide("g", "o")
        expect("too to. go")
        letter("x", in: app).tap()
        expect("too to. go x")
        letter("q", in: app).press(forDuration: 0.12, thenDragTo: letter("w", in: app))
        expect("too to. go xw")
    }

    func testDisablingGlideKeepsSlideToLetter() {
        let app = XCUIApplication()
        func openSetting() -> XCUIElement {
            app.launch()
            app.buttons["keyboard-settings"].tap()
            let toggle = app.switches["glide-typing"]
            if !toggle.isHittable { app.swipeUp() }
            XCTAssertTrue(toggle.isHittable)
            return toggle
        }
        let toggle = openSetting()
        let original = toggle.value as? String
        func flip(_ element: XCUIElement) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        }
        addTeardownBlock {
            let control = openSetting()
            if control.value as? String != original { flip(control) }
        }
        if original == "1" { flip(toggle) }
        XCTAssertEqual(toggle.value as? String, "0")
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        letter("t", in: app).press(forDuration: 0.12, thenDragTo: letter("o", in: app))
        XCTAssertEqual((draft.value as? String)?.lowercased(), "o")
    }

    func testOneHandedKeyboardOnCoverDisplay() throws {
        let app = XCUIApplication()
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        guard !app.buttons["toggle-split-layout"].exists else {
            throw XCTSkip("Close the Duo to test the cover keyboard.")
        }
        let menu = app.buttons["keyboard-options"]
        func choose(_ title: String) {
            menu.tap()
            let choice = app.buttons[title]
            XCTAssertTrue(choice.waitForExistence(timeout: 2))
            choice.tap()
        }
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        choose("Full Width")
        let q = letter("q", in: app), p = letter("p", in: app)
        let left = q.frame.minX, right = p.frame.maxX
        let height = q.frame.height
        let hide = app.buttons["hide-keyboard"]
        func checkHidePosition() {
            let layerKey = app.buttons["key-123"].frame
            XCTAssertEqual(hide.frame.minX, layerKey.minX, accuracy: 2)
            XCTAssertGreaterThanOrEqual(hide.frame.minY, layerKey.maxY - 1)
        }
        checkHidePosition()
        choose("Left Hand")
        XCTAssertEqual(q.frame.minX, left, accuracy: 2)
        XCTAssertLessThan(p.frame.maxX, right - 40)
        XCTAssertEqual(q.frame.height, height, accuracy: 1)
        checkHidePosition()
        q.press(forDuration: 0.15, thenDragTo: letter("w", in: app))
        XCTAssertEqual((draft.value as? String)?.lowercased(), "w")
        capture("Left-handed cover keyboard")

        choose("Right Hand")
        checkHidePosition()
        XCTAssertEqual(p.frame.maxX, right, accuracy: 2)
        XCTAssertGreaterThan(q.frame.minX, left + 40)
        XCTAssertGreaterThanOrEqual(menu.frame.minX, q.frame.minX - 3)
        let edge = q.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        edge.press(forDuration: 0.15, thenDragTo: edge.withOffset(CGVector(dx: -35, dy: 0)))
        XCTAssertEqual((draft.value as? String)?.lowercased(), "w")
        capture("Right-handed cover keyboard")
        app.buttons["key-123"].tap()
        app.buttons["key-0"].tap()
        if app.buttons["key-123"].exists { app.buttons["key-123"].tap() }
        app.buttons["key-#+="].tap()
        app.buttons["key-="].tap()
        if app.buttons["key-ABC"].exists { app.buttons["key-ABC"].tap() }
        XCTAssertEqual((draft.value as? String)?.lowercased(), "w0=")
        app.buttons["hide-keyboard"].tap()
        draft.tap()
        XCTAssertTrue(p.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(q.frame.minX, left + 40)
        app.buttons["expand-keyboard"].tap()
        XCTAssertEqual(q.frame.minX, left, accuracy: 2)
        XCTAssertEqual(p.frame.maxX, right, accuracy: 2)
    }

    func testYAndBCanBeTypedAndSwipedFromEitherHalf() throws {
        let originalOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        defer {
            if originalOrientation != .unknown { XCUIDevice.shared.orientation = originalOrientation }
        }
        let app = XCUIApplication()
        app.launch()
        app.buttons["keyboard-settings"].tap()
        enableForTest("split-wide-screens", inSettingsOf: app)
        enableForTest("repeat-split-letters", inSettingsOf: app)
        enableForTest("glide-typing", inSettingsOf: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        let layout = app.buttons["toggle-split-layout"]
        guard layout.exists else { throw XCTSkip("Open the Duo to test both sides of the keyboard.") }
        let leftY = app.buttons["key-y-left"], leftB = app.buttons["key-b-left"]
        let rightY = letter("y", in: app), rightB = letter("b", in: app)
        XCTAssertLessThan(leftY.frame.maxX, rightY.frame.minX)
        XCTAssertLessThan(leftB.frame.maxX, rightB.frame.minX)

        for (b, y) in [(leftB, leftY), (rightB, rightY)] {
            b.press(forDuration: 0.12, thenDragTo: y)
            XCTAssertEqual((draft.value as? String)?.lowercased(), "by")
            app.buttons["key-Delete"].tap()
        }
        let initial = rightY.label
        XCTAssertEqual(leftY.label, initial)
        leftY.tap()
        rightB.tap()
        leftB.tap()
        rightY.tap()
        XCTAssertEqual(draft.value as? String, initial + "bby")

        app.buttons["key-123"].tap()
        XCTAssertFalse(leftY.exists)
        XCTAssertFalse(leftB.exists)
        app.buttons["key-ABC"].tap()
        layout.tap()
        XCTAssertFalse(leftY.exists)
        XCTAssertFalse(leftB.exists)
        rightY.tap()
        rightB.tap()
        XCTAssertEqual(draft.value as? String, initial + "bbyyb")
        layout.tap()
        XCTAssertTrue(leftY.exists && leftB.exists)
    }

    func testSplitLayoutOnWideKeyboard() throws {
        let originalOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        defer {
            if originalOrientation != .unknown { XCUIDevice.shared.orientation = originalOrientation }
        }
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["keyboard-settings"]
        settings.tap()
        let split = app.switches["split-wide-screens"]
        func enableSplit() {
            if split.value as? String != "1" {
                split.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            }
            XCTAssertEqual(split.value as? String, "1")
        }
        enableSplit()
        enableForTest("return-after-symbol", inSettingsOf: app)
        enableForTest("glide-typing", inSettingsOf: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        let draft = app.textViews["draft"]
        draft.tap()
        selectMonkeyBoard(in: app)
        let toggle = app.buttons["toggle-split-layout"]
        guard toggle.exists else {
            XCTAssertTrue(app.buttons["key-Space"].exists)
            throw XCTSkip("Open the Duo to exercise both banks at full width.")
        }
        XCTAssertEqual(toggle.label, "Join keyboard")
        let leftSpace = app.buttons["key-Space-left"]
        let rightSpace = app.buttons["key-Space-right"]
        func letter(_ lower: String) -> XCUIElement {
            self.letter(lower, in: app)
        }
        let t = letter("t")
        let y = letter("y")
        XCTAssertFalse(app.buttons["key-,"].exists)
        let leftNeighbor = try XCTUnwrap(["Emoji", "Next keyboard", "123"]
            .map { app.buttons["key-" + $0] }.first { $0.exists })
        XCTAssertEqual(leftSpace.frame.minX, leftNeighbor.frame.maxX + 4, accuracy: 1)
        XCTAssertGreaterThan(y.frame.minX - t.frame.maxX, 50)
        XCTAssertGreaterThan(rightSpace.frame.minX - leftSpace.frame.maxX, 50)
        t.press(forDuration: 0.12, thenDragTo: letter("o"))
        XCTAssertEqual((draft.value as? String)?.lowercased(), "to")
        app.buttons["key-Delete"].tap()
        let firstLetter = letter("f").label
        letter("f").tap()
        leftNeighbor.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: 12, dy: 0)).tap()
        letter("j").tap()
        rightSpace.tap()
        app.buttons["key-123"].tap()
        app.buttons["key-1"].tap()
        app.buttons["key-123"].tap()
        app.buttons["key-0"].tap()
        app.buttons["key-123"].tap()
        app.buttons["key-#+="].tap()
        app.buttons["key-["].tap()
        app.buttons["key-123"].tap()
        app.buttons["key-#+="].tap()
        app.buttons["key-="].tap()
        XCTAssertEqual(draft.value as? String, firstLetter + " j 10[=")

        let gutter = leftSpace.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: (rightSpace.frame.minX - leftSpace.frame.maxX) / 2, dy: 0))
        let v = letter("v").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        v.press(forDuration: 0.15, thenDragTo: gutter)
        XCTAssertEqual(draft.value as? String, firstLetter + " j 10[=")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Split keyboard"
        capture.lifetime = .keepAlways
        add(capture)

        app.buttons["key-123"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "key-,").count, 1)
        app.buttons["key-,"].tap()
        app.buttons["key-."].tap()
        XCTAssertEqual(draft.value as? String, firstLetter + " j 10[=,.")
        toggle.tap()
        let singleSpace = app.buttons["key-Space"]
        XCTAssertTrue(singleSpace.exists)
        XCTAssertFalse(leftSpace.exists)
        XCTAssertFalse(rightSpace.exists)
        app.buttons["key-,"].tap()
        singleSpace.tap()
        app.buttons["key-."].tap()
        XCTAssertEqual(draft.value as? String, firstLetter + " j 10[=,., .")
        app.buttons["hide-keyboard"].tap()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 3))
        settings.tap()
        XCTAssertEqual(split.value as? String, "0")
        enableSplit()
        let back = app.buttons["BackButton"]
        if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
        draft.tap()
        XCTAssertTrue(rightSpace.waitForExistence(timeout: 3))
        let hide = app.buttons["hide-keyboard"]
        let layer = app.buttons["key-123"]
        XCTAssertEqual(hide.frame.minX, layer.frame.minX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(hide.frame.minY, layer.frame.maxY - 1)
        hide.tap()
        XCTAssertTrue(rightSpace.waitForNonExistence(timeout: 3))
    }
}
