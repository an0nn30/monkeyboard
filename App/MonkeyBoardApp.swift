import SwiftUI
import UIKit

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
    @State private var percent = KeypressFeedback.storedPercent() ?? KeypressFeedback.initial
    @State private var saveFailed = false
    @State private var split = WideKeyboardLayout.prefersSplit
    @State private var layoutSaveFailed = false
    @State private var returnAfterSymbol = ReturnAfterSymbolSetting.isEnabled
    @State private var symbolSaveFailed = false
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
                AppearanceSettings()
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
            Section("Keypress feedback") {
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
                } label: {
                    Label("Try a keypress", systemImage: "waveform")
                }
                .disabled(percent == 0)
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
        .onAppear { reload() }
        .onChange(of: phase) { _, next in if next == .active { reload() } }
    }

    private func reload() {
        autoCorrect = AutoCorrectionSetting.isEnabled
        useSentence = SentenceScoringSetting.isEnabled
        transformer = TransformerSetting.isEnabled
        split = WideKeyboardLayout.prefersSplit
        returnAfterSymbol = ReturnAfterSymbolSetting.isEnabled
        percent = KeypressFeedback.storedPercent() ?? KeypressFeedback.initial
    }
}

@MainActor
private final class PreviewFeedback {
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
