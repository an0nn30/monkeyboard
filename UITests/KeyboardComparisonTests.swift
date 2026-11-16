import XCTest

/// Capture the same actual key taps in the same host with either keyboard selected.
/// Run on a fresh English simulator per keyboard. Outputs are measurements, including misses.
final class KeyboardComparisonTests: XCTestCase {
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
