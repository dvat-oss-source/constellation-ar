import Foundation
import Testing
@testable import SkyCore

@Suite struct SatelliteParsingTests {
    static func unix(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
        return calendar.date(from: c)!.timeIntervalSince1970
    }

    @Test func epochParsingKeepsMicroseconds() throws {
        let base = Self.unix(2026, 10, 24, 12, 34, 56)
        let micro = try #require(OMMParser.parseEpoch("2026-10-24T12:34:56.123456"))
        #expect(abs(micro.timeIntervalSince1970 - (base + 0.123456)) < 1e-6)
        let none = try #require(OMMParser.parseEpoch("2026-10-24T12:34:56"))
        #expect(none.timeIntervalSince1970 == base)
        let short = try #require(OMMParser.parseEpoch("2026-10-24T12:34:56.1Z"))
        #expect(abs(short.timeIntervalSince1970 - (base + 0.1)) < 1e-6)
        let leapDay = try #require(OMMParser.parseEpoch("2024-02-29T00:00:00.000"))
        #expect(leapDay.timeIntervalSince1970 == Self.unix(2024, 2, 29, 0, 0, 0))
        #expect(OMMParser.parseEpoch("2026-13-01T00:00:00") == nil)
        #expect(OMMParser.parseEpoch("2026-10-24T25:00:00") == nil)
        #expect(OMMParser.parseEpoch("not a date") == nil)
        #expect(OMMParser.parseEpoch("2026-10-24T12:34:-5") == nil)
    }

    @Test func lenientArrayParsing() throws {
        let json = """
        [
          {"OBJECT_NAME":"ISS (ZARYA)","OBJECT_ID":"1998-067A","EPOCH":"2018-02-08T22:51:48.999744",
           "MEAN_MOTION":15.54072469,"ECCENTRICITY":0.0003401,"INCLINATION":51.6426,"RA_OF_ASC_NODE":297.9871,
           "ARG_OF_PERICENTER":86.7895,"MEAN_ANOMALY":100.1959,"EPHEMERIS_TYPE":0,"CLASSIFICATION_TYPE":"U",
           "NORAD_CAT_ID":25544,"ELEMENT_SET_NO":999,"REV_AT_EPOCH":9857,"BSTAR":3.2659e-5,
           "MEAN_MOTION_DOT":1.678e-5,"MEAN_MOTION_DDOT":0},
          {"OBJECT_NAME":"STRINGS","OBJECT_ID":"2000-001A","EPOCH":"2018-02-08T00:00:00.5",
           "MEAN_MOTION":"14.2","ECCENTRICITY":"0.001","INCLINATION":"98.1","RA_OF_ASC_NODE":"10",
           "ARG_OF_PERICENTER":"20","MEAN_ANOMALY":"30","EPHEMERIS_TYPE":"0","CLASSIFICATION_TYPE":"U",
           "NORAD_CAT_ID":"11111","ELEMENT_SET_NO":"999","REV_AT_EPOCH":"1","BSTAR":"0.0001"},
          {"OBJECT_NAME":"NO EPOCH","NORAD_CAT_ID":22222,"MEAN_MOTION":15,"ECCENTRICITY":0.001,"INCLINATION":50,
           "RA_OF_ASC_NODE":0,"ARG_OF_PERICENTER":0,"MEAN_ANOMALY":0,"BSTAR":0},
          {"OBJECT_NAME":"BAD NUMBER","NORAD_CAT_ID":33333,"EPOCH":"2018-02-08T00:00:00","MEAN_MOTION":"abc",
           "ECCENTRICITY":0.001,"INCLINATION":50,"RA_OF_ASC_NODE":0,"ARG_OF_PERICENTER":0,"MEAN_ANOMALY":0,"BSTAR":0},
          {"OBJECT_NAME":"HYPERBOLIC","NORAD_CAT_ID":44444,"EPOCH":"2018-02-08T00:00:00","MEAN_MOTION":15,
           "ECCENTRICITY":1.2,"INCLINATION":50,"RA_OF_ASC_NODE":0,"ARG_OF_PERICENTER":0,"MEAN_ANOMALY":0,"BSTAR":0},
          {"OBJECT_NAME":null,"OBJECT_ID":"2001-001B","NORAD_CAT_ID":55555,"EPOCH":"2018-02-08T00:00:00",
           "MEAN_MOTION":15,"ECCENTRICITY":0.001,"INCLINATION":50,"RA_OF_ASC_NODE":0,"ARG_OF_PERICENTER":0,
           "MEAN_ANOMALY":0,"BSTAR":null,"RCS_SIZE":null},
          {"OBJECT_NAME":"ISS NEWER","OBJECT_ID":"1998-067A","EPOCH":"2018-02-09T00:00:00",
           "MEAN_MOTION":15.54,"ECCENTRICITY":0.0003,"INCLINATION":51.64,"RA_OF_ASC_NODE":297,
           "ARG_OF_PERICENTER":86,"MEAN_ANOMALY":100,"NORAD_CAT_ID":25544,"BSTAR":3e-5},
          42
        ]
        """
        let result = try OMMParser.parse(Data(json.utf8))
        #expect(result.satellites.map(\.noradID) == [25544, 11111, 55555])
        #expect(result.satellite(noradID: 25544)?.name == "ISS NEWER")
        #expect(result.satellite(noradID: 11111)?.record.meanMotion == 14.2)
        #expect(result.satellite(noradID: 55555)?.name == "2001-001B")
        #expect(result.satellite(noradID: 55555)?.record.bstar == 0)
        let skippedIDs = Set(result.skipped.compactMap(\.noradID))
        #expect(skippedIDs == [22222, 33333, 44444, 25544])
        #expect(result.skipped.contains { $0.noradID == nil && $0.index == 7 })
        #expect(result.skipped.first { $0.noradID == 22222 }?.reason == "missing EPOCH")
    }

    @Test func singleObjectAndGarbage() throws {
        let record = try JSONEncoder().encode(SatelliteTestData.iss2018)
        #expect(try OMMParser.satellites(from: record).count == 1)
        #expect(throws: SatelliteError.notAnOMMArray) { try OMMParser.parse(Data("<html>No GP data found</html>".utf8)) }
        #expect(try OMMParser.parse(Data("[]".utf8)).satellites.isEmpty)
    }

    @Test func celesTrakURLs() {
        #expect(CelesTrak.issURL.absoluteString == "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=json")
        #expect(CelesTrak.visualGroupURL.query == "GROUP=visual&FORMAT=json")
        #expect(CelesTrak.groupURL("visual") == CelesTrak.visualGroupURL)
    }

    @Test func dataAge() throws {
        let sat = try TrackedSatellite(record: SatelliteTestData.iss2018)
        let fetched = sat.epoch.addingTimeInterval(3 * 3_600)
        let age = SatelliteDataAge(fetchedAt: fetched, satellites: [sat], now: fetched.addingTimeInterval(2 * 3_600))
        #expect(age.sinceFetch == 7_200)
        #expect(abs((age.newestElementAge ?? 0) - 5 * 3_600) < 1e-3)
        #expect(age.summary == "updated 2.0 h ago · elements 5.0 h old")
        #expect(SatelliteDataAge.formatDuration(30) == "30 s")
        #expect(SatelliteDataAge.formatDuration(600) == "10 min")
        #expect(SatelliteDataAge.formatDuration(3 * 86_400) == "3.0 d")
        #expect(abs(sat.elementAge(at: sat.epoch.addingTimeInterval(86_400)) - 86_400) < 1e-6)
    }
}

@Suite struct SatelliteCacheTests {
    actor Counter {
        var count = 0
        func increment() -> Int { count += 1; return count }
    }

    static let payload = try! JSONEncoder().encode([SatelliteTestData.iss2018])

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("skycore-satellite-cache-\(UUID().uuidString)")
    }

    @Test func policy() {
        let p = SatelliteCachePolicy()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(p.shouldFetch(lastSuccessfulFetch: nil, now: t))
        #expect(!p.shouldFetch(lastSuccessfulFetch: t, now: t.addingTimeInterval(3_600)))
        #expect(!p.shouldFetch(lastSuccessfulFetch: t, now: t.addingTimeInterval(86_399)))
        #expect(p.shouldFetch(lastSuccessfulFetch: t, now: t.addingTimeInterval(86_400)))
        #expect(p.shouldFetch(lastSuccessfulFetch: t, now: t.addingTimeInterval(-7_200)))
        #expect(!p.shouldFetch(lastSuccessfulFetch: t, lastFailedAttempt: t.addingTimeInterval(90_000),
                               now: t.addingTimeInterval(90_600)))
        #expect(p.shouldFetch(lastSuccessfulFetch: t, lastFailedAttempt: t.addingTimeInterval(90_000),
                              now: t.addingTimeInterval(92_000)))
        #expect(p.nextFetchDate(lastSuccessfulFetch: t) == t.addingTimeInterval(86_400))
    }

    @Test func fetchesAtMostOncePerDay() async throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = Counter()
        let store = SatelliteDataStore(cacheDirectory: dir) { _ in
            _ = await counter.increment()
            return Self.payload
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await store.load(CelesTrak.issURL, now: t0)
        #expect(first.origin == .network)
        #expect(first.iss != nil)
        #expect(first.fetchedAt == t0)

        for hours in [0.5, 6.0, 23.99] {
            let later = try await store.load(CelesTrak.issURL, now: t0.addingTimeInterval(hours * 3_600))
            #expect(later.origin == .cache)
            #expect(later.fetchedAt == t0)
        }
        #expect(await counter.count == 1)

        let nextDay = try await store.load(CelesTrak.issURL, now: t0.addingTimeInterval(86_401))
        #expect(nextDay.origin == .network)
        #expect(nextDay.fetchedAt == t0.addingTimeInterval(86_401))
        #expect(await counter.count == 2)

        let fresh = SatelliteDataStore(cacheDirectory: dir) { _ in throw URLError(.notConnectedToInternet) }
        #expect(fresh.cachedDataSet(for: CelesTrak.issURL, now: t0.addingTimeInterval(90_000))?.origin == .cache)
        #expect(fresh.cachedDataSet(for: CelesTrak.visualGroupURL, now: t0) == nil)
    }

    @Test func failuresFallBackToStaleCacheAndThrottle() async throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await SatelliteDataStore(cacheDirectory: dir) { _ in Self.payload }.load(CelesTrak.issURL, now: t0)

        let counter = Counter()
        let offline = SatelliteDataStore(cacheDirectory: dir) { _ in
            _ = await counter.increment()
            return Data("<html>rate limited</html>".utf8)
        }
        let stale = try await offline.load(CelesTrak.issURL, now: t0.addingTimeInterval(2 * 86_400))
        #expect(stale.origin == .staleCache)
        #expect(stale.fetchedAt == t0)
        #expect(await counter.count == 1)
        #expect(offline.metadata(for: CelesTrak.issURL)?.lastFailedAttempt == t0.addingTimeInterval(2 * 86_400))

        _ = try await offline.load(CelesTrak.issURL, now: t0.addingTimeInterval(2 * 86_400 + 600))
        #expect(await counter.count == 1)
        _ = try await offline.load(CelesTrak.issURL, now: t0.addingTimeInterval(2 * 86_400 + 3_600))
        #expect(await counter.count == 2)

        let emptyDir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: emptyDir) }
        let nothing = SatelliteDataStore(cacheDirectory: emptyDir) { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: URLError.self) { try await nothing.load(CelesTrak.issURL, now: t0) }
    }

    @Test func concurrentLoadsShareOneDownload() async throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = Counter()
        let store = SatelliteDataStore(cacheDirectory: dir) { _ in
            _ = await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return Self.payload
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        async let a = store.load(CelesTrak.issURL, now: t0)
        async let b = store.load(CelesTrak.issURL, now: t0)
        let (x, y) = try await (a, b)
        #expect(x.satellites.count == 1 && y.satellites.count == 1)
        #expect(await counter.count == 1)
    }
}
