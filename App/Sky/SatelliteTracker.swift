import Foundation
import Observation
import SkyCore
import simd

/// ISS and bright-satellite positions from CelesTrak elements (downloaded at most once a day by `SatelliteDataStore`,
/// cached on disk). Positions are propagated once a second off the main actor and interpolated per frame.
@MainActor
@Observable
final class SatelliteTracker {
    struct Sample: Sendable {
        var noradID: Int
        var name: String
        var isISS: Bool
        /// Airless ENU at `Snapshot.date` and one second later.
        var enuNow: SIMD3<Double>
        var enuNext: SIMD3<Double>
        /// Sunlit, sky dark enough and above the horizon.
        var visible: Bool
        var sunlit: Bool
        var altitudeDegrees: Double
    }

    struct Snapshot: Sendable {
        var date: Date
        var samples: [Sample]
        var issPath: [SatelliteTrackPoint]
    }

    struct Status: Sendable {
        var summary: String
        var isStale: Bool
    }

    @ObservationIgnored private(set) var snapshot: Snapshot?
    private(set) var nextISSPass: SatellitePassSummary?
    private(set) var dataStatus: Status?
    private(set) var errorMessage: String?
    private(set) var issSample: Sample?

    @ObservationIgnored private let store: SatelliteDataStore
    @ObservationIgnored private var satellites: [TrackedSatellite] = []
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var passTask: Task<Void, Never>?
    @ObservationIgnored private var lastPassSearch: (date: Date, location: GeoLocation)?

    init(cacheDirectory: URL? = nil) {
        let base = cacheDirectory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                                     appropriateFor: nil, create: true))?
            .appendingPathComponent("Satellites", isDirectory: true) ?? FileManager.default.temporaryDirectory
        store = SatelliteDataStore(cacheDirectory: base)
    }

    /// `context` supplies the sky date and observer on each tick.
    func start(context: @escaping @MainActor () -> (date: Date, location: GeoLocation)?) {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.loadElements()
            while !Task.isCancelled {
                if let self, let (date, location) = context(), !self.satellites.isEmpty {
                    let satellites = self.satellites
                    let snapshot = await Task.detached(priority: .utility) {
                        Self.propagate(satellites, at: date, location: location)
                    }.value
                    self.snapshot = snapshot
                    self.issSample = snapshot.samples.first(where: \.isISS)
                    self.searchPassIfNeeded(date: date, location: location)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func loadElements() async {
        do {
            var set = try await store.load(CelesTrak.visualGroupURL, now: Date())
            if set.iss == nil, let stations = try? await store.load(CelesTrak.stationsGroupURL, now: Date()) {
                set.satellites += stations.satellites.filter { new in !set.satellites.contains { $0.noradID == new.noradID } }
            }
            satellites = set.satellites
            let age = set.age(now: Date())
            let origin = switch set.origin {
            case .network: "downloaded just now"
            case .cache: "cached"
            case .staleCache: "cached, older than a day (offline?)"
            }
            dataStatus = Status(summary: "\(age.summary) (\(origin))", isStale: set.origin == .staleCache)
            errorMessage = nil
        } catch {
            errorMessage = "Satellite data unavailable: \(error)"
        }
    }

    /// The pass search scans days of orbit; redo it every ten minutes of sky time or after a large move.
    private func searchPassIfNeeded(date: Date, location: GeoLocation) {
        if passTask != nil { return }
        if let last = lastPassSearch, abs(date.timeIntervalSince(last.date)) < 600,
           abs(last.location.latitude - location.latitude) < 0.5, abs(last.location.longitude - location.longitude) < 0.5 {
            return
        }
        lastPassSearch = (date, location)
        let satellites = satellites
        passTask = Task { [weak self] in
            let summary = await Task.detached(priority: .utility) {
                try? SatellitePassPredictor().nextISSPassSummary(satellites: satellites, location: location, now: date)
            }.value
            self?.nextISSPass = summary
            self?.passTask = nil
        }
    }

    nonisolated private static func propagate(_ satellites: [TrackedSatellite], at date: Date, location: GeoLocation) -> Snapshot {
        let observer = SatelliteObserver(location: location)
        let instant = AstroInstant(date: date)
        let next = instant.adding(seconds: 1)
        var samples: [Sample] = []
        var issPath: [SatelliteTrackPoint] = []
        for satellite in satellites {
            guard let position = try? satellite.topocentric(at: instant, observer: observer) else { continue }
            guard position.altitudeDegrees > -1 || satellite.isISS else { continue }
            guard let observation = try? satellite.observation(at: instant, observer: observer),
                  let later = try? satellite.topocentric(at: next, observer: observer) else { continue }
            samples.append(Sample(noradID: satellite.noradID, name: satellite.name, isISS: satellite.isISS,
                                  enuNow: position.enu, enuNext: later.enu,
                                  visible: observation.isVisible(minimumAltitudeDegrees: 0), sunlit: observation.isSunlit,
                                  altitudeDegrees: position.altitudeDegrees))
            if satellite.isISS { issPath = (try? satellite.predictedPath(observer: observer, around: instant)) ?? [] }
        }
        return Snapshot(date: date, samples: samples, issPath: issPath)
    }

    /// Position at `date` by interpolating the last propagation; nil if the snapshot is too old for that date.
    func enu(of sample: Sample, at date: Date) -> SIMD3<Double>? {
        guard let snapshot, abs(date.timeIntervalSince(snapshot.date)) < 4 else { return nil }
        let f = date.timeIntervalSince(snapshot.date)
        return simd_normalize(sample.enuNow + (sample.enuNext - sample.enuNow) * f)
    }
}
