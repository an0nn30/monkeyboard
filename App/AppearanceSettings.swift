import ImageIO
import PhotosUI
import SwiftUI

struct AppearanceSettings: View {
    @State private var tint = KeyboardTint.stored()
    @State private var photo: PhotosPickerItem?
    @State private var screenshot: ScreenshotPixels?
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Key tint") {
                HStack {
                    Circle().fill(tint.map { Color(uiColor: $0.sourceColor) } ?? .secondary)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                    Text(tint?.hex ?? "Default").monospacedDigit()
                        .accessibilityIdentifier("saved-tint")
                }
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Choose Screenshot", systemImage: "photo")
                }
                .accessibilityIdentifier("choose-screenshot")
                if loading { ProgressView("Opening screenshot…") }
                if tint != nil {
                    Button("Restore Default Tint") { save(nil) }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            Section {
                ForEach([UIUserInterfaceStyle.light, .dark], id: \.rawValue) { style in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(style == .dark ? "Dark" : "Light").font(.subheadline.weight(.medium))
                        SplitKeyboardPreview(tint: tint, style: style)
                            .aspectRatio(669.0 / 289, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Preview")
            } footer: {
                Text("Your tint colors Return and Shift when Shift is active.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: photo) {
            guard let photo else { loading = false; return }
            loading = true
            errorMessage = nil
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let image = try await ScreenshotPixels.decode(data)
                try Task.checkCancellation()
                screenshot = image
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Couldn’t open that image. Choose another screenshot."
                self.photo = nil
            }
            loading = false
        }
        .sheet(item: $screenshot, onDismiss: { photo = nil }) { image in
            TintSampler(screenshot: image) { color in
                let success = save(color)
                if success { screenshot = nil }
                return success
            }
        }
    }

    @discardableResult
    private func save(_ value: KeyboardTint?) -> Bool {
        guard KeyboardTint.save(value) else {
            errorMessage = "Couldn’t save the key tint. Try again."
            return false
        }
        tint = value
        errorMessage = nil
        return true
    }
}

/// Limit decoding to the picker and normalize orientation and color space once.
/// The displayed image and sampled bytes then have the same top-left origin.
private struct ScreenshotPixels: Identifiable {
    let id = UUID()
    let image: CGImage
    let rgba: Data

    static func decode(_ data: Data) async throws -> Self {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let width = thumbnail.width, height = thumbnail.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var pixels = Data(count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: info) else { return false }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(rect)
            context.draw(thumbnail, in: rect)
            return true
        }
        guard rendered, let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw CocoaError(.fileReadCorruptFile) }
        return Self(image: image, rgba: pixels)
    }

    func tint(at point: UnitPoint) -> KeyboardTint {
        let x = min(image.width - 1, max(0, Int(point.x * CGFloat(image.width))))
        let y = min(image.height - 1, max(0, Int(point.y * CGFloat(image.height))))
        let index = 4 * (y * image.width + x)
        return KeyboardTint(red: rgba[index], green: rgba[index + 1], blue: rgba[index + 2])
    }
}

private struct TintSampler: View {
    @Environment(\.dismiss) private var dismiss
    let screenshot: ScreenshotPixels
    let apply: (KeyboardTint) -> Bool
    @State private var point: UnitPoint?
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Tap or drag over the color you want.")
                    .font(.subheadline).foregroundStyle(.secondary)
                GeometryReader { area in
                    let image = screenshot.image
                    let scale = min(area.size.width / CGFloat(image.width), area.size.height / CGFloat(image.height))
                    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    Image(decorative: image, scale: 1)
                        .resizable().frame(width: size.width, height: size.height)
                        .overlay {
                            if let point {
                                Circle().strokeBorder(.white, lineWidth: 3)
                                    .overlay(Circle().strokeBorder(.black.opacity(0.7), lineWidth: 1))
                                    .frame(width: 24, height: 24)
                                    .position(x: point.x * size.width, y: point.y * size.height)
                                    .allowsHitTesting(false)
                            }
                        }
                        .clipped().contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { touch in
                            guard size.width > 0, size.height > 0 else { return }
                            point = UnitPoint(x: min(1, max(0, touch.location.x / size.width)),
                                              y: min(1, max(0, touch.location.y / size.height)))
                        })
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Screenshot color sampler")
                        .accessibilityIdentifier("screenshot-sampler")
                        .accessibilityAddTraits(.allowsDirectInteraction)
                        .position(x: area.size.width / 2, y: area.size.height / 2)
                }
                if let point {
                    let color = screenshot.tint(at: point)
                    HStack(spacing: 12) {
                        Circle().fill(Color(uiColor: color.sourceColor)).frame(width: 23, height: 23)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                        Text(color.hex).monospacedDigit().accessibilityIdentifier("sampled-tint")
                        Spacer()
                        ForEach([UIUserInterfaceStyle.light, .dark], id: \.rawValue) { style in
                            let traits = UITraitCollection(userInterfaceStyle: style)
                            Image(systemName: "return")
                                .foregroundStyle(style == .dark ? Color.white : .black)
                                .frame(width: 48, height: 35)
                                .background(Color(uiColor: color.keyColor.resolvedColor(with: traits)),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel(style == .dark ? "Dark Return" : "Light Return")
                        }
                    }
                }
                if saveFailed { Text("Couldn’t save the key tint. Try again.").foregroundStyle(.red) }
            }
            .padding()
            .navigationTitle("Pick a Tint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Tint") {
                        if let point { saveFailed = !apply(screenshot.tint(at: point)) }
                    }
                    .disabled(point == nil)
                }
            }
        }
    }
}

private struct SplitKeyboardPreview: UIViewRepresentable {
    let tint: KeyboardTint?
    let style: UIUserInterfaceStyle

    final class Canvas: UIView {
        let board = KeyboardView()

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            addSubview(board)
            board.setSuggestions(["I", "the", "you"])
            board.setOptionsMenu(UIMenu(), feedbackValue: "", showsSplitToggle: true)
        }

        required init?(coder: NSCoder) { fatalError("Use init()") }

        override func layoutSubviews() {
            super.layoutSubviews()
            let size = CGSize(width: 669, height: 289)
            board.bounds = CGRect(origin: .zero, size: size)
            board.center = CGPoint(x: bounds.midX, y: bounds.midY)
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            board.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }

    func makeUIView(context: Context) -> Canvas { Canvas() }

    func updateUIView(_ view: Canvas, context: Context) {
        var model = KeyboardModel()
        model.isSplit = true
        model.needsGlobe = true
        model.shift = .upper
        view.overrideUserInterfaceStyle = style
        view.backgroundColor = style == .dark ? UIColor(white: 0.16, alpha: 1) : UIColor(white: 0.88, alpha: 1)
        view.board.update(model, returnTitle: nil, accentColor: tint?.keyColor)
    }
}
