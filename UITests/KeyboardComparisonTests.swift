import XCTest

/// Capture the same actual key taps in the same host with either keyboard selected.
/// Run on a fresh English simulator per keyboard. Outputs are measurements, including misses.
final class KeyboardComparisonTests: XCTestCase {
    func testIOSStylePickerAndTyping() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        var originalStyle: String?
        var originalReturn: String?
        func choose(_ name: String) {
            app.launch()
            app.buttons["keyboard-settings"].tap()
            let returnToggle = app.switches["return-after-space"]
            if originalReturn == nil {
                originalReturn = returnToggle.value as? String
                if originalReturn == "0" { returnToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
                XCTAssertEqual(returnToggle.value as? String, "1")
            }
            app.buttons["appearance-settings"].tap()
            if originalStyle == nil {
                originalStyle = app.segmentedControls["keyboard-style-picker"].buttons["iOS"].isSelected ? "iOS" : "Default"
            }
            let segment = app.segmentedControls["keyboard-style-picker"].buttons[name]
            XCTAssertTrue(segment.waitForExistence(timeout: 5))
            segment.tap()
            XCTAssertTrue(segment.isSelected)
        }
        func showKeyboard() {
            app.launch()
            app.textViews["draft"].tap()
            app.switchToKeyboard(showing: app.buttons["keyboard-options"])
        }
        func key(_ label: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier ==[c] %@", "key-" + label)).firstMatch
        }
        addTeardownBlock {
            guard let originalStyle else { return }
            app.launch()
            app.buttons["keyboard-settings"].tap()
            let toggle = app.switches["return-after-space"]
            if let originalReturn, toggle.value as? String != originalReturn { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
            app.buttons["appearance-settings"].tap()
            app.segmentedControls["keyboard-style-picker"].buttons[originalStyle].tap()
        }
        choose("Default")
        showKeyboard()
        XCTAssertTrue(key(".").exists)
        choose("iOS")
        showKeyboard()
        XCTAssertFalse(key(".").exists)
        XCTAssertFalse(app.buttons["hide-keyboard"].exists)
        if app.frame.width >= 560 && key("Space").exists {
            app.buttons["keyboard-options"].tap()
            app.buttons["Split Keyboard"].tap()
        }
        let space = key("Space-left").exists ? key("Space-left") : key("Space")
        XCTAssertTrue(space.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
        print("IOS_STYLE_READY") // Also allows simctl to capture Duo's secondary display.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "ios-style-keyboard"
        shot.lifetime = .keepAlways
        add(shot)
        key("q").tap()
        space.tap()
        XCTAssertEqual(app.textViews["draft"].value as? String, "Q ")
        key("Delete").tap()
        XCTAssertEqual(app.textViews["draft"].value as? String, "Q")
        key("123").tap()
        XCTAssertTrue(key(",").waitForExistence(timeout: 4), app.debugDescription)
        key("1").tap()
        XCTAssertTrue(key("2").exists, "Typing a number must keep the numbers page open")
        key("2").tap()
        key("Delete").tap()
        key("3").tap()
        key(".").tap()
        key("4").tap()
        key("#+=").tap()
        key("[").tap()
        key("]").tap()
        XCTAssertTrue(key("ABC").exists)
        XCTAssertEqual(app.textViews["draft"].value as? String, "Q13.4[]")
        space.tap()
        XCTAssertTrue(key("q").exists)
        XCTAssertEqual(app.textViews["draft"].value as? String, "Q13.4[] ")
        key("Return").tap()
        XCTAssertEqual(app.textViews["draft"].value as? String, "Q13.4[] \n")
        app.buttons["keyboard-options"].tap()
        if app.buttons["Join Keyboard"].exists {
            app.buttons["Join Keyboard"].tap()
            XCTAssertTrue(key("Space").wait(for: \.isHittable, toEqual: true, timeout: 5))
            app.buttons["keyboard-options"].tap()
            XCTAssertTrue(app.buttons["Split Keyboard"].exists)
            app.buttons["Split Keyboard"].tap()
            XCTAssertTrue(key("Space-left").wait(for: \.isHittable, toEqual: true, timeout: 5))
            app.buttons["keyboard-options"].tap()
            XCTAssertTrue(app.buttons["Join Keyboard"].exists)
        }
        app.buttons["Hide Keyboard"].tap()
        XCTAssertTrue(app.buttons["keyboard-options"].wait(for: \.isHittable, toEqual: false, timeout: 5))
        app.buttons["keyboard-settings"].tap()
        app.buttons["appearance-settings"].tap()
        XCTAssertTrue(app.segmentedControls["keyboard-style-picker"].buttons["iOS"].isSelected)
    }

    func testThumbReachMovesSplitKeysAndPersists() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        var originalReach: CGFloat?
        var originalStyle: String?
        var originalSplit: String?
        func settings() {
            app.launch()
            app.buttons["keyboard-settings"].tap()
        }
        func setReach(_ amount: CGFloat) {
            settings()
            let slider = app.sliders["thumb-reach"]
            XCTAssertTrue(slider.waitForExistence(timeout: 3), "Thumb reach belongs under Layout")
            slider.adjust(toNormalizedSliderPosition: amount)
        }
        func key(_ label: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier ==[c] %@", "key-" + label)).firstMatch
        }
        func showKeyboard() {
            app.launch()
            app.textViews["draft"].tap()
            app.switchToKeyboard(showing: app.buttons["keyboard-options"])
            XCTAssertTrue(key("Space-left").exists, "Open the Duo simulator for this test")
        }
        addTeardownBlock {
            if let originalReach {
                setReach(originalReach)
                if let originalSplit {
                    let split = app.switches["split-wide-screens"]
                    if split.value as? String != originalSplit {
                        split.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
                    }
                }
                if let originalStyle {
                    app.buttons["appearance-settings"].tap()
                    app.segmentedControls["keyboard-style-picker"].buttons[originalStyle].tap()
                }
            }
        }
        settings()
        let slider = app.sliders["thumb-reach"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3), "Thumb reach belongs under Layout")
        originalReach = slider.normalizedSliderPosition
        let split = app.switches["split-wide-screens"]
        originalSplit = split.value as? String
        if originalSplit == "0" { split.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        app.buttons["appearance-settings"].tap()
        let styles = app.segmentedControls["keyboard-style-picker"]
        originalStyle = styles.buttons["iOS"].isSelected ? "iOS" : "Default"
        styles.buttons["iOS"].tap()
        // Duo inner-display rotation is controlled in Device Hub; XCUIDevice
        // orientation can target only its folded display. Exercise the current layout.
        setReach(0)
        showKeyboard()
        let q = key("q").frame, p = key("p").frame, g = key("g").frame
        setReach(1)
        settings()
        XCTAssertEqual(slider.normalizedSliderPosition, 1, accuracy: 0.02, "Reach should survive relaunch")
        showKeyboard()
        print("THUMB_REACH host=\(app.frame) qOriginal=\(q) qReached=\(key("q").frame)")
        XCTAssertLessThan(key("q").frame.minX, q.minX - 3)
        XCTAssertGreaterThan(key("p").frame.maxX, p.maxX + 3)
        XCTAssertLessThan(key("g").frame.midX, g.midX - 15)
        XCTAssertEqual(key("q").frame.height, q.height, accuracy: 1)
        key("g").tap()
        key("v").tap()
        key("Space-left").tap()
        key("p").tap()
        key("Space-right").tap()
        XCTAssertEqual((app.textViews["draft"].value as? String)?.lowercased(), "gv p ")
        let reachedQ = key("q").frame
        app.buttons["keyboard-options"].tap()
        app.buttons["Join Keyboard"].tap()
        XCTAssertTrue(key("Space").wait(for: \.isHittable, toEqual: true, timeout: 5))
        app.buttons["keyboard-options"].tap()
        app.buttons["Split Keyboard"].tap()
        XCTAssertTrue(key("Space-left").wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertEqual(key("q").frame.minX, reachedQ.minX, accuracy: 1, "Joining and splitting must restore reach")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "thumb-reach"
        shot.lifetime = .keepAlways
        add(shot)
    }

    #if MONKEYBOARD_REACH_PREVIEW
    /// Explicit simulator demo setup; excluded from normal regression runs.
    func testPrepareThumbReachPreview() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["keyboard-settings"].tap()
        let slider = app.sliders["thumb-reach"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.75)
        XCTAssertEqual(slider.normalizedSliderPosition, 0.75, accuracy: 0.02)
        let split = app.switches["split-wide-screens"]
        if split.value as? String == "0" { split.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        app.buttons["appearance-settings"].tap()
        app.segmentedControls["keyboard-style-picker"].buttons["iOS"].tap()
        app.launch()
        app.textViews["draft"].tap()
        app.switchToKeyboard(showing: app.buttons["keyboard-options"])
        XCTAssertTrue(app.buttons["key-Space-left"].exists)
    }
    #endif

    func testCaptureAppleAppearanceReference() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.textViews["draft"].tap()
        let q = app.keyboards.keys.matching(NSPredicate(format: "label ==[c] 'q'")).firstMatch
        app.switchToKeyboard(showing: q)
        app.dismissAppleSlideToTypeIntroduction()
        XCTAssertTrue(q.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "apple-appearance-reference"
        shot.lifetime = .keepAlways
        add(shot)
        let frames = app.keyboards.keys.allElementsBoundByIndex.map {
            ["label": $0.label, "frame": NSCoder.string(for: $0.frame)]
        }
        let data = try JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted])
        let metrics = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        metrics.name = "apple-key-frames"
        metrics.lifetime = .keepAlways
        add(metrics)
    }

    func testCaptureSafariSpaceBoundary() throws {
        continueAfterFailure = false
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <input aria-label="Search terms" type="search" inputmode="search"
               autocapitalize="off" autocorrect="off" style="font-size:20px;width:95%">
        """
        let url = try XCTUnwrap(URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString()))
        safari.open(url)
        let field = safari.descendants(matching: .any).matching(NSPredicate(
            format: "label == 'Search terms' AND (elementType == %d OR elementType == %d)",
            XCUIElement.ElementType.searchField.rawValue, XCUIElement.ElementType.textField.rawValue)).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        let monkey = safari.buttons["keyboard-options"].waitForExistence(timeout: 5)
        let keys = monkey ? safari.buttons : safari.keyboards.keys
        func key(_ literal: String) -> XCUIElement {
            if monkey {
                if literal == "space" {
                    let right = keys["key-Space-right"]
                    return right.exists ? right : keys["key-Space"]
                }
                return keys.matching(NSPredicate(format: "identifier ==[c] %@", "key-" + literal)).firstMatch
            }
            return keys.matching(NSPredicate(format: "label ==[c] %@", literal)).firstMatch
        }
        let space = key("space"), dot = key(".")
        XCTAssertTrue(space.exists && dot.exists, "Missing a comparison key. \(safari.keyboards.debugDescription)")
        let a = space.frame, b = dot.frame
        XCTAssertGreaterThan(b.midX, a.midX)
        let edge = (a.maxX + b.minX) / 2
        let y = (max(a.minY, b.minY) + min(a.maxY, b.maxY)) / 2
        let origin = safari.coordinate(withNormalizedOffset: .zero)
        let probes = [("center of Space", a.midX, " "), ("one point toward Space", edge - 1, " "),
                      ("one point toward period", edge + 1, "."), ("center of period", b.midX, ".")]
        var records: [[String: String]] = []
        for (label, x, intended) in probes {
            key("b").tap() // Separate the probes so double-space punctuation cannot fire.
            let before = try XCTUnwrap(field.value as? String)
            origin.withOffset(CGVector(dx: x, dy: y)).tap()
            let after = try XCTUnwrap(field.value as? String)
            XCTAssertTrue(after.hasPrefix(before))
            records.append(["keyboard": monkey ? "MonkeyBoard" : "Apple", "probe": label,
                            "intended": intended, "actual": String(after.dropFirst(before.count))])
        }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "safari-space-boundary.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureEverydayMessages() throws {
        let examples = [
            ("I packed teh mugs", "I packed the mugs"),
            ("We got a lift home", "We got a lift home"),
            ("Please check the frotn door", "Please check the front door"),
            ("Nori packed the mugs", "Nori packed the mugs"),
            ("The plumber fixed the leek", "The plumber fixed the leak"),
            ("I made leek soup", "I made leek soup"),
            ("Leave the box by the dor", "Leave the box by the door"),
            ("Send me the link rn", "Send me the link rn")
        ]
        try capture(examples, name: "everyday-messages")
    }

    func testCaptureShortWordsAndContext() throws {
        try capture([
            ("Someone rang the dor", "Someone rang the door"),
            ("Please lock the back dor", "Please lock the back door"),
            ("We can hear the roof leek", "We can hear the roof leak"),
            ("They repaired the gas leek", "They repaired the gas leak"),
            ("Can you shut the dor gently", "Can you shut the door gently"),
            ("I left my bok on the desk", "I left my book on the desk"),
            ("She dropped a leek", "She dropped a leek"),
            ("The plumber sliced a leek", "The plumber sliced a leek"),
            ("The recipe calls for leek", "The recipe calls for leek"),
            ("I ordered bok choy", "I ordered bok choy"),
            ("Send the doc rn", "Send the doc rn"),
            ("Bring the dog to the door", "Bring the dog to the door")
        ], name: "short-words-and-context")
    }

    func testCaptureEverydayConfirmation() throws {
        try capture([
            ("A package is at the side dor", "A package is at the side door"),
            ("Could you knock on the dor", "Could you knock on the door"),
            ("Turn to page ten in the bok", "Turn to page ten in the book"),
            ("The mechanic stopped the oil leek", "The mechanic stopped the oil leak"),
            ("A roofer sealed the leek", "A roofer sealed the leak"),
            ("I left the ligths on", "I left the lights on"),
            ("Dor is on my team", "Dor is on my team"),
            ("Roast the leek until soft", "Roast the leek until soft"),
            ("The repair crew shared leek soup", "The repair crew shared leek soup"),
            ("The noodles came with bok choy", "The noodles came with bok choy"),
            ("Can you grab my mug", "Can you grab my mug"),
            ("Text me when ur free", "Text me when ur free")
        ], name: "everyday-confirmation")
    }

    private func capture(_ examples: [(String, String)], name attachmentName: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        var results: [[String: String]] = []
        for (typed, intended) in examples {
            app.launch()
            let draft = app.textViews["draft"]
            draft.tap()
            let monkey = app.buttons["keyboard-options"].waitForExistence(timeout: 5)
            let name = monkey ? "MonkeyBoard" : "Apple"
            if let previous = results.first { XCTAssertEqual(name, previous["keyboard"]) }
            let keys = monkey ? app.buttons : app.keyboards.keys
            for character in typed + " " {
                let value = String(character)
                let key: XCUIElement
                if monkey && character == " " {
                    let left = keys["key-Space-left"]
                    key = left.exists ? left : keys["key-Space"]
                } else {
                    let label = character == " " ? "space" : value
                    let attribute = monkey ? "identifier" : "label"
                    key = keys.matching(NSPredicate(format: "%K ==[c] %@", attribute,
                                                    monkey ? "key-" + label : label)).firstMatch
                }
                XCTAssertTrue(key.exists, "Missing \(name) key for \(value). \(app.keyboards.debugDescription)")
                key.tap()
            }
            // Both keyboards get the same settling interval for asynchronous corrections.
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let actual = try XCTUnwrap(draft.value as? String)
            results.append(["keyboard": name, "typed": typed + " ", "intended": intended + " ", "actual": actual])
            app.terminate()
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = attachmentName + ".json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
