import Foundation

public enum CelesTrak {
    public static let issNoradID = 25544
    /// ~150 naked-eye satellites, including the ISS.
    public static let visualGroupURL = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=visual&FORMAT=json")!
    public static let stationsGroupURL = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=stations&FORMAT=json")!
    public static var issURL: URL { catalogURL(noradID: issNoradID) }

    public static func catalogURL(noradID: Int) -> URL {
        URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=\(noradID)&FORMAT=json")!
    }

    public static func groupURL(_ group: String) -> URL? {
        var components = URLComponents(string: "https://celestrak.org/NORAD/elements/gp.php")
        components?.queryItems = [URLQueryItem(name: "GROUP", value: group), URLQueryItem(name: "FORMAT", value: "json")]
        return components?.url
    }
}

/// Network policy for element sets: at most one successful download per `maximumAge` (CelesTrak updates GP data a
/// few times a day and throttles clients that poll more often), and no retry sooner than `retryInterval` after a
/// failed attempt.
public struct SatelliteCachePolicy: Sendable, Hashable, Codable {
    public var maximumAge: TimeInterval
    public var retryInterval: TimeInterval
    /// A cache stamped further than this in the future (device clock moved back) counts as stale.
    public var clockSkewTolerance: TimeInterval

    public init(maximumAge: TimeInterval = 86_400, retryInterval: TimeInterval = 1_800, clockSkewTolerance: TimeInterval = 3_600) {
        self.maximumAge = maximumAge
        self.retryInterval = retryInterval
        self.clockSkewTolerance = clockSkewTolerance
    }

    public func isFresh(fetchedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age < maximumAge && age > -clockSkewTolerance
    }

    public func shouldFetch(lastSuccessfulFetch: Date?, lastFailedAttempt: Date? = nil, now: Date) -> Bool {
        if let fetched = lastSuccessfulFetch, isFresh(fetchedAt: fetched, now: now) { return false }
        if let failed = lastFailedAttempt {
            let sinceFailure = now.timeIntervalSince(failed)
            if sinceFailure < retryInterval && sinceFailure > -clockSkewTolerance { return false }
        }
        return true
    }

    public func nextFetchDate(lastSuccessfulFetch: Date) -> Date { lastSuccessfulFetch.addingTimeInterval(maximumAge) }
}

/// How old the downloaded data and its element sets are, for display ("updated 3 h ago · elements 1.2 d old").
public struct SatelliteDataAge: Sendable, Hashable, Codable {
    public var fetchedAt: Date
    public var newestElementEpoch: Date?
    public var oldestElementEpoch: Date?
    public var now: Date

    public init(fetchedAt: Date, newestElementEpoch: Date?, oldestElementEpoch: Date?, now: Date) {
        self.fetchedAt = fetchedAt
        self.newestElementEpoch = newestElementEpoch
        self.oldestElementEpoch = oldestElementEpoch
        self.now = now
    }

    public init(fetchedAt: Date, satellites: [TrackedSatellite], now: Date) {
        let epochs = satellites.map(\.epoch)
        self.init(fetchedAt: fetchedAt, newestElementEpoch: epochs.max(), oldestElementEpoch: epochs.min(), now: now)
    }

    public var sinceFetch: TimeInterval { now.timeIntervalSince(fetchedAt) }
    /// Age of the freshest element set; SGP4 errors grow to ~1–2 km/day for LEO beyond a few days.
    public var newestElementAge: TimeInterval? { newestElementEpoch.map { now.timeIntervalSince($0) } }
    public var oldestElementAge: TimeInterval? { oldestElementEpoch.map { now.timeIntervalSince($0) } }

    public var summary: String {
        var text = "updated \(Self.formatDuration(sinceFetch)) ago"
        if let age = newestElementAge { text += " · elements \(Self.formatDuration(age)) old" }
        return text
    }

    /// "45 s", "12 min", "3.4 h", "2.1 d" (negative durations are shown as their magnitude).
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = abs(seconds)
        if s < 90 { return "\(Int(s.rounded())) s" }
        if s < 5_400 { return "\(Int((s / 60).rounded())) min" }
        if s < 172_800 { return String(format: "%.1f h", s / 3_600) }
        return String(format: "%.1f d", s / 86_400)
    }
}

public struct SatelliteCacheMetadata: Sendable, Hashable, Codable {
    public var source: URL
    public var fetchedAt: Date?
    public var lastFailedAttempt: Date?
    public var lastError: String?
}

public struct SatelliteDataSet: Sendable {
    public enum Origin: String, Sendable, Hashable, Codable {
        /// Downloaded during this call.
        case network
        /// Fresh cache; no download needed.
        case cache
        /// Cache past `maximumAge` (download failed or was throttled).
        case staleCache
    }

    public var satellites: [TrackedSatellite]
    public var source: URL
    public var fetchedAt: Date
    public var origin: Origin
    public var skippedRecordCount: Int

    public func age(now: Date) -> SatelliteDataAge { SatelliteDataAge(fetchedAt: fetchedAt, satellites: satellites, now: now) }
    public func satellite(noradID: Int) -> TrackedSatellite? { satellites.first { $0.noradID == noradID } }
    public var iss: TrackedSatellite? { satellite(noradID: CelesTrak.issNoradID) }
}

/// File cache of CelesTrak OMM JSON with a once-a-day download policy. Time is injected (`now`) and the network is
/// a replaceable closure, so the policy is testable offline.
public actor SatelliteDataStore {
    public typealias Fetcher = @Sendable (URL) async throws -> Data

    public static let urlSessionFetcher: Fetcher = { url in
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SatelliteError.httpStatus(http.statusCode)
        }
        return data
    }

    public nonisolated let cacheDirectory: URL
    public nonisolated let policy: SatelliteCachePolicy
    private let fetcher: Fetcher
    private var inFlight: [URL: Task<SatelliteDataSet, any Error>] = [:]

    public init(cacheDirectory: URL, policy: SatelliteCachePolicy = SatelliteCachePolicy(),
                fetcher: @escaping Fetcher = SatelliteDataStore.urlSessionFetcher) {
        self.cacheDirectory = cacheDirectory
        self.policy = policy
        self.fetcher = fetcher
    }

    public nonisolated func cacheFileURL(for source: URL) -> URL {
        let key = (source.query ?? source.lastPathComponent).map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return cacheDirectory.appendingPathComponent("omm_\(String(key)).json")
    }

    nonisolated func metadataURL(for source: URL) -> URL {
        cacheFileURL(for: source).deletingPathExtension().appendingPathExtension("meta.json")
    }

    public nonisolated func metadata(for source: URL) -> SatelliteCacheMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(for: source)) else { return nil }
        return try? JSONDecoder().decode(SatelliteCacheMetadata.self, from: data)
    }

    /// Cached data without touching the network (nil when nothing usable is cached).
    public nonisolated func cachedDataSet(for source: URL, now: Date) -> SatelliteDataSet? {
        guard let meta = metadata(for: source), let fetchedAt = meta.fetchedAt,
              let data = try? Data(contentsOf: cacheFileURL(for: source)),
              let parsed = try? OMMParser.parse(data), !parsed.satellites.isEmpty else { return nil }
        return SatelliteDataSet(satellites: parsed.satellites, source: source, fetchedAt: fetchedAt,
                                origin: policy.isFresh(fetchedAt: fetchedAt, now: now) ? .cache : .staleCache,
                                skippedRecordCount: parsed.skipped.count)
    }

    /// Returns the cache when it is younger than `policy.maximumAge`; otherwise downloads (at most once per call
    /// burst), falling back to the stale cache when the download fails. Throws only if there is nothing to return.
    public func load(_ source: URL, now: Date) async throws -> SatelliteDataSet {
        if let task = inFlight[source] { return try await task.value }
        let task = Task { try await self.performLoad(source, now: now) }
        inFlight[source] = task
        defer { inFlight[source] = nil }
        return try await task.value
    }

    private func performLoad(_ source: URL, now: Date) async throws -> SatelliteDataSet {
        let cached = cachedDataSet(for: source, now: now)
        var meta = metadata(for: source) ?? SatelliteCacheMetadata(source: source)
        let lastSuccess = cached == nil ? nil : meta.fetchedAt
        guard policy.shouldFetch(lastSuccessfulFetch: lastSuccess, lastFailedAttempt: meta.lastFailedAttempt, now: now) else {
            if let cached { return cached }
            throw SatelliteError.noUsableSatellites
        }
        do {
            let data = try await fetcher(source)
            let parsed = try OMMParser.parse(data)
            guard !parsed.satellites.isEmpty else { throw SatelliteError.noUsableSatellites }
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: cacheFileURL(for: source), options: .atomic)
            meta = SatelliteCacheMetadata(source: source, fetchedAt: now, lastFailedAttempt: nil, lastError: nil)
            try writeMetadata(meta, for: source)
            return SatelliteDataSet(satellites: parsed.satellites, source: source, fetchedAt: now, origin: .network,
                                    skippedRecordCount: parsed.skipped.count)
        } catch {
            meta.lastFailedAttempt = now
            meta.lastError = "\(error)"
            try? writeMetadata(meta, for: source)
            if let cached { return cached }
            throw error
        }
    }

    private func writeMetadata(_ meta: SatelliteCacheMetadata, for source: URL) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(meta).write(to: metadataURL(for: source), options: .atomic)
    }
}
