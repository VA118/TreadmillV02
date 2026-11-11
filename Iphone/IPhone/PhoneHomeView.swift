import SwiftUI
import AVFoundation
import AVKit
import WatchConnectivity

@MainActor final class PhoneRunModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published var selected = 1
    @Published var treadmillFinalDistance = ""
    @Published var savedRuns: [RunSummary] = []
    @Published var saveMessage = ""
    private let historyKey = "treadmillVO2.runHistory.v1"
    @Published var seconds = 0
    @Published var running = false
    @Published var speedKmh = 8.0
    @Published var accumulatedDistanceKm = 0.0
    private var lastTickDate: Date?
    @Published var units: UnitPreference = .kilometres
    @Published var forest = false
    @Published var silentMotivation = true
    @Published var privateMotivation = true
    @Published var videoName = ""
    @Published var voiceCues = true
    @Published var motivationEnabled = true
    @Published var motivationStatus = ""
    private var lastMotivation: Date = .distantPast
    private var timer: Timer?
    private let speaker = AVSpeechSynthesizer()
    var session: TrainingSession { TrainingLibrary.sessions[selected - 1] }
    var clock: IntervalClock { IntervalClock(intervals: session.intervals, elapsed: seconds) }
    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let history = try? RunHistory.decode(data) { savedRuns = history }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            guard let request = message["coaching"] as? String else { return }
            self.motivate(request)
        }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func startPause() {
        if running { timer?.invalidate(); running = false; lastTickDate = nil; return }
        if clock.active == nil { seconds = 0; accumulatedDistanceKm = 0 }
        running = true
        lastTickDate = Date()
        cue()
        sendState()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let previous = self.clock.active?.index
                let now = Date()
                let dt = min(3.0, max(0.0, now.timeIntervalSince(self.lastTickDate ?? now)))
                self.lastTickDate = now
                self.accumulatedDistanceKm += max(0, self.speedKmh) * dt / 3600
                self.seconds += 1
                if previous != self.clock.active?.index { self.cue() }
                self.sendState()
                if self.clock.active == nil { self.running = false; self.timer?.invalidate(); self.lastTickDate = nil }
            }
        }
    }
    func reset() { timer?.invalidate(); running = false; seconds = 0; accumulatedDistanceKm = 0; lastTickDate = nil; sendState() }
    func saveRun() {
        let trimmed = treadmillFinalDistance.trimmingCharacters(in: .whitespacesAndNewlines)
        let entered = Double(trimmed.replacingOccurrences(of: ",", with: "."))
        if !trimmed.isEmpty && (entered == nil || entered! <= 0) {
            saveMessage = "Enter a positive distance or leave the field empty."
            return
        }
        let actualKm = entered.map { units == .kilometres ? $0 : $0 * 1.609344 }
        let record = RunSummary(workoutNumber: selected, elapsedSeconds: seconds,
                                estimatedDistanceKm: accumulatedDistanceKm,
                                treadmillDistanceKm: actualKm)
        savedRuns.insert(record, at: 0)
        if let data = try? RunHistory.encode(savedRuns) {
            UserDefaults.standard.set(data, forKey: historyKey)
            saveMessage = "Run saved on this iPhone."
        } else {
            saveMessage = "Could not save run."
        }
    }
    func motivate(_ request: String) {
        guard motivationEnabled, !forest else { motivationStatus = "Coaching muted in forest mode"; return }
        guard Date().timeIntervalSince(lastMotivation) >= 8 else { return }
        lastMotivation = Date()
        let phrase: String
        switch request {
        case "push": phrase = "Stay steady. You've got this."
        case "motivate": phrase = "Keep going. Every minute counts."
        default: return
        }
        motivationStatus = phrase
        // No on-screen motivational overlay. This status is only on the settings screen.
        // Audio is disabled by default and must be explicitly enabled.
        guard !silentMotivation else { return }
        if privateMotivation {
            let route = AVAudioSession.sharedInstance().currentRoute.outputs
            let privateOutput = route.contains { output in
                switch output.portType {
                case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return true
                default: return false
                }
            }
            guard privateOutput else { motivationStatus = "Connect headphones for private coaching"; return }
        }
        speaker.speak(AVSpeechUtterance(string: phrase))
    }
    func cue() {
        guard voiceCues, let active = clock.active else { return }
        let utterance = AVSpeechUtterance(string: active.kind == .run ? "Run now" : "Walk now")
        utterance.rate = 0.5
        speaker.speak(utterance)
    }
    func sendState() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext([
            "elapsed": seconds, "running": running, "speed": speedKmh, "distanceKm": accumulatedDistanceKm,
            "unit": units.rawValue, "interval": clock.active?.kind.rawValue ?? "complete"
        ])
    }
}
struct PhoneHomeView: View {
    @StateObject private var model = PhoneRunModel()
    var body: some View {
        NavigationStack {
            Form {
                Section("10K training") {
                    Picker("Session", selection: $model.selected) {
                        ForEach(TrainingLibrary.sessions) { s in
                            Text(s.title).tag(s.id)
                        }
                    }
                    Text("Session \(model.selected) of 42")
                    Text("Elapsed: \(model.seconds / 60)m \(model.seconds % 60)s")
                    Text(model.clock.active.map { "\($0.kind.rawValue.capitalized) — \($0.remaining)s left" } ?? "Complete")
                    HStack {
                        Button(model.running ? "Pause" : "Start / Resume") { model.startPause() }
                        Button("Reset") { model.reset() }
                    }
                }
                Section("Treadmill") {
                    HStack {
                        Text("Speed (km/h)")
                        Spacer()
                        TextField("Speed", value: $model.speedKmh, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    Picker("Units", selection: $model.units) {
                        ForEach(UnitPreference.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Text("Distance: \(model.units.distance(model.accumulatedDistanceKm), specifier: "%.2f") \(model.units.distanceLabel)")
                    if let pace = RunEstimate.paceMinutesPerKm(speedKmh: model.speedKmh) {
                        Text("Pace: \(model.units.pace(pace), specifier: "%.2f") min/\(model.units.distanceLabel)")
                    }
                    Text("Distance is calculated from the manually entered treadmill speed, not read from the machine.")
                        .font(.caption)
                }
                Section("Forest mode") {
                    Toggle("Forest scenery", isOn: $model.forest)
                    if model.forest {
                        ForestPlayerView(filename: model.videoName)
                        TextField("Bundled video filename (without .mp4)", text: $model.videoName)
                        Text("To play offline, add a properly licensed forest.mp4 to the iPhone app target and enter forest.")
                            .font(.caption)
                    }
                    Toggle("Brief neutral interval voice cues", isOn: $model.voiceCues)
                    Toggle("Keep motivation private", isOn: $model.privateMotivation)
                    Toggle("Enable motivational buttons", isOn: $model.motivationEnabled)
                    Toggle("Disable motivational audio", isOn: $model.silentMotivation)
                    if !model.forest {
                        HStack {
                            Button("Motivate Me") { model.motivate("motivate") }
                            Button("Push Me") { model.motivate("push") }
                        }
                    }
                    if !model.motivationStatus.isEmpty { Text(model.motivationStatus).font(.caption) }
                }
                Section("After your run") {
                    TextField("Treadmill final distance (optional, in selected units)", text: $model.treadmillFinalDistance)
                        .keyboardType(.decimalPad)
                    Button("Save run") { model.saveRun() }
                    if !model.saveMessage.isEmpty { Text(model.saveMessage).font(.caption) }
                    ForEach(model.savedRuns.prefix(5)) { run in
                        Text("Workout \(run.workoutNumber): \(model.units.distance(run.finalDistanceKm), specifier: "%.2f") \(model.units.distanceLabel)")
                    }
                    Text("Estimated VO₂ max: unavailable. A scientifically defensible per-treadmill-run VO₂ max estimate needs a validated model and calibration. This app does not invent a number.")
                        .font(.caption)
                }
            }.navigationTitle("TreadmillVO2")
        }
    }
}
struct ForestPlayerView: View {
    let filename: String
    @State private var player: AVPlayer?
    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player).frame(height: 180)
            } else {
                ContentUnavailableView("No forest video bundled", systemImage: "tree")
            }
        }
        .onAppear { load() }
        .onChange(of: filename) { _, _ in load() }
    }
    private func load() {
        guard !filename.isEmpty, let url = Bundle.main.url(forResource: filename, withExtension: "mp4") else {
            player = nil; return
        }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        p.play()
    }
}
