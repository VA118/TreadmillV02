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
    private let background = Color(red: 0.045, green: 0.05, blue: 0.065)
    private let panel = Color(red: 0.095, green: 0.105, blue: 0.125)
    private let accent = Color(red: 0.80, green: 0.13, blue: 0.17)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    workoutCard
                    treadmillCard
                    forestCard
                    historyCard
                    Text("TREADMILLVO2  •  TRAIN WITH PURPOSE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .padding(18)
            }
            .background(background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .tint(accent)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "figure.run")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(accent)
                Text("TREADMILL")
                    .foregroundStyle(.white)
                Text("VO2")
                    .foregroundStyle(accent)
                Spacer()
                Text("TRAINING / 01")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.gray)
            }
            .font(.system(size: 23, weight: .black, design: .rounded))
            Rectangle().fill(accent).frame(width: 44, height: 3)
            Text("YOUR PERFORMANCE. YOUR PROGRESS.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(.gray)
        }
        .padding(.bottom, 4)
    }

    private var workoutCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeading("10K TRAINING", symbol: "figure.run.circle")
                Picker("Training session", selection: $model.selected) {
                    ForEach(TrainingLibrary.sessions) { session in
                        Text(session.title).tag(session.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("SESSION \(model.selected) OF 42")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.gray)
                Text(String(format: "%02d:%02d", model.seconds / 60, model.seconds % 60))
                    .font(.system(size: 62, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                Text(model.clock.active.map { "\($0.kind.rawValue.uppercased())  •  \($0.remaining) SEC REMAINING" } ?? "SESSION COMPLETE")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 10) {
                    Button(action: { model.startPause() }) {
                        Label(model.running ? "PAUSE" : "START / RESUME", systemImage: model.running ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(WorkoutButtonStyle(color: accent))
                    Button(action: { model.reset() }) {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 46, height: 24)
                    }
                    .buttonStyle(WorkoutButtonStyle(color: Color(white: 0.22)))
                    .accessibilityLabel("Reset workout")
                }
            }
        }
    }

    private var treadmillCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeading("TREADMILL", symbol: "speedometer")
                HStack {
                    Text("SPEED  •  KM/H")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.gray)
                    Spacer()
                    TextField("Speed", value: $model.speedKmh, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .frame(width: 100)
                }
                Divider().overlay(Color.white.opacity(0.08))
                Picker("Units", selection: $model.units) {
                    ForEach(UnitPreference.allCases) { unit in
                        Text(unit.rawValue.capitalized).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 12) {
                    metric("DISTANCE", value: String(format: "%.2f", model.units.distance(model.accumulatedDistanceKm)), unit: model.units.distanceLabel)
                    if let pace = RunEstimate.paceMinutesPerKm(speedKmh: model.speedKmh) {
                        metric("PACE", value: String(format: "%.2f", model.units.pace(pace)), unit: "min/\(model.units.distanceLabel)")
                    } else {
                        metric("PACE", value: "--", unit: "min/\(model.units.distanceLabel)")
                    }
                }
                Text("Distance is estimated from the speed you enter, not read directly from your treadmill.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
        }
    }

    private var forestCard: some View {
        card {
            VStack(alignment: .leading, spacing: 13) {
                sectionHeading("EXPERIENCE & AUDIO", symbol: "waveform")
                Toggle("Forest scenery", isOn: $model.forest)
                if model.forest {
                    ForestPlayerView(filename: model.videoName)
                    TextField("Bundled video filename (without .mp4)", text: $model.videoName)
                        .textFieldStyle(.roundedBorder)
                    Text("Offline video requires a properly licensed MP4 bundled with the iPhone app.")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                Toggle("Neutral interval voice cues", isOn: $model.voiceCues)
                Toggle("Keep motivation private", isOn: $model.privateMotivation)
                Toggle("Enable motivation buttons", isOn: $model.motivationEnabled)
                Toggle("Disable motivational audio", isOn: $model.silentMotivation)
                if !model.forest {
                    HStack(spacing: 10) {
                        Button("MOTIVATE ME") { model.motivate("motivate") }
                        Button("PUSH ME") { model.motivate("push") }
                    }
                    .font(.system(size: 12, weight: .bold))
                    .buttonStyle(.bordered)
                }
                if !model.motivationStatus.isEmpty {
                    Text(model.motivationStatus).font(.caption).foregroundStyle(.gray)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: accent))
        }
    }

    private var historyCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeading("AFTER YOUR RUN", symbol: "chart.xyaxis.line")
                TextField("Final treadmill distance (optional)", text: $model.treadmillFinalDistance)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Button("SAVE RUN") { model.saveRun() }
                    .buttonStyle(WorkoutButtonStyle(color: accent))
                if !model.saveMessage.isEmpty {
                    Text(model.saveMessage).font(.caption).foregroundStyle(.gray)
                }
                if !model.savedRuns.isEmpty {
                    Text("RECENT RUNS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.gray)
                    ForEach(model.savedRuns.prefix(5)) { run in
                        HStack {
                            Text("Workout \(run.workoutNumber)")
                            Spacer()
                            Text(String(format: "%.2f %@", model.units.distance(run.finalDistanceKm), model.units.distanceLabel))
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
                Divider().overlay(Color.white.opacity(0.08))
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("VO₂ MAX  •  COMING LATER")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                        Text("A reliable treadmill VO₂ max estimate requires a validated model and calibration. No number is invented.")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }
            }
        }
    }

    private func sectionHeading(_ title: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(accent)
            Text(title)
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(.white)
            Spacer()
        }
    }

    private func metric(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.gray)
            Text(value)
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(unit).font(.caption2).foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

private struct WorkoutButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.vertical, 15)
            .padding(.horizontal, 16)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 11))
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
