import XCTest

extension XCUIApplication {
    func dismissAppleSlideToTypeIntroduction() {
        let sheet = otherElements["UIContinuousPathIntroductionView"]
        let button = sheet.buttons["Continue"]
        if button.exists && button.isHittable { button.tap() }
    }

    /// The installed order can put Apple's emoji picker between letter keyboards.
    func switchToKeyboard(showing target: XCUIElement) {
        for _ in 0..<4 {
            if target.exists || target.waitForExistence(timeout: 3) { return }
            let letters = buttons["letters"]
            let globe = buttons["key-Next keyboard"]
            let switcher = letters.exists ? letters : (globe.exists ? globe : buttons["Next keyboard"].firstMatch)
            XCTAssertTrue(switcher.isHittable, "Missing keyboard switcher")
            switcher.tap()
        }
        XCTAssertTrue(target.waitForExistence(timeout: 4), "Requested keyboard unavailable")
    }
}

/// Tap the installed keyboards in real host fields. Only intentional globe
/// transitions may reselect MonkeyBoard; elsewhere a fallback is a failed test.
final class KeyboardStabilityTests: XCTestCase {
    private let host = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let originalOrientation = XCUIDevice.shared.orientation
        if originalOrientation != .portrait { XCUIDevice.shared.orientation = .portrait }
        addTeardownBlock {
            if originalOrientation != .unknown && XCUIDevice.shared.orientation != originalOrientation {
                XCUIDevice.shared.orientation = originalOrientation
            }
        }
    }

    private func key(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier ==[c] %@", "key-" + value)).firstMatch
    }

    private func appleKey(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.keyboards.keys.matching(NSPredicate(format: "label ==[c] %@", value)).firstMatch
    }

    private func requireLetters(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.buttons["keyboard-options"].waitForExistence(timeout: 5), "MonkeyBoard disappeared", file: file, line: line)
        XCTAssertTrue(key("k", in: app).wait(for: \.isHittable, toEqual: true, timeout: 4), app.debugDescription, file: file, line: line)
    }

    private func chooseLetters(in app: XCUIApplication, apple: Bool) {
        let target = apple ? appleKey("q", in: app) : app.buttons["keyboard-options"]
        app.switchToKeyboard(showing: target)
        if apple {
            app.dismissAppleSlideToTypeIntroduction()
            XCTAssertFalse(app.buttons["keyboard-options"].exists)
        }
        else { requireLetters(in: app) }
    }

    private func draft() -> XCUIElement {
        host.launch()
        let field = host.textViews["draft"]
        field.tap()
        chooseLetters(in: host, apple: false)
        return field
    }

    private func expect(_ field: XCUIElement, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(field.value as? String ?? "", text, file: file, line: line)
    }

    private func appendKey(_ button: XCUIElement, to expected: inout String) {
        XCTAssertTrue(button.isHittable)
        expected += button.label
        button.tap()
    }

    private func focusAtEnd(_ field: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed, "Field never became hittable after foregrounding")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    private func openBrowser(_ fields: String) throws -> XCUIApplication {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0;padding-top:60px}input{display:block;font-size:18px;margin:6px;width:85%}</style>
        <form autocomplete="off" onsubmit="return false">\(fields)</form>
        """
        let url = try XCTUnwrap(URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString()))
        safari.open(url)
        return safari
    }

    func testAppleAndMonkeyBoardRoundTripsKeepDraft() {
        let field = draft()
        var expected = ""
        for round in 1...6 {
            XCTContext.runActivity(named: "Keyboard round trip \(round)") { _ in
                requireLetters(in: host)
                appendKey(key("m", in: host), to: &expected)
                chooseLetters(in: host, apple: true)
                appendKey(appleKey("a", in: host), to: &expected)
                expect(field, expected)
                chooseLetters(in: host, apple: false)
                appendKey(key("k", in: host), to: &expected)
                expect(field, expected)
            }
        }
    }

    func testEmojiSearchBrowseDeleteAndReturnRepeatedly() {
        let field = draft()
        var expected = ""
        for round in 1...6 {
            XCTContext.runActivity(named: "Emoji round trip \(round)") { _ in
                key("Emoji", in: host).tap()
                host.buttons["emoji-search"].tap()
                for c in "cat" { key(String(c), in: host).tap() }
                XCTAssertEqual(host.buttons["emoji-search"].value as? String, "cat")
                expect(field, expected)
                host.buttons["emoji-done"].tap()
                host.buttons["emoji-category-food"].tap()
                host.cells["emoji-🍇"].tap()
                expect(field, expected + "🍇")
                if round.isMultiple(of: 2) { host.buttons["emoji-delete"].tap() }
                else { expected += "🍇" }
                host.buttons["emoji-abc"].tap()
                requireLetters(in: host)
                appendKey(key("x", in: host), to: &expected)
                expect(field, expected)
            }
        }
    }

    func testSystemEmojiPickerReturnsToMonkeyBoard() {
        let field = draft()
        var expected = ""
        for round in 1...3 {
            XCTContext.runActivity(named: "System emoji round trip \(round)") { _ in
                let own = key("Next keyboard", in: host)
                let globe = own.exists ? own : host.buttons["Next keyboard"].firstMatch
                globe.press(forDuration: 0.8)
                let item = host.descendants(matching: .any).matching(NSPredicate(
                    format: "label ==[c] 'Emoji' AND NOT identifier BEGINSWITH 'key-'")).firstMatch
                XCTAssertTrue(item.waitForExistence(timeout: 3), host.debugDescription)
                item.tap()
                let letters = host.buttons["letters"]
                XCTAssertTrue(letters.waitForExistence(timeout: 4), host.debugDescription)
                XCTAssertFalse(host.buttons["emoji-abc"].exists)
                expect(field, expected)
                letters.tap()
                chooseLetters(in: host, apple: false)
                appendKey(key("j", in: host), to: &expected)
                expect(field, expected)
            }
        }
    }

    func testContinuousTypingWhilePredictionsRun() throws {
        let field = draft()
        var expected = ""
        #if MONKEYBOARD_SOUND_BENCHMARK
        let process = try probe(in: host).pid
        #endif
        let phrase = "we can meet at noon "
        var targets: [Character: XCUICoordinate] = [:]
        for c in Set(phrase) {
            let left = key("Space-left", in: host)
            let button = c == " " ? (left.exists ? left : key("Space", in: host)) : key(String(c), in: host)
            XCTAssertTrue(button.isHittable)
            targets[c] = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        }
        for round in 1...8 {
            try XCTContext.runActivity(named: "Typing passage \(round)") { _ in
                for c in phrase { try XCTUnwrap(targets[c]).tap() }
                expected += phrase
                requireLetters(in: host)
                XCTAssertEqual((field.value as? String)?.lowercased(), expected)
                #if MONKEYBOARD_SOUND_BENCHMARK
                XCTAssertEqual(try probe(in: host).pid, process, "Extension restarted in a continuous editing session")
                #endif
            }
        }
    }

    #if MONKEYBOARD_SOUND_BENCHMARK
    private func probe(in app: XCUIApplication) throws -> (mode: String, fullAccess: Bool, pid: Int, taps: Int, submissions: Int) {
        let element = app.descendants(matching: .any)["sound-footprint-probe"].firstMatch
        let raw = try XCTUnwrap(element.value as? String)
        let values = raw.components(separatedBy: "|")
        let counters = try XCTUnwrap(values.count == 8 ? values : nil, "Invalid process and playback counters")
        return (counters[0], counters[1] == "true", try XCTUnwrap(Int(counters[2])),
                try XCTUnwrap(Int(counters[3])), try XCTUnwrap(Int(counters[4])))
    }
    #endif

    func testSplitAndJoinedLayoutsKeepDraftThroughModeChanges() {
        host.launch()
        if host.frame.width < 560 { XCUIDevice.shared.orientation = .landscapeLeft }
        let field = host.textViews["draft"]
        field.tap()
        chooseLetters(in: host, apple: false)
        let toggle = host.buttons["toggle-split-layout"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 4), "Run the wide-layout test on the open Duo or a wide landscape keyboard")
        let initiallySplit = key("Space-left", in: host).exists
        defer {
            if toggle.exists && key("Space-left", in: host).exists != initiallySplit { toggle.tap() }
        }
        var expected = ""
        for step in 1...10 {
            XCTContext.runActivity(named: "Layout switch \(step)") { _ in
                let wasSplit = key("Space-left", in: host).exists
                toggle.tap()
                let nextSpace = key(wasSplit ? "Space" : "Space-right", in: host)
                XCTAssertTrue(nextSpace.waitForExistence(timeout: 3))
                XCTAssertFalse(key(wasSplit ? "Space-left" : "Space", in: host).exists)
                appendKey(key("m", in: host), to: &expected)
                nextSpace.tap()
                expected += " "
                expect(field, expected)
                key("Emoji", in: host).tap()
                host.buttons["emoji-abc"].tap()
                requireLetters(in: host)
                XCTAssertTrue(nextSpace.isHittable)
            }
        }
    }

    func testChangingEachSoundKeepsTypingInLiveDraft() throws {
        let field = draft()
        func openPicker() -> XCUIElement {
            host.buttons["keyboard-settings"].tap()
            let picker = host.buttons["typing-sound"]
            for _ in 0..<8 {
                if picker.exists && picker.isHittable { break }
                host.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(picker.exists && picker.isHittable, "Typing sound picker is unavailable")
            return picker
        }
        func select(_ name: String, in picker: XCUIElement) {
            picker.tap()
            host.buttons[name].firstMatch.tap()
            XCTAssertEqual(picker.value as? String, name)
        }
        host.buttons["hide-keyboard"].tap()
        var picker = openPicker()
        let original = try XCTUnwrap(picker.value as? String)
        addTeardownBlock {
            self.host.launch()
            select(original, in: openPicker())
        }
        var expected = ""
        for name in ["Soft Tap", "System Click", "Mechanical", "Hollow Tap", "Soft Knock", "Crisp Tick", "iOS-Style Click", "Off"] {
            try XCTContext.runActivity(named: "Type after choosing \(name)") { _ in
                select(name, in: picker)
                let back = host.buttons["BackButton"]
                if back.isHittable { back.tap() } else {
                    host.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.48))
                        .press(forDuration: 0.06, thenDragTo: host.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.48)))
                }
                XCTAssertTrue(field.waitForExistence(timeout: 4))
                field.tap()
                requireLetters(in: host)
                expect(field, expected)
                #if MONKEYBOARD_SOUND_BENCHMARK
                let before = try probe(in: host)
                XCTAssertEqual(before.mode, name, "Live extension did not load the selected sound")
                #endif
                appendKey(key("k", in: host), to: &expected)
                key("Delete", in: host).tap()
                expected.removeLast()
                appendKey(key("p", in: host), to: &expected)
                expect(field, expected)
                #if MONKEYBOARD_SOUND_BENCHMARK
                let after = try probe(in: host)
                XCTAssertEqual(after.pid, before.pid)
                XCTAssertEqual(after.taps - before.taps, 3)
                let submissions = after.submissions - before.submissions
                XCTAssertEqual(submissions, name != "Off" && before.fullAccess ? 3 : 0)
                print("Sound \(name), full access \(before.fullAccess), submissions \(submissions)")
                #endif
                host.buttons["hide-keyboard"].tap()
                XCTAssertTrue(key("p", in: host).waitForNonExistence(timeout: 4))
                picker = openPicker()
            }
        }
    }

    private func openInputTraitsForm() throws -> XCUIApplication {
        try openBrowser("""
        <input aria-label="Message" autocapitalize="off" autocorrect="off">
        <input aria-label="Quantity" inputmode="numeric">
        <input aria-label="Secret" type="password">
        """)
    }

    func testSafariFieldChangesDuringEmojiSearchAndSecureInput() throws {
        _ = draft()
        let safari = try openInputTraitsForm()
        let message = safari.textFields["Message"], quantity = safari.textFields["Quantity"]
        let password = safari.secureTextFields["Secret"]
        XCTAssertTrue(message.waitForExistence(timeout: 8))
        var expectedText = "", expectedDigits = ""
        for step in 1...4 {
            XCTContext.runActivity(named: "Web input traits \(step)") { _ in
                focusAtEnd(message, in: safari)
                requireLetters(in: safari)
                appendKey(key("z", in: safari), to: &expectedText)
                key("Emoji", in: safari).tap()
                safari.buttons["emoji-search"].tap()
                key("b", in: safari).tap()
                quantity.tap()
                XCTAssertTrue(key("1", in: safari).waitForExistence(timeout: 3))
                XCTAssertFalse(safari.buttons["emoji-search"].exists)
                key("1", in: safari).tap()
                expectedDigits += "1"
                expect(quantity, expectedDigits)
                password.tap()
                XCTAssertTrue(appleKey("q", in: safari).waitForExistence(timeout: 4), "iOS should use its secure keyboard")
                XCTAssertFalse(safari.buttons["keyboard-options"].exists)
                safari.dismissAppleSlideToTypeIntroduction()
                appleKey("a", in: safari).tap()
                XCTAssertEqual((password.value as? String)?.count, step)
                focusAtEnd(message, in: safari)
                requireLetters(in: safari)
                expect(message, expectedText)
                expect(quantity, expectedDigits)
            }
        }
    }

    func testSafariSystemKeyboardControlAcrossSecureFields() throws {
        // The Apple control starts with its own Safari process even after a timed-out mixed run.
        XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").terminate()
        _ = draft()
        let safari = try openInputTraitsForm()
        let message = safari.textFields["Message"], quantity = safari.textFields["Quantity"]
        let password = safari.secureTextFields["Secret"]
        XCTAssertTrue(message.waitForExistence(timeout: 8))
        message.tap()
        chooseLetters(in: safari, apple: true)
        addTeardownBlock { _ = self.draft() }
        var expectedText = "", expectedDigits = ""
        for step in 1...4 {
            XCTContext.runActivity(named: "Apple web input traits \(step)") { _ in
                safari.dismissAppleSlideToTypeIntroduction()
                let letter = appleKey("z", in: safari)
                XCTAssertTrue(letter.wait(for: \.isHittable, toEqual: true, timeout: 4), safari.debugDescription)
                XCTAssertFalse(safari.buttons["keyboard-options"].exists)
                appendKey(letter, to: &expectedText)
                quantity.tap()
                let digit = appleKey("1", in: safari)
                XCTAssertTrue(digit.waitForExistence(timeout: 4))
                appendKey(digit, to: &expectedDigits)
                expect(quantity, expectedDigits)
                password.tap()
                XCTAssertTrue(appleKey("a", in: safari).waitForExistence(timeout: 4))
                safari.dismissAppleSlideToTypeIntroduction()
                appleKey("a", in: safari).tap()
                XCTAssertEqual((password.value as? String)?.count, step)
                focusAtEnd(message, in: safari)
                XCTAssertFalse(safari.buttons["keyboard-options"].exists)
                expect(message, expectedText)
                expect(quantity, expectedDigits)
            }
        }
    }

    func testEmojiSearchCannotConsumeInputAfterSwitchingTextFields() throws {
        _ = draft()
        let safari = try openBrowser("""
        <input aria-label="First draft" autocapitalize="off" autocorrect="off">
        <input aria-label="Second draft" autocapitalize="off" autocorrect="off">
        """)
        let fields = [safari.textFields["First draft"], safari.textFields["Second draft"]]
        XCTAssertTrue(fields[0].waitForExistence(timeout: 8))
        fields[0].tap()
        var texts = ["", ""]
        for round in 0..<6 {
            XCTContext.runActivity(named: "Switch text fields during search \(round + 1)") { _ in
                let source = round % 2, target = 1 - source
                requireLetters(in: safari)
                key("Emoji", in: safari).tap()
                safari.buttons["emoji-search"].tap()
                key("b", in: safari).tap()
                expect(fields[source], texts[source])
                focusAtEnd(fields[target], in: safari)
                requireLetters(in: safari)
                XCTAssertFalse(safari.buttons["emoji-search"].exists)
                appendKey(key("j", in: safari), to: &texts[target])
                expect(fields[target], texts[target])
                expect(fields[source], texts[source])
            }
        }
    }

    func testBackgroundAndSwitchAppsWithIndependentDrafts() throws {
        let field = draft()
        let safari = try openBrowser("<input aria-label='Other draft' autocorrect='off' autocapitalize='off'>")
        let other = safari.textFields["Other draft"]
        XCTAssertTrue(other.waitForExistence(timeout: 8))
        other.tap()
        var appText = "", webText = ""
        for round in 1...5 {
            XCTContext.runActivity(named: "Host round trip \(round)") { _ in
                safari.activate()
                if !safari.keyboards.firstMatch.waitForExistence(timeout: 2) { focusAtEnd(other, in: safari) }
                requireLetters(in: safari)
                appendKey(key("s", in: safari), to: &webText)
                expect(other, webText)
                XCUIDevice.shared.press(.home)
                host.activate()
                if !host.keyboards.firstMatch.waitForExistence(timeout: 2) { focusAtEnd(field, in: host) }
                requireLetters(in: host)
                appendKey(key("m", in: host), to: &appText)
                expect(field, appText)
            }
        }
    }

    func testMessagesUnsentDraftSurvivesEmojiAndSystemKeyboardSwitches() throws {
        _ = draft()
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.open(try XCTUnwrap(URL(string: "sms:2025550147")))
        let field = messages.textFields["messageBodyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), messages.debugDescription)
        field.tap()
        requireLetters(in: messages)
        let original = field.value as? String ?? ""
        var expected = original == field.placeholderValue ? "" : original
        let originalLength = expected.count
        for round in 1...4 {
            XCTContext.runActivity(named: "Messages unsent draft \(round)") { _ in
                appendKey(key("m", in: messages), to: &expected)
                key("Emoji", in: messages).tap()
                messages.buttons["emoji-category-food"].tap()
                messages.cells["emoji-🍇"].tap()
                expected += "🍇"
                messages.buttons["emoji-abc"].tap()
                chooseLetters(in: messages, apple: true)
                appendKey(appleKey("p", in: messages), to: &expected)
                chooseLetters(in: messages, apple: false)
                expect(field, expected)
            }
        }
        // Remove only our test draft without submitting it.
        for _ in expected.dropFirst(originalLength) { key("Delete", in: messages).tap() }
    }
}
