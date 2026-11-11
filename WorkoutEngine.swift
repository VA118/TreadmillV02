import Foundation

enum IntervalKind: String, Codable { case run, walk }
struct WorkoutInterval: Codable {
    var kind: IntervalKind
    var seconds: Int
}
struct TrainingSession: Identifiable {
    let id: Int
    let title: String
    let intervals: [WorkoutInterval]
    var totalSeconds: Int { intervals.reduce(0) { $0 + $1.seconds } }
}
enum TrainingLibrary {
    // A configurable 42-session progression, not a clinically validated training prescription.
    static let sessions: [TrainingSession] = (1...42).map { day in
        let week = (day - 1) / 3
        let rounds = min(5 + week, 12)
        let run = min(60 + week * 15, 240)
        let walk = max(60, 120 - week * 5)
        let intervals = [WorkoutInterval(kind: .walk, seconds: 300)]
            + (0..<rounds).flatMap { _ in [
                WorkoutInterval(kind: .run, seconds: run),
                WorkoutInterval(kind: .walk, seconds: walk)
            ] } + [WorkoutInterval(kind: .walk, seconds: 300)]
        return TrainingSession(id: day, title: "Workout \(day)", intervals: intervals)
    }
}
struct IntervalClock {
    let intervals: [WorkoutInterval]
    var elapsed = 0
    var total: Int { intervals.reduce(0) { $0 + $1.seconds } }
    var active: (index: Int, kind: IntervalKind, remaining: Int)? {
        var offset = 0
        for (index, interval) in intervals.enumerated() {
            if elapsed < offset + interval.seconds {
                return (index, interval.kind, offset + interval.seconds - elapsed)
            }
            offset += interval.seconds
        }
        return nil
    }
    mutating func advance() { elapsed = min(total, elapsed + 1) }
}
enum UnitPreference: String, CaseIterable, Identifiable {
    case kilometres, miles
    var id: String { rawValue }
    var distanceLabel: String { self == .kilometres ? "km" : "mi" }
    func distance(_ km: Double) -> Double { self == .kilometres ? km : km / 1.609344 }
    func pace(_ minPerKm: Double) -> Double { self == .kilometres ? minPerKm : minPerKm * 1.609344 }
}
struct RunEstimate {
    // A treadmill speed manually entered by the runner is more appropriate than claiming GPS precision indoors.
    static func distanceKm(speedKmh: Double, elapsedSeconds: Int) -> Double {
        max(0, speedKmh) * Double(max(0, elapsedSeconds)) / 3600
    }
    static func paceMinutesPerKm(speedKmh: Double) -> Double? {
        speedKmh > 0 ? 60 / speedKmh : nil
    }
}

struct RunSummary: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = Date()
    var workoutNumber: Int
    var elapsedSeconds: Int
    var estimatedDistanceKm: Double
    var treadmillDistanceKm: Double?
    var finalDistanceKm: Double { treadmillDistanceKm ?? estimatedDistanceKm }
}
struct RunHistory {
    static func encode(_ runs: [RunSummary]) throws -> Data { try JSONEncoder().encode(runs) }
    static func decode(_ data: Data) throws -> [RunSummary] { try JSONDecoder().decode([RunSummary].self, from: data) }
}
