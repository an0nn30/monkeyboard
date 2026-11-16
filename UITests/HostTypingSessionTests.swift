import XCTest
import Vision

/// Opt-in so running the regular UI suite never writes in a third-party app.
final class HostTypingSessionTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func key(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier ==[c] %@", "key-" + name)).firstMatch
    }

    func testFirefoxTypingSession() throws {
        try XCTSkipUnless(environment["MONKEYBOARD_HOST_SESSION"] == "firefox")
        let (app, field) = try firefoxDraft()
        try typeSession(in: app, field: field, host: "firefox")
    }

    private func firefoxDraft() throws -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication(bundleIdentifier: "org.mozilla.ios.Fennec")
        app.launchArguments = ["FIREFOX_TEST", "FIREFOX_SKIP_INTRO", "FIREFOX_SKIP_TERMS_OF_USE",
                               "FIREFOX_SKIP_WHATS_NEW", "FIREFOX_SKIP_CONTEXTUAL_HINTS"]
        if environment["MONKEYBOARD_HOST_SESSION"] == "finger" {
            app.launchArguments.append("DISABLE_ANIMATIONS") // Firefox test-host animations only
        }
        app.launch()
        let port = Int(environment["MONKEYBOARD_DRAFT_PORT"] ?? "") ?? 18768
        let link = try XCTUnwrap(URL(string: "fennec://open-url?url=http%3A%2F%2F127.0.0.1%3A\(port)%2F"))
        app.open(link)
        let field = app.webViews.textViews["MonkeyBoard test draft"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 12), "Local Firefox test page unavailable")
        return (app, field)
    }

    func testDiscordTypingSession() throws {
        try XCTSkipUnless(environment["MONKEYBOARD_HOST_SESSION"] == "discord")
        let app = XCUIApplication(bundleIdentifier: "com.hammerandchisel.discord")
        app.activate()
        // Only use a visible message editor. Never navigate into someone else's
        // conversation, open search, or substitute a login/password field.
        let predicate = NSPredicate(format:
            "(elementType == %d OR elementType == %d) AND (label BEGINSWITH[c] 'Message' OR placeholderValue BEGINSWITH[c] 'Message' OR identifier CONTAINS[c] 'chat_input' OR identifier CONTAINS[c] 'chatinput')",
            XCUIElement.ElementType.textView.rawValue, XCUIElement.ElementType.textField.rawValue)
        var field = app.descendants(matching: .any).matching(predicate).firstMatch
        if !field.exists {
            // Discord can display the empty editor as a custom placeholder until
            // focused. Locate its visible prompt before touching the screen.
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            let screenshot = XCUIScreen.main.screenshot().image
            try VNImageRequestHandler(cgImage: XCTUnwrap(screenshot.cgImage)).perform([request])
            let prompts = (request.results ?? []).filter {
                let label = $0.topCandidates(1).first?.string ?? ""
                return label.lowercased().hasPrefix("message ") && $0.boundingBox.midY < 0.5
            }
            guard prompts.count == 1, let box = prompts.first?.boundingBox else {
                XCTFail("No unique visible Discord message prompt; stopping before typing")
                return
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: box.midX, dy: 1 - box.midY)).tap()
            let editors = app.descendants(matching: .any).matching(NSPredicate(format:
                "elementType == %d OR elementType == %d", XCUIElement.ElementType.textView.rawValue,
                XCUIElement.ElementType.textField.rawValue)).allElementsBoundByIndex.filter { $0.isHittable }
            if !field.exists, editors.count == 1 { field = editors[0] }
        }
        guard field.waitForExistence(timeout: 5) else {
            XCTFail("Discord editor did not become accessible; stopping before typing")
            return
        }
        try typeSession(in: app, field: field, host: "discord")
    }

    private func typeSession(in app: XCUIApplication, field: XCUIElement, host: String) throws {
        let initial = field.value as? String ?? ""
        guard initial.isEmpty || initial == field.placeholderValue else {
            XCTFail("Existing draft; stopping before typing")
            return
        }
        field.tap()
        app.switchToKeyboard(showing: app.buttons["keyboard-options"])
        let letters = key("ABC", in: app)
        if letters.exists && letters.isHittable { letters.tap() }
        let phrases = ["we can meet at noon ", "the book is on the shelf ", "we can go for a walk ",
                       "the blue bag is on the seat ", "you can take the next train "]
        let space = key("Space-left", in: app).exists ? "Space-left" : "Space"
        var targets: [Character: XCUICoordinate] = [:]
        for letter in Set(phrases.joined()) {
            let button = key(letter == " " ? space : String(letter), in: app)
            XCTAssertTrue(button.isHittable, "Unreachable test key")
            targets[letter] = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        }
        let probe = app.descendants(matching: .any)["sound-footprint-probe"].firstMatch
        func processID() -> String? {
            guard probe.exists, let raw = probe.value as? String else { return nil }
            let parts = raw.split(separator: "|")
            return parts.count >= 3 ? String(parts[2]) : nil
        }
        let pid = processID()
        let start = ProcessInfo.processInfo.systemUptime
        let duration = Double(environment["MONKEYBOARD_HOST_SECONDS"] ?? "") ?? 600
        var typed = "", rounds = 0
        func record(_ state: String) {
            print("HOSTSOAK host=\(host) state=\(state) taps=\(typed.count) rounds=\(rounds) elapsed=\(Int(ProcessInfo.processInfo.systemUptime - start)) pid=\(pid ?? "external")")
        }
        record("start")
        defer {
            // Cleanup uses only a verified synthetic prefix in the original field.
            if host == "discord", !typed.isEmpty, field.exists, let actual = field.value as? String,
               !actual.isEmpty, typed.lowercased().hasPrefix(actual.lowercased()) {
                let own = key("Delete", in: app)
                let delete = own.isHittable ? own : app.keyboards.keys["delete"].firstMatch
                if delete.isHittable { delete.press(forDuration: Double(actual.count) * 0.08 + 1.2) }
                let value = field.value as? String ?? ""
                XCTAssertTrue(value.isEmpty || value == initial || value == field.placeholderValue, "Draft cleanup incomplete")
                if value.isEmpty || value == initial || value == field.placeholderValue { record("cleared") }
            }
        }
        repeat {
            let phrase = phrases[rounds % phrases.count]
            for character in phrase {
                try XCTUnwrap(targets[character]).tap()
                typed.append(character)
            }
            rounds += 1
            guard app.buttons["keyboard-options"].exists else {
                record(app.keyboards.keys["q"].firstMatch.exists ? "apple-keyboard-visible" : "monkeyboard-missing")
                XCTFail("MonkeyBoard disappeared during continuous typing")
                return
            }
            if let pid, processID() != pid {
                record("extension-restarted")
                XCTFail("Keyboard extension restarted during continuous typing")
                return
            }
            let value = (field.value as? String)?.lowercased()
            guard value == typed else {
                record("draft-mismatch")
                XCTFail("Draft differed after \(typed.count) taps; observed length \(value?.count ?? -1)")
                return
            }
            record("verified")
            if host == "discord", typed.count + 30 >= 1900, ProcessInfo.processInfo.systemUptime - start < duration {
                XCTFail("Reached the draft length limit before the requested duration")
                return
            }
        } while ProcessInfo.processInfo.systemUptime - start < duration
        record("complete")
    }
}

#if targetEnvironment(simulator)
extension HostTypingSessionTests {
    /// A separate draft, text cursor and keyboard process may belong to each host.
    private final class EditingHost {
        let name: String
        let app: XCUIApplication
        let field: XCUIElement
        var expected = ""
        var process: String?
        var checks = 0

        init(_ name: String, _ app: XCUIApplication, _ field: XCUIElement) {
            self.name = name
            self.app = app
            self.field = field
        }

        var draft: String {
            let value = field.value as? String ?? ""
            return value == field.placeholderValue ? "" : value
        }

        var monkeyBoard: XCUIElement { app.buttons["keyboard-options"] }
        var appleLetter: XCUIElement {
            app.keyboards.keys.matching(NSPredicate(format: "label ==[c] 'q'")).firstMatch
        }

        func pid() -> String? {
            let probe = app.descendants(matching: .any)["sound-footprint-probe"].firstMatch
            guard probe.exists, let raw = probe.value as? String else { return nil }
            let parts = raw.split(separator: "|")
            guard parts.count == 8, Int(parts[2]) != nil else { return nil }
            return String(parts[2])
        }
    }

    func testMessagesFirefoxMidSentence() throws {
        try XCTSkipUnless(environment["MONKEYBOARD_HOST_SESSION"] == "messages-firefox")
        let (browser, textarea) = try firefoxDraft()
        let firefox = EditingHost("firefox", browser, textarea)
        firefox.field.tap()
        browser.switchToKeyboard(showing: firefox.monkeyBoard)

        let sms = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        // Use a fictional recipient and a fresh compose session for every run.
        let number = String(format: "20255501%02d", Int.random(in: 0...99))
        if sms.state != .notRunning { sms.terminate() }
        sms.open(try XCTUnwrap(URL(string: "sms:" + number)))
        let messages = EditingHost("messages", sms, sms.textFields["messageBodyField"])
        XCTAssertTrue(messages.field.waitForExistence(timeout: 8), "Messages composer unavailable")
        let intro = "the weather looks good so we can meet at the "
        let places = ["park after lunch", "lake before dinner", "shop on the corner"]
        let items = ["the blue bag", "a book for the train", "the tickets for the game"]
        func messagePassage(_ round: Int) -> String {
            places[round % places.count] + ". please bring the blue bag so we can carry the books. we can meet at the "
        }
        func isPreviousTestDraft(_ text: String) -> Bool {
            guard text.hasPrefix(intro) else { return false }
            var prefix = intro, round = 0
            while prefix.count < text.count {
                prefix += messagePassage(round)
                round += 1
                if (prefix + places[round % places.count] + ".").hasPrefix(text) { return true }
            }
            return text == intro
        }
        func clearTestDraft() {
            // Use the editing menu; hardware shortcuts can hide the simulator's keyboard.
            messages.field.press(forDuration: 0.8)
            let selectAll = sms.descendants(matching: .any)
                .matching(NSPredicate(format: "label ==[c] 'Select All'")).firstMatch
            guard selectAll.waitForExistence(timeout: 2) && selectAll.isHittable else {
                XCTFail("Select All unavailable for the verified synthetic Messages draft")
                return
            }
            selectAll.tap()
            let delete = key("Delete", in: sms)
            guard delete.isHittable else { XCTFail("Keyboard unavailable to clear the synthetic draft"); return }
            delete.tap()
            XCTAssertTrue(messages.field.exists && messages.draft.isEmpty, "Synthetic Messages draft cleanup incomplete")
        }
        messages.field.tap()
        let existing = messages.draft.lowercased()
        if !existing.isEmpty {
            guard isPreviousTestDraft(existing) else {
                XCTFail("Existing Messages draft is outside the test corpus (length \(existing.count), startsWithIntro=\(existing.hasPrefix(intro))); stopped before typing")
                return
            }
            sms.switchToKeyboard(showing: messages.monkeyBoard)
            clearTestDraft()
        }
        sms.switchToKeyboard(showing: messages.monkeyBoard)
        let start = ProcessInfo.processInfo.systemUptime
        let duration = Double(environment["MONKEYBOARD_HOST_SECONDS"] ?? "") ?? 720
        var active = messages
        var switches = 0

        func log(_ state: String, detail: String = "") {
            print("HOSTSOAK host=\(active.name) state=\(state) time=\(ISO8601DateFormatter().string(from: Date())) elapsed=\(Int(ProcessInfo.processInfo.systemUptime - start)) switches=\(switches) messages=\(messages.expected.count) firefox=\(firefox.expected.count) messagesChecks=\(messages.checks) firefoxChecks=\(firefox.checks) pid=\(active.process ?? "unavailable") \(detail)")
        }

        addTeardownBlock { [self] in
            guard let failures = testRun?.failureCount, failures > 0 else { return }
            let visible = active.monkeyBoard.exists ? "monkeyboard" : (active.appleLetter.exists ? "apple" : "unidentified")
            log("failure", detail: "keyboard=\(visible) observedPID=\(active.pid() ?? "unavailable")")
            let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            evidence.name = "Keyboard visible at failure in " + active.name
            evidence.lifetime = .keepAlways
            self.add(evidence)
        }

        func verify(_ stage: String) throws {
            guard active.monkeyBoard.exists else {
                log(active.appleLetter.exists ? "apple-fallback" : "keyboard-missing", detail: "stage=" + stage)
                throw SessionError("MonkeyBoard disappeared in \(active.name) during \(stage)")
            }
            let current = active.pid()
            if stage == "resume" || stage == "start" {
                let previous = active.process
                active.process = current
                log(stage, detail: "previousPID=\(previous ?? "unavailable")")
            } else if current != active.process {
                log("process-changed-during-typing", detail: "observedPID=\(current ?? "unavailable")")
                throw SessionError("Extension process changed during typing")
            }
            let actual = active.draft.lowercased()
            guard actual == active.expected else {
                let prefix = zip(actual, active.expected).prefix(while: { $0 == $1 }).count
                log("draft-mismatch", detail: "stage=\(stage) observedLength=\(actual.count) firstDifference=\(prefix)")
                throw SessionError("Draft changed in \(active.name) during \(stage)")
            }
            active.checks += 1
        }

        func switchHost(to target: EditingHost) throws {
            log("switch-away")
            active = target
            switches += 1
            target.app.activate()
            XCTAssertTrue(target.app.wait(for: .runningForeground, timeout: 6))
            // Returning can dismiss the input view. Refocus only if neither
            // letter keyboard appeared. Never reselect the keyboard during the run.
            if !target.monkeyBoard.waitForExistence(timeout: 2) && !target.appleLetter.exists {
                log("refocus")
                target.field.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.91)).tap()
                _ = target.monkeyBoard.waitForExistence(timeout: 3)
            }
            try verify("resume")
        }

        func type(_ chunk: String) throws {
            var targets = [Character: XCUICoordinate]()
            let space = key("Space-left", in: active.app).exists ? "Space-left" : "Space"
            for letter in Set(chunk) {
                let button = key(letter == " " ? space : String(letter), in: active.app)
                guard button.isHittable else { throw SessionError("Unreachable key in " + active.name) }
                targets[letter] = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            }
            for (index, character) in chunk.enumerated() {
                try XCTUnwrap(targets[character]).tap()
                active.expected.append(character)
                if (index + 1).isMultiple(of: 20) { try verify("typing") }
            }
            try verify("end-of-passage")
            log("verified")
        }

        try verify("start")
        try type(intro)
        var round = 0
        repeat {
            try switchHost(to: firefox)
            try type(round == 0 ? "before we go we still need to bring " :
                        items[(round - 1) % items.count] + ". we still need to bring ")
            try switchHost(to: messages)
            try type(messagePassage(round))
            round += 1
        } while ProcessInfo.processInfo.systemUptime - start < duration || round < 2
        try switchHost(to: firefox)
        try type(items[(round - 1) % items.count] + ".")
        try switchHost(to: messages)
        try type(places[round % places.count] + ".")
        log("complete")
        // Only this test's verified, previously empty draft can be cleared.
        clearTestDraft()
        let cancel = sms.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap() }
    }

    private struct SessionError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
#endif

#if targetEnvironment(simulator)
extension HostTypingSessionTests {
    private struct FingerTap: Decodable {
        let key: String
        let controlX, controlY: Double
    }
    private struct FingerCase: Decodable {
        let profile: String
        let seed: UInt64
        let text: String
        let taps: [FingerTap]
    }
    private struct FingerResult: Encodable {
        let profile: String, intended: String, mode: String, observed: String, layout: String
        let seed: UInt64
        let completedTaps: Int
    }

    func testFingerReplay() throws {
        try XCTSkipUnless(environment["MONKEYBOARD_HOST_SESSION"] == "finger")
        let input = try XCTUnwrap(environment["MONKEYBOARD_FINGER_CASES"])
        let cases = try JSONDecoder().decode([FingerCase].self, from: Data(input.utf8))
        let port = try XCTUnwrap(environment["MONKEYBOARD_DRAFT_PORT"])
        let (browser, _) = try firefoxDraft()
        let probe = FingerCase(profile: "autocorrect-control", seed: 0, text: "teh ",
                               taps: "teh ".map { FingerTap(key: String($0), controlX: 0.5, controlY: 0.5) })
        for (index, item) in ([probe] + cases).enumerated() {
            XCTAssertEqual(item.taps.map(\.key).joined(), item.text)
            for mode in ["off", "on"] {
                let url = "http://127.0.0.1:\(port)/?correction=\(mode)&trial=\(index)"
                var deepLink = URLComponents(string: "fennec://open-url")!
                deepLink.queryItems = [URLQueryItem(name: "url", value: url)]
                browser.open(try XCTUnwrap(deepLink.url))
                let field = browser.webViews.textViews["MonkeyBoard test draft"].firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 10))
                XCTAssertEqual(field.value as? String ?? "", "")
                field.tap()
                browser.switchToKeyboard(showing: browser.buttons["keyboard-options"])
                let letters = key("ABC", in: browser)
                if letters.exists && letters.isHittable { letters.tap() }
                let split = key("Space-left", in: browser).exists
                let origin = browser.coordinate(withNormalizedOffset: .zero)
                let appFrame = browser.frame
                var completed = 0
                for tap in item.taps {
                    let name = tap.key == " " ? (split ? "Space-left" : "Space") : tap.key
                    let button = key(name, in: browser)
                    guard button.exists && button.isHittable else { break }
                    // Resolve on the current screen; allow offsets outside the intended key.
                    let cap = button.frame
                    let point = CGVector(dx: cap.minX - appFrame.minX + tap.controlX * cap.width,
                                         dy: cap.minY - appFrame.minY + tap.controlY * cap.height)
                    origin.withOffset(point).tap()
                    completed += 1
                }
                // The sentence corrector can publish a deferred edit after the boundary.
                Thread.sleep(forTimeInterval: 0.7)
                let observed = try XCTUnwrap(field.value as? String)
                let row = FingerResult(profile: item.profile, intended: item.text, mode: mode, observed: observed,
                                       layout: split ? "split" : "joined", seed: item.seed, completedTaps: completed)
                print("FINGERCASE " + String(decoding: try JSONEncoder().encode(row), as: UTF8.self))
                if index == 0 {
                    XCTAssertEqual(observed.lowercased(), mode == "off" ? "teh " : "the ", "Host autocorrection control failed")
                }
            }
        }
        print("HOSTSOAK host=accuracy state=complete cases=\(cases.count)")
    }
}
#endif
