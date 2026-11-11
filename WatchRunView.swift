import SwiftUI
import HealthKit
import WatchConnectivity

@MainActor final class WatchRunModel: NSObject, ObservableObject, WCSessionDelegate, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    @Published var heartRate: Double?
    @Published var elapsed = 0
    @Published var distanceKm: Double = 0
    @Published var pace: Double?
    @Published var interval = "Ready"
    @Published var active = false
    @Published var units: UnitPreference = .kilometres
    @Published var permissionMessage: String?
    private let health = HKHealthStore()
    private var workout: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    override init() {
        super.init()
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in
            self.interval = context["interval"] as? String ?? self.interval
            self.elapsed = context["elapsed"] as? Int ?? self.elapsed
            self.units = UnitPreference(rawValue: context["unit"] as? String ?? "") ?? .kilometres
            let speed = context["speed"] as? Double ?? 0
            self.distanceKm = context["distanceKm"] as? Double ?? self.distanceKm
            self.pace = RunEstimate.paceMinutesPerKm(speedKmh: speed)
        }
    }
    func sendCoaching(_ kind: String) {
        guard WCSession.isSupported(), WCSession.default.isReachable else {
            permissionMessage = "Open the iPhone app for coaching"
            return
        }
        WCSession.default.sendMessage(["coaching": kind], replyHandler: nil) { [weak self] error in
            Task { @MainActor in self?.permissionMessage = error.localizedDescription }
        }
    }
    func requestAndStart() {
        guard HKHealthStore.isHealthDataAvailable() else { permissionMessage = "Health data unavailable"; return }
        let heart = HKObjectType.quantityType(forIdentifier: .heartRate)!
        let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!
        let workoutType = HKObjectType.workoutType()
        health.requestAuthorization(toShare: [workoutType], read: [heart, distance]) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.permissionMessage = error?.localizedDescription ?? "Health permission not granted"
                    return
                }
                self.startWorkout()
            }
        }
    }
    private func startWorkout() {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: health, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.workout = session
            self.builder = builder
            session.startActivity(with: Date())
            builder.beginCollection(withStart: Date()) { [weak self] success, error in
                Task { @MainActor in
                    self?.active = success
                    if let error { self?.permissionMessage = error.localizedDescription }
                }
            }
        } catch { permissionMessage = error.localizedDescription }
    }
    func stopWorkout() { workout?.end() }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended {
            Task { @MainActor in
                self.builder?.endCollection(withEnd: date) { [weak self] _, _ in
                    self?.builder?.finishWorkout { _, _ in }
                }
                self.active = false
            }
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.permissionMessage = error.localizedDescription }
    }
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor in
            guard let type = HKObjectType.quantityType(forIdentifier: .heartRate),
                  let statistics = self.builder?.statistics(for: type),
                  let quantity = statistics.mostRecentQuantity() else { return }
            self.heartRate = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        }
    }
    var zone: Int? { nil }
}
struct WatchRunView: View {
    @StateObject private var model = WatchRunModel()
    var body: some View {
        ScrollView {
            VStack(spacing: 5) {
                Text(model.heartRate.map { String(format: "%.0f BPM", $0) } ?? "— BPM").font(.title3.bold())
                Text(model.zone.map { "Zone \($0) of 5 (estimated)" } ?? "Zone —")
                Text(String(format: "%.2f %@", model.units.distance(model.distanceKm), model.units.distanceLabel))
                Text(model.pace.map { String(format: "%.2f min/%@", model.units.pace($0), model.units.distanceLabel) } ?? "— pace")
                Text("\(model.elapsed / 60):\(String(format: "%02d", model.elapsed % 60))")
                Text(model.interval.capitalized)
                Button(model.active ? "Stop Health workout" : "Start Health workout") {
                    if model.active { model.stopWorkout() } else { model.requestAndStart() }
                }
                Button("Motivate Me") { model.sendCoaching("motivate") }
                Button("Push Me") { model.sendCoaching("push") }
                if let error = model.permissionMessage { Text(error).font(.caption2) }
            }
        }
    }
}
