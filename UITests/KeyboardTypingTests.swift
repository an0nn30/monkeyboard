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
                                      timeout: 8), .completed)
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

    private func typePhrase(_ text: String, in app: XCUIApplication) {
        let splitSpace = app.buttons["key-Space-left"]
        let space = splitSpace.exists ? splitSpace : app.buttons["key-Space"]
        for ch in text {
            if ch == " " { space.tap() } else { letter(String(ch), in: app).tap() }
        }
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
        app.buttons["key-,"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "teh keyboard,")
        app.buttons["key-Delete"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "teh keybaord")
        space.tap()
        typeWord("teh")
        app.buttons["suggestion-0"].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "teh keybaord teh ")
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
        app.buttons["key-,"].tap()
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
        app.buttons["key-,"].tap()
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
        q.press(forDuration: 0.15, thenDragTo: p)
        XCTAssertEqual((draft.value as? String)?.lowercased(), "p")
        capture("Left-handed cover keyboard")

        choose("Right Hand")
        checkHidePosition()
        XCTAssertEqual(p.frame.maxX, right, accuracy: 2)
        XCTAssertGreaterThan(q.frame.minX, left + 40)
        XCTAssertGreaterThanOrEqual(menu.frame.minX, q.frame.minX - 3)
        let edge = q.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        edge.press(forDuration: 0.15, thenDragTo: edge.withOffset(CGVector(dx: -35, dy: 0)))
        XCTAssertEqual((draft.value as? String)?.lowercased(), "p")
        capture("Right-handed cover keyboard")
        app.buttons["key-123"].tap()
        app.buttons["key-0"].tap()
        app.buttons["key-123"].tap()
        app.buttons["key-#+="].tap()
        app.buttons["key-="].tap()
        XCTAssertEqual((draft.value as? String)?.lowercased(), "p0=")
        app.buttons["hide-keyboard"].tap()
        draft.tap()
        XCTAssertTrue(p.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(q.frame.minX, left + 40)
        app.buttons["expand-keyboard"].tap()
        XCTAssertEqual(q.frame.minX, left, accuracy: 2)
        XCTAssertEqual(p.frame.maxX, right, accuracy: 2)
    }

    func testSplitLayoutOnWideKeyboard() throws {
        let originalOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .landscapeLeft
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
        let back = app.buttons["BackButton"]
        if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
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
        XCTAssertGreaterThan(y.frame.minX - t.frame.maxX, 50)
        XCTAssertGreaterThan(rightSpace.frame.minX - leftSpace.frame.maxX, 50)
        let firstLetter = letter("f").label
        letter("f").tap()
        leftSpace.tap()
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
