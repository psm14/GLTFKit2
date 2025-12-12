import Cocoa
import SwiftUI
import RealityKit
import GLTFKit2

final class ViewerState: ObservableObject {
    @Published var asset: GLTFAsset?
    @Published var focusRequestID: Int = 0

    func requestFocus() {
        focusRequestID += 1
    }
}

class ViewController: NSViewController {
    var asset: GLTFAsset? {
        didSet {
            viewerState.asset = asset
        }
    }

    private let viewerState = ViewerState()

    @IBOutlet weak var focusOnSceneMenuItem: NSMenuItem!

    override func viewDidLoad() {
        super.viewDidLoad()
        installRealityKitViewer()
    }

    private func installRealityKitViewer() {
        if #available(macOS 15.0, *) {
            let rootView = GLTFRealityViewer(state: viewerState)
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: view.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        } else {
            let label = NSTextField(labelWithString: "RealityKit viewer requires macOS 15 or later.")
            label.alignment = .center
            label.font = NSFont.systemFont(ofSize: 15, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
    }

    @IBAction func focusOnScene(_ sender: Any) {
        viewerState.requestFocus()
    }
}

@available(macOS 15.0, *)
private struct GLTFRealityViewer: View {
    @ObservedObject var state: ViewerState

    @State private var currentEntity: Entity?
    @State private var addedEntity: Entity?
    @State private var animations: [AnimationResource] = []
    @State private var selectedAnimationIndex: Int = 0
    @State private var playbackController: AnimationPlaybackController?
    @State private var isPlaying = false
    @State private var loopMode: LoopMode = .loopOne
    @State private var progress: Double = 0
    @State private var duration: Double = 1.0
    @State private var playbackTimer: Timer?

    private enum LoopMode: Int, CaseIterable {
        case loopAll
        case loopOne
        case dontLoop

        var title: String {
            switch self {
            case .loopAll: return "All"
            case .loopOne: return "One"
            case .dontLoop: return "Off"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RealityView(make: { content in
                content.camera = .virtual
            }, update: { content in
                if let previous = addedEntity, previous !== currentEntity {
                    content.remove(previous)
                    addedEntity = nil
                }
                if let entity = currentEntity, addedEntity == nil {
                    content.add(entity)
                    content.cameraTarget = entity
                    addedEntity = entity
                }
            })
            .realityViewCameraControls(.orbit)
            .background(Color(nsColor: NSColor(named: "BackgroundColor") ?? .white))

            if !animations.isEmpty {
                playbackOverlay
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 8)
            }
        }
        .onAppear {
            loadAsset()
            schedulePlaybackTimer()
        }
        .onChange(of: state.asset) { _ in
            loadAsset()
        }
        .onChange(of: state.focusRequestID) { _ in
            refocusEntity()
        }
        .onDisappear {
            playbackTimer?.invalidate()
            playbackTimer = nil
        }
    }

    private var playbackOverlay: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("Animation", selection: $selectedAnimationIndex) {
                    ForEach(animations.indices, id: \.self) { i in
                        Text(animations[i].name ?? "Animation \(i + 1)").tag(i)
                    }
                }
                .onChange(of: selectedAnimationIndex) { _ in
                    startSelectedAnimation(startsPaused: !isPlaying)
                }

                Picker("Loop", selection: $loopMode) {
                    ForEach(LoopMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: loopMode) { _ in
                    startSelectedAnimation(startsPaused: !isPlaying)
                }

                Button(isPlaying ? "Pause" : "Play") {
                    togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
            }

            HStack(spacing: 8) {
                Text(timeString(progress))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
                Slider(value: $progress, in: 0...max(duration, 0.001)) {
                    Text("Progress")
                } onEditingChanged: { editing in
                    if !editing {
                        scrub(to: progress)
                    }
                }
                Text(timeString(duration))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60, alignment: .leading)
            }
        }
        .frame(width: 520)
    }

    private func loadAsset() {
        stopPlayback()
        guard let asset = state.asset, let scene = asset.defaultScene else {
            currentEntity = nil
            animations = []
            return
        }

        Task { @MainActor in
            let entity = GLTFRealityKitLoader.convert(scene: scene, asset: asset)
            normalize(entity: entity)
            currentEntity = entity
            animations = entity.availableAnimations
            selectedAnimationIndex = 0
            if !animations.isEmpty {
                startSelectedAnimation(startsPaused: true)
            }
        }
    }

    private func normalize(entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let extent = max(bounds.extents.x, max(bounds.extents.y, bounds.extents.z))
        guard extent > 0 else { return }
        let scaleFactor = 1.0 / extent
        entity.scale = [scaleFactor, scaleFactor, scaleFactor]
        entity.position = -bounds.center * scaleFactor
    }

    private func refocusEntity() {
        guard let entity = currentEntity else { return }
        normalize(entity: entity)
    }

    private func schedulePlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60.0, repeats: true) { _ in
            tickPlayback()
        }
    }

    private func tickPlayback() {
        guard let controller = playbackController else { return }

        if loopMode == .loopAll, controller.isComplete {
            advanceToNextAnimation()
            return
        }

        let t = controller.time
        if duration > 0, duration.isFinite {
            progress = t.truncatingRemainder(dividingBy: duration)
        } else {
            progress = t
        }
        isPlaying = controller.isPlaying
    }

    private func baseDuration(for animation: AnimationResource, on entity: Entity) -> Double {
        let temp = entity.playAnimation(animation, transitionDuration: 0, startsPaused: true)
        let d = temp.duration
        temp.stop()
        return d.isFinite && d > 0 ? d : 1.0
    }

    private func startSelectedAnimation(startsPaused: Bool) {
        guard let entity = currentEntity, selectedAnimationIndex < animations.count else { return }
        stopPlayback()

        let original = animations[selectedAnimationIndex]
        duration = baseDuration(for: original, on: entity)

        var toPlay = original
        switch loopMode {
        case .loopOne:
            toPlay = original.repeat()
        case .loopAll, .dontLoop:
            break
        }

        playbackController = entity.playAnimation(toPlay, transitionDuration: 0, startsPaused: startsPaused)
        progress = 0
        isPlaying = !startsPaused
    }

    private func advanceToNextAnimation() {
        guard !animations.isEmpty else { return }
        let next = (selectedAnimationIndex + 1) % animations.count
        selectedAnimationIndex = next
        startSelectedAnimation(startsPaused: false)
    }

    private func togglePlayPause() {
        guard let controller = playbackController else {
            startSelectedAnimation(startsPaused: false)
            return
        }
        if controller.isPaused {
            controller.resume()
            isPlaying = true
        } else {
            controller.pause()
            isPlaying = false
        }
    }

    private func scrub(to time: Double) {
        guard let controller = playbackController else { return }
        controller.time = time
        progress = time
    }

    private func stopPlayback() {
        playbackController?.stop()
        playbackController = nil
        progress = 0
        isPlaying = false
    }

    private func timeString(_ t: Double) -> String {
        String(format: "%.2f", t)
    }
}
