import SwiftUI
import UIKit
import notify

@main
struct MonkeyBoardApp: App {
    var body: some Scene {
        WindowGroup { NavigationStack { TypingRoom() } }
    }
}

private struct TypingRoom: View {
    @Environment(\.openURL) private var openURL
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add MonkeyBoard in Settings, then use the globe key to select it.")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Message draft").font(.headline)
                    TextEditor(text: $draft)
                        .focused($editing)
                        .accessibilityLabel("Message draft")
                        .accessibilityIdentifier("draft")
                        .font(.title3)
                        .padding(8)
                        .frame(minHeight: 96)
                        .scrollContentBackground(.hidden)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                if editing {
                    Button("Done typing") { editing = false }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        Text("General → Keyboard → Keyboards → Add New Keyboard → MonkeyBoard")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("MonkeyBoard")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    KeyboardSettings()
                } label: {
                    Label("Keyboard Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("keyboard-settings")
            }
        }
    }
}

private struct KeyboardSettings: View {
    @Environment(\.scenePhase) private var phase
    @State private var sound = TypingSound.stored
    @State private var soundSaveFailed = false
    @State private var percent = KeypressFeedback.storedPercent() ?? KeypressFeedback.initial
    @State private var saveFailed = false
    @State private var split = WideKeyboardLayout.prefersSplit
    @State private var repeatSplitLetters = WideKeyboardLayout.repeatsLetters
    @State private var layoutSaveFailed = false
    @State private var returnAfterSymbol = ReturnAfterSymbolSetting.isEnabled
    @State private var symbolSaveFailed = false
    @State private var glideEnabled = GlideTypingSetting.isEnabled
    @State private var glideSaveFailed = false
    @State private var autoCorrect = AutoCorrectionSetting.isEnabled
    @State private var correctionSaveFailed = false
    @State private var useSentence = SentenceScoringSetting.isEnabled
    @State private var transformer = TransformerSetting.isEnabled
    @State private var modelSaveFailed = false
    @State private var sentenceSaveFailed = false
    @State private var preview = PreviewFeedback()

    var body: some View {
        Form {
            NavigationLink {
                AppearanceSettings(repeatSplitLetters: repeatSplitLetters)
            } label: {
                Label("Appearance", systemImage: "paintpalette")
            }
            .accessibilityIdentifier("appearance-settings")
            Section {
                Toggle("Split on wide screens", isOn: Binding(
                    get: { split },
                    set: { newValue in
                        layoutSaveFailed = !WideKeyboardLayout.setSplit(newValue)
                        if !layoutSaveFailed { split = newValue }
                    }
                )).accessibilityIdentifier("split-wide-screens")
                Toggle("Show Y and B on both sides", isOn: Binding(
                    get: { repeatSplitLetters },
                    set: { enabled in
                        layoutSaveFailed = !WideKeyboardLayout.setRepeatLetters(enabled)
                        if !layoutSaveFailed { repeatSplitLetters = enabled }
                    }
                )).accessibilityIdentifier("repeat-split-letters")
                if layoutSaveFailed {
                    Text("Couldn’t save the layout. Try again.").foregroundStyle(.red)
                }
            } header: {
                Text("Layout")
            } footer: {
                Text("Places keys and a spacebar under each thumb when there’s room. You can also switch layouts from the keyboard.")
            }
            Section {
                Toggle("Return to letters after a symbol", isOn: Binding(
                    get: { returnAfterSymbol },
                    set: { enabled in
                        symbolSaveFailed = !ReturnAfterSymbolSetting.save(enabled)
                        if !symbolSaveFailed { returnAfterSymbol = enabled }
                    }
                )).accessibilityIdentifier("return-after-symbol")
                if symbolSaveFailed { Text("Couldn’t save this setting. Try again.").foregroundStyle(.red) }
            } footer: {
                Text("When you open 123 or #+=, typing one number or symbol switches back to ABC.")
            }
            Section {
                Toggle("Glide typing", isOn: Binding(
                    get: { glideEnabled },
                    set: { value in
                        glideSaveFailed = !GlideTypingSetting.save(value)
                        if !glideSaveFailed { glideEnabled = value }
                    }
                )).accessibilityIdentifier("glide-typing")
                if glideSaveFailed { Text("Couldn’t save Glide typing. Try again.").foregroundStyle(.red) }
                Toggle("Auto-Correction", isOn: Binding(
                    get: { autoCorrect },
                    set: { newValue in
                        correctionSaveFailed = !AutoCorrectionSetting.save(newValue)
                        if !correctionSaveFailed { autoCorrect = newValue }
                    }
                )).accessibilityIdentifier("auto-correction")
                Toggle("Use sentence context", isOn: Binding(
                    get: { useSentence },
                    set: { newValue in
                        sentenceSaveFailed = !SentenceScoringSetting.save(newValue)
                        if !sentenceSaveFailed { useSentence = newValue }
                    }
                )).disabled(!autoCorrect).accessibilityIdentifier("sentence-context")
                Picker("Prediction model", selection: Binding(
                    get: { transformer },
                    set: { value in
                        modelSaveFailed = !TransformerSetting.save(value)
                        if !modelSaveFailed { transformer = value }
                    }
                )) {
                    Text("Compact").tag(false)
                    Text("Transformer · 15M").tag(true)
                }.disabled(!useSentence)
                if modelSaveFailed { Text("Couldn’t save the model choice. Try again.").foregroundStyle(.red) }
                if sentenceSaveFailed { Text("Couldn’t save sentence context. Try again.").foregroundStyle(.red) }
                if correctionSaveFailed { Text("Couldn’t save Auto-Correction. Try again.").foregroundStyle(.red) }
            } footer: {
                Text("The transformer suggests the next word and can revise a recent spelling as you keep typing. Tap Delete immediately after a correction to undo it.")
            }
            Section {
                NavigationLink {
                    PersonalSpellingsSettings()
                } label: {
                    Label("Learned spellings", systemImage: "text.book.closed")
                }
                .accessibilityIdentifier("personal-spellings")
            }
            Section("Keypress feedback") {
                Picker("Typing sound", selection: Binding(get: { sound }, set: { next in
                    soundSaveFailed = !next.save()
                    guard !soundSaveFailed else { return }
                    sound = next
                    preview.sound.select(next)
                    if next != .systemClick { preview.sound.play() }
                })) {
                    ForEach(TypingSound.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("typing-sound")
                .accessibilityValue(sound.title)
                if soundSaveFailed { Text("Couldn’t save the typing sound. Try again.").foregroundStyle(.red) }
                if sound != .off {
                    Text(sound == .systemClick
                         ? "System Click uses Apple’s Keyboard Feedback sound setting. For a deeper Backspace and higher Space, choose iOS-Style Click. Both require Allow Full Access while typing."
                         : "To hear this while typing, turn on Allow Full Access for MonkeyBoard in iOS keyboard settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Firmness", value: percent == 0 ? "Off" : "\(percent)%")
                        .monospacedDigit()
                    Slider(value: Binding(
                        get: { Double(percent) },
                        set: { newValue in
                            let next = Int(newValue.rounded())
                            guard next != percent else { return }
                            percent = next
                            saveFailed = !KeypressFeedback.save(next)
                            preview.tick(next)
                        }
                    ), in: 0...100, step: 1)
                    .accessibilityLabel("Keypress firmness")
                    .accessibilityValue(percent == 0 ? "Off" : "\(percent)%")
                    .accessibilityIdentifier("firmness-slider")
                    HStack { Text("Off"); Spacer(); Text("Firm") }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                Button {
                    preview.play(percent)
                    if sound != .systemClick { preview.sound.play() }
                } label: {
                    Label("Try a keypress", systemImage: "waveform")
                }
                .disabled(percent == 0 && (sound == .off || sound == .systemClick))
                if saveFailed {
                    Text("Couldn’t save the firmness. Adjust the slider to try again.")
                        .foregroundStyle(.red)
                }
            }
            Section {
                NavigationLink("Prediction data credits") {
                    List {
                        Section("Taskmaster-1 · 2019") {
                            Text("Bill Byrne, Karthik Krishnamoorthi, Chinnadhurai Sankar, Arvind Neelakantan, Amit Dubey, Kyu-Young Kim and Andy Cedilnik, Google LLC. MonkeyBoard derives word counts and trains its sentence model on English written dialogue.")
                            Link("Original dataset", destination: URL(string: "https://github.com/google-research-datasets/Taskmaster/tree/master/TM-1-2019")!)
                            Link("Creative Commons Attribution 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                        }
                        Section("Taskmaster-2 · 2020") {
                            Text("Google LLC and the Taskmaster contributors. MonkeyBoard uses English conversational transcripts to train its prediction and word-boundary models.")
                            Link("Original dataset", destination: URL(string: "https://github.com/google-research-datasets/Taskmaster/tree/d92cb6af3005f1dc09c39e75e7daf4a04905e00b/TM-2-2020")!)
                            Link("Creative Commons Attribution 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                        }
                        Section("SMS Spam Collection") {
                            Text("Tiago Almeida and José María Gómez Hidalgo. MonkeyBoard uses separate groups of non-spam messages to learn casual spellings, train word-context weights, and evaluate corrections.")
                            Link("UCI dataset", destination: URL(string: "https://archive.ics.uci.edu/dataset/228/sms+spam+collection")!)
                            Link("Creative Commons Attribution 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                        }
                        Section("WordNet 3.0") {
                            Text("MonkeyBoard derives word relationships from Princeton University’s English noun definitions.")
                            if let url = Bundle.main.url(forResource: "WordNet-LICENSE", withExtension: "txt"),
                               let license = try? String(contentsOf: url, encoding: .utf8) {
                                NavigationLink("Copyright and license") {
                                    ScrollView { Text(license).padding() }.navigationTitle("WordNet license")
                                }
                            }
                        }
                        Section("Tatoeba") {
                            Text("MonkeyBoard derives word counts and trains its sentence model on Tatoeba contributors’ English CC0 export.")
                            Link("Source and terms", destination: URL(string: "https://tatoeba.org/en/downloads")!)
                        }
                    }.navigationTitle("Prediction data credits")
                }
            }

        }
        .background(FeedbackAnchor(preview: preview).frame(width: 1, height: 1))
        .navigationTitle("Keyboard Settings")
        .onDisappear { preview.sound.select(.off) }
        .onAppear { reload() }
        .onChange(of: phase) { _, next in if next == .active { reload() } }
    }

    private func reload() {
        sound = .stored
        preview.sound.select(sound)
        glideEnabled = GlideTypingSetting.isEnabled
        autoCorrect = AutoCorrectionSetting.isEnabled
        useSentence = SentenceScoringSetting.isEnabled
        transformer = TransformerSetting.isEnabled
        split = WideKeyboardLayout.prefersSplit
        repeatSplitLetters = WideKeyboardLayout.repeatsLetters
        returnAfterSymbol = ReturnAfterSymbolSetting.isEnabled
        percent = KeypressFeedback.storedPercent() ?? KeypressFeedback.initial
    }
}

private struct PersonalSpellingsSettings: View {
    @Environment(\.scenePhase) private var phase
    @State private var snapshot = PersonalSpellings.Snapshot()
    @State private var speed = LearningSpeed.balanced
    @State private var editing: PersonalSpellings.Preference?
    @State private var confirmingReset = false
    @State private var failed = false

    var body: some View {
        List {
            Section {
                Picker("Learning speed", selection: Binding(get: { speed }, set: { next in
                    update(next.save())
                })) {
                    ForEach([LearningSpeed.careful, .balanced, .fast], id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("learning-speed")
            } header: {
                Text("Learning speed")
            } footer: {
                Text("Learn after \(speed.rawValue) matching corrections. Undo an autocorrection or choose a different spelling while typing or swiping.")
            }
            if snapshot.preferences.isEmpty {
                Text("No learned spellings yet").foregroundStyle(.secondary)
                    .accessibilityIdentifier("no-learned-spellings")
            } else {
                preferenceSection(.typing, title: "Typing")
                preferenceSection(.swipe, title: "Swipe typing")
            }
            Section {
                Button("Reset spelling memory", role: .destructive) { confirmingReset = true }
                    .disabled(snapshot.preferences.isEmpty && !snapshot.hasPending)
                    .accessibilityIdentifier("reset-spellings")
            } footer: {
                Text("Learned words and pending choices stay on this device. Reset clears both.")
            }
            if failed { Text("Couldn’t save the change. Try again.").foregroundStyle(.red) }
        }
        .navigationTitle("Learned spellings")
        .onAppear { reload() }
        .onChange(of: phase) { _, value in if value == .active { reload() } }
        .sheet(item: $editing) { preference in
            EditSpelling(preference: preference) { update(true) }
        }
        .alert("Reset spelling memory?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { update(PersonalSpellings.reset()) }
        } message: { Text("This clears typing and swipe preferences, including choices still being learned.") }
    }

    @ViewBuilder private func preferenceSection(_ input: SpellingInput, title: String) -> some View {
        let entries = snapshot.preferences.filter { $0.input == input }
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { entry in
                    let suffix = (input == .swipe ? "swipe-" : "") + entry.original.lowercased()
                    HStack {
                        Button {
                            editing = entry
                        } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: entry.original)
                                Text(entry.keepsOriginal ? "Keep spelling" : "Use “\(entry.preferred)”")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit " + entry.original)
                        .accessibilityIdentifier("edit-spelling-" + suffix)
                        Spacer()
                        Button("Forget", role: .destructive) { update(PersonalSpellings.forget(entry)) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Forget " + entry.original)
                            .accessibilityIdentifier("forget-spelling-" + suffix)
                    }
                }
            }
        }
    }

    private func reload() {
        snapshot = PersonalSpellings.snapshot()
        speed = .stored
    }

    private func update(_ success: Bool) {
        failed = !success
        if success { notify_post(PersonalSpellings.settingsChanged) }
        reload()
    }
}

private struct EditSpelling: View {
    @Environment(\.dismiss) private var dismiss
    let preference: PersonalSpellings.Preference
    let didSave: () -> Void
    @State private var word: String
    @State private var failed = false

    init(preference: PersonalSpellings.Preference, didSave: @escaping () -> Void) {
        self.preference = preference
        self.didSave = didSave
        _word = State(initialValue: preference.preferred)
    }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent(preference.input == .swipe ? "Swipe result" : "Typed spelling", value: preference.original)
                Section {
                    TextField("Preferred spelling", text: $word)
                        .accessibilityIdentifier("preferred-spelling")
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Preferred spelling")
                } footer: {
                    Text(preference.input == .swipe
                         ? "This word moves to first place when it’s among the matches for your swipe."
                         : "Misspellings can be corrected automatically. For a valid word, the alternative appears in suggestions.")
                }
                if failed { Text("Couldn’t update this spelling. Reopen it and try again.").foregroundStyle(.red) }
            }
            .navigationTitle("Edit spelling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard PersonalSpellings.edit(preference, to: word) else { failed = true; return }
                        didSave()
                        dismiss()
                    }.disabled(RejectedSpelling.key(word) == nil || word == preference.preferred)
                }
            }
        }
    }
}

@MainActor
private final class PreviewFeedback {
    let sound = TypingSoundPlayer()
    var player: KeypressPlayer?
    private var lastTick = TimeInterval.zero

    func tick(_ percent: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTick >= 0.08 else { return }
        lastTick = now
        play(percent)
    }

    func play(_ percent: Int) { player?.play(percent) }
}

private struct FeedbackAnchor: UIViewRepresentable {
    let preview: PreviewFeedback

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        preview.player = KeypressPlayer(view: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
