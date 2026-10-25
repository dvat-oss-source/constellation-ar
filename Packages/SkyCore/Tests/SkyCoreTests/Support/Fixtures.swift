import Foundation
import simd
@testable import SkyCore

enum RepoFiles {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    static func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }

    static func decode<T: Decodable>(_ type: T.Type, _ relative: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url(relative)))
    }
}

/// Prints a measurement line that `swift test` output keeps (grep "SKYCORE").
func report(_ message: String) {
    print("SKYCORE \(message)")
}

func arcsec(_ radians: Double) -> Double { radians / Angle.radiansPerArcsecond }

struct FixtureObserver: Decodable {
    let name: String
    let lat: Double
    let lon: Double
    let height_m: Double
    var location: GeoLocation { GeoLocation(latitude: lat, longitude: lon, height: height_m) }
}

struct FixtureTime: Decodable {
    let utc: String
    let jd_utc: Double
    let jd_tt: Double
    let dut1: Double
    let delta_t: Double

    func instant(useDUT1: Bool) -> AstroInstant { AstroInstant(jdUTC: jd_utc, ut1MinusUTC: useDUT1 ? dut1 : 0) }
}

struct StarFixture: Decodable {
    struct Star: Decodable {
        let hip: Int
        let vmag: Double
        let catalog_icrs: [String: [Double]]
        let astrometric: [[Double]]
    }

    let observers: [FixtureObserver]
    let times: [FixtureTime]
    let stars: [Star]
    let results: [[Double]]
}

struct OrientationFixture: Decodable {
    struct Row: Decodable {
        let utc: String
        let jd_utc: Double
        let jd_tt: Double
        let dut1: Double
        let dpsi_arcsec: Double
        let deps_arcsec: Double
        let mean_obliquity_arcsec: Double
        let gmst_hours: Double
        let gast_hours: Double
        let icrs_to_true_of_date: [[Double]]
        let icrs_to_mean_of_date: [[Double]]
    }

    let rows: [Row]
}

struct HorizonsFixture: Decodable {
    struct Entry: Decodable {
        let body: String
        let time: Int
        let observer: Int
        let ra_deg: Double
        let dec_deg: Double
    }

    let observers: [FixtureObserver]
    let times: [FixtureTime]
    let entries: [Entry]
}

extension SIMD3 where Scalar == Double {
    init(_ a: [Double]) { self.init(a[0], a[1], a[2]) }
}

func matrix(rows: [[Double]]) -> simd_double3x3 {
    simd_double3x3(rows: rows.map { SIMD3($0) })
}

/// Largest rotation angle (radians) between two nearly equal rotation matrices.
func rotationAngle(_ a: simd_double3x3, _ b: simd_double3x3) -> Double {
    let r = a * b.transpose
    let c = (r[0][0] + r[1][1] + r[2][2] - 1) / 2
    let s = simd_length(SIMD3(r[1][2] - r[2][1], r[2][0] - r[0][2], r[0][1] - r[1][0])) / 2
    return atan2(s, c)
}

struct SplitMixRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func randomUnitVector<G: RandomNumberGenerator>(_ g: inout G) -> SIMD3<Double> {
    let z = Double.random(in: -1...1, using: &g)
    let phi = Double.random(in: 0..<(2 * .pi), using: &g)
    let r = (1 - z * z).squareRoot()
    return SIMD3(r * cos(phi), r * sin(phi), z)
}
