// Standalone, read-only checks of what a contextual Undo is allowed to teach.
import Foundation

@main enum CheckRejectionAttribution {
    static func main() {
        typealias Change = RejectedSpelling
        func verify(_ typed: String, _ visible: String, _ proposal: String, _ word: String?, _ replacement: String? = nil) {
            let change = Change.singleChange(typed: typed, before: visible, after: proposal)
            precondition(change?.word == word && change?.replacement == replacement, "Incorrect attribution for: \(typed)")
        }
        verify("my teh dog.", "my teh dog.", "my the dog.", "teh", "the")
        verify("lets go!", "lets go!", "let’s go!", "lets", "let's")
        verify("pick up the kidsin the morning", "pick up the kidsin the morning",
               "pick up the kids in the morning", "kidsin", "kids in")
        verify("Teh dog", "The dog", "That dog", nil) // The user never typed “The.”
        verify("teh dgo", "teh dgo", "the dog", nil) // One Undo reversed two edits.
        verify("two  words", "two  words", "two words", nil)
        verify("same", "same", "same", nil)
        verify("today", "today", "Today", nil)
        verify("on line", "on line", "online", nil)
        verify("I cant go", "I can’t go", "I can't go", nil)
        precondition(Change("pass123", "password") == nil && Change("a@b", "ab") == nil)
        precondition(Change.key("Y’all") == "y'all")
        print("Passed single-word, split-word, apostrophe, and ambiguous-undo attribution checks.")
    }
}
