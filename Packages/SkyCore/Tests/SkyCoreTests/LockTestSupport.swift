import Foundation
import simd
@testable import SkyCore

typealias LockRNG = SkyCore.SplitMix64

enum LockTestData {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    static func dataURL(_ name: String) -> URL {
        repoRoot.appendingPathComponent("Data").appendingPathComponent(name)
    }

    static func has(_ names: String...) -> Bool {
        names.allSatisfy { FileManager.default.fileExists(atPath: dataURL($0).path) }
    }

    static let hasFigures = has("stars.bin", "lines.json")
    static let hasSky = has("stars.bin", "lines.json", "roman1875.json")

    static let catalog: StarCatalog? = try? StarCatalog(url: dataURL("stars.bin"))
    static let lines: ConstellationLines? = try? ConstellationLines(url: dataURL("lines.json"))
    static let roman: RomanLookup? = try? RomanLookup(url: dataURL("roman1875.json"))

    static let scorer: ConstellationScorer? = {
        guard let catalog, let lines else { return nil }
        return ConstellationScorer(lines: lines, catalog: catalog)
    }()

    static let schedules: [String: DrawInSchedule] = {
        guard let catalog, let lines else { return [:] }
        return DrawInSchedule.all(lines: lines, catalog: catalog)
    }()

    static let observer = GeoLocation(latitude: 40, longitude: -105, height: 1600)
    static let sweepInstant = AstroInstant(date: ISO8601DateFormatter().date(from: "2027-01-15T05:00:00Z")!)
    static let session = SkySession(epoch: sweepInstant, location: observer)

    static let intrinsics = CameraIntrinsics.fieldOfView(horizontalDegrees: 60, bufferWidth: 1920, bufferHeight: 1080)
    static let mapping = ScreenMapping.portraitAspectFill(bufferWidth: 1920, bufferHeight: 1080,
                                                          viewWidth: 390, viewHeight: 844)

    static func projector(looking forward: SIMD3<Double>, up: SIMD3<Double> = SIMD3(0, 0, 1)) -> Projector {
        Projector(pose: .looking(at: forward, up: up), intrinsics: intrinsics, mapping: mapping)
    }

    /// `v` rotated by `angle` radians about unit `axis`.
    static func rotate(_ v: SIMD3<Double>, about axis: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
        simd_quatd(angle: angle, axis: simd_normalize(axis)).act(v)
    }

    /// Point `angle` radians from unit `from` along the great circle toward `toward`.
    static func move(_ from: SIMD3<Double>, toward: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
        let axis = simd_cross(from, toward)
        return simd_normalize(rotate(from, about: axis, by: angle))
    }

    static func slerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        let theta = Angle.separation(a, b)
        guard theta > 1e-12 else { return a }
        return simd_normalize((sin((1 - t) * theta) * a + sin(t * theta) * b) / sin(theta))
    }

    static func uniform(_ range: ClosedRange<Double>, _ g: inout LockRNG) -> Double {
        Double.random(in: range, using: &g)
    }

    /// Values that are not finite or fall outside 0...1, described for failure messages.
    static func unitRangeViolations(_ visuals: [ConstellationVisual]) -> [String] {
        var bad: [String] = []
        func check(_ x: Double, _ what: @autoclosure () -> String) {
            if !(x.isFinite && x >= 0 && x <= 1) { bad.append("\(what())=\(x)") }
        }
        for v in visuals {
            check(v.highlight, "\(v.id).highlight")
            check(v.label, "\(v.id).label")
            check(v.artwork, "\(v.id).artwork")
            for s in v.stars { check(s.alpha, "\(v.id).star\(s.hip)") }
            for s in v.segments {
                check(s.progress, "\(v.id).seg\(s.index).progress")
                check(s.alpha, "\(v.id).seg\(s.index).alpha")
                check(s.glow, "\(v.id).seg\(s.index).glow")
                check(s.glowPosition, "\(v.id).seg\(s.index).glowPosition")
            }
        }
        return bad
    }
}
