import Foundation
@testable import SkyCore

enum SatelliteTestData {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = repoRoot.appendingPathComponent("Data/fixtures")
    static let ommSnapshotPath = fixtures.appendingPathComponent("omm_snapshot.json").path
    static let passesPath = fixtures.appendingPathComponent("satellite_passes.json").path
    static let hasOMMSnapshot = FileManager.default.fileExists(atPath: ommSnapshotPath)
    static let hasPassFixtures = hasOMMSnapshot && FileManager.default.fileExists(atPath: passesPath)

    /// SatelliteKit's test TLE (1 25544U 98067A 18039.95265046 …) as OMM.
    static let iss2018 = OMMRecord(
        objectName: "ISS (ZARYA)", objectID: "1998-067A", epoch: "2018-02-08T22:51:48.999744",
        meanMotion: 15.54072469, eccentricity: 0.0003401, inclination: 51.6426, raOfAscendingNode: 297.9871,
        argumentOfPericenter: 86.7895, meanAnomaly: 100.1959, noradCatalogID: 25544, bstar: 3.2659e-5,
        revolutionAtEpoch: 9857)

    /// Vallado et al. (2006) SGP4 verification satellite 00005 (1 00005U 58002B 00179.78495062 …).
    static let vallado00005 = OMMRecord(
        objectName: "VANGUARD 1", objectID: "1958-002B", epoch: "2000-06-27T18:50:19.733568",
        meanMotion: 10.82419157, eccentricity: 0.1859667, inclination: 34.2682, raOfAscendingNode: 348.7242,
        argumentOfPericenter: 331.7664, meanAnomaly: 19.3264, noradCatalogID: 5, bstar: 2.8098e-5,
        revolutionAtEpoch: 41366)

    static func utc(_ text: String) -> Date? {
        var s = text
        if s.hasSuffix("+00:00") { s.removeLast(6) }
        return OMMParser.parseEpoch(s)
    }

    static func report(_ line: String) { print("SKYCORE satellite: \(line)") }
}

struct SatellitePassFixture: Decodable {
    struct Observer: Decodable {
        var name: String
        var lat: Double
        var lon: Double
        var heightM: Double

        var location: GeoLocation { GeoLocation(latitude: lat, longitude: lon, height: heightM) }
    }

    struct Pass: Decodable {
        var norad: Int
        var name: String?
        var observer: Int
        var riseJdUtc: Double
        var culminationJdUtc: Double
        var setJdUtc: Double
        var maxAltDeg: Double
        var sunlitAtCulmination: Bool?
        var sunAltAtCulminationDeg: Double?
    }

    struct Sample: Decodable {
        var norad: Int
        var observer: Int
        var jdUtc: Double
        var altDeg: Double
        var azDeg: Double
        var rangeKm: Double
        var sunlit: Bool
        var sunAltDeg: Double?
    }

    var startUtc: String
    var endUtc: String
    var horizonDeg: Double?
    var observers: [Observer]
    var passes: [Pass]
    var samples: [Sample]

    static func load() throws -> SatellitePassFixture {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: SatelliteTestData.passesPath)))
    }
}
