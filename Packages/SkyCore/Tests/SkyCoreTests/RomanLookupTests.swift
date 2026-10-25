import Foundation
import Testing
import simd
@testable import SkyCore

/// VI/49 boundary polygons (B1875) with the containment rule documented in Data/test/vi49_bounds.json.
struct VI49Boundaries {
    struct File: Decodable {
        struct Constellation: Decodable {
            struct Polygon: Decodable {
                let enclosesPole: String?
                let vertices: [[Double]]
            }
            let id: String
            let polygons: [Polygon]
        }
        let constellations: [Constellation]
    }

    struct ParallelEdge {
        let polygon: Int
        let dec: Double
        let raStart: Double
        let width: Double
        func contains(ra: Double) -> Bool {
            var d = (ra - raStart).truncatingRemainder(dividingBy: 24)
            if d < 0 { d += 24 }
            return d < width
        }
    }

    struct MeridianEdge {
        let ra: Double
        let decLow: Double
        let decHigh: Double
    }

    var polygonIDs: [String] = []
    var polygonNorth: [Bool] = []
    var parallel: [ParallelEdge] = []
    var meridian: [MeridianEdge] = []
    var parallelByRABin: [[Int]] = Array(repeating: [], count: 240)
    var parallelByDecBin: [[Int]] = Array(repeating: [], count: 180)
    var meridianByDecBin: [[Int]] = Array(repeating: [], count: 180)

    init(url: URL) throws {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        for c in file.constellations {
            for p in c.polygons {
                let index = polygonIDs.count
                polygonIDs.append(c.id)
                polygonNorth.append(p.enclosesPole == "N")
                for k in 0..<(p.vertices.count - 1) {
                    let a = p.vertices[k], b = p.vertices[k + 1]
                    if a[1] == b[1] && a[0] != b[0] {
                        var w = (b[0] - a[0]).truncatingRemainder(dividingBy: 24)
                        if w < 0 { w += 24 }
                        let (start, width) = w <= 12 ? (a[0], w) : (b[0], 24 - w)
                        parallel.append(ParallelEdge(polygon: index, dec: a[1], raStart: start, width: width))
                    } else if a[0] == b[0] && a[1] != b[1] {
                        meridian.append(MeridianEdge(ra: a[0], decLow: min(a[1], b[1]), decHigh: max(a[1], b[1])))
                    }
                }
            }
        }
        for (i, e) in parallel.enumerated() {
            let first = Int(e.raStart * 10), count = Int((e.width * 10).rounded(.up)) + 1
            for k in 0...count { parallelByRABin[(first + k) % 240].append(i) }
        }
        let margin = 0.2
        func decBins(_ lo: Double, _ hi: Double) -> ClosedRange<Int> {
            max(0, Int((lo - margin + 90).rounded(.down)))...min(179, Int((hi + margin + 90).rounded(.down)))
        }
        for (i, e) in parallel.enumerated() { for b in decBins(e.dec, e.dec) { parallelByDecBin[b].append(i) } }
        for (i, e) in meridian.enumerated() { for b in decBins(e.decLow, e.decHigh) { meridianByDecBin[b].append(i) } }
    }

    func constellations(raHours ra: Double, dec: Double) -> [String] {
        var parity = [Bool](repeating: false, count: polygonIDs.count)
        for i in parallelByRABin[min(239, Int(ra * 10))] {
            let e = parallel[i]
            if e.dec > dec && e.contains(ra: ra) { parity[e.polygon].toggle() }
        }
        var result: [String] = []
        for (i, p) in parity.enumerated() where p != polygonNorth[i] { result.append(polygonIDs[i]) }
        return result
    }

    /// True if (ra, dec) lies within `margin` degrees of any boundary edge.
    func isNearBoundary(raHours ra: Double, dec: Double, margin: Double) -> Bool {
        if abs(dec) > 90 - margin { return true }
        let bin = Int((dec + 90).rounded(.down))
        let cosDec = cos(Angle.radians(dec))
        for i in meridianByDecBin[min(179, bin)] {
            let e = meridian[i]
            guard dec >= e.decLow - margin && dec <= e.decHigh + margin else { continue }
            let dra = Angle.wrapPi(Angle.radians((ra - e.ra) * 15))
            if Angle.degrees(asin(min(1, abs(sin(dra)) * cosDec))) < margin && abs(dra) < .pi / 2 { return true }
        }
        for i in parallelByDecBin[min(179, bin)] {
            let e = parallel[i]
            guard abs(dec - e.dec) < margin else { continue }
            let expand = min(12, margin / 15 / max(cos(Angle.radians(e.dec)), 1e-6))
            var d = (ra - (e.raStart - expand)).truncatingRemainder(dividingBy: 24)
            if d < 0 { d += 24 }
            if d < e.width + 2 * expand { return true }
        }
        return false
    }
}

@Suite struct RomanLookupTests {
    static let romanPath = "Data/roman1875.json"
    static let vi49Path = "Data/test/vi49_bounds.json"

    @Test(.enabled(if: RepoFiles.exists(romanPath)))
    func tableHas357Rows() throws {
        let roman = try RomanLookup(url: RepoFiles.url(Self.romanPath))
        #expect(roman.rows.count == 357)
        #expect(Set(roman.rows.map(\.constellation)).count == 88)
    }

    @Test(.enabled(if: RepoFiles.exists(romanPath) && RepoFiles.exists("Data/stars.bin")))
    func betelgeuseIsInOrionAndOtherLandmarks() throws {
        let roman = try RomanLookup(url: RepoFiles.url(Self.romanPath))
        let cat = try StarCatalog(url: RepoFiles.url("Data/stars.bin"))
        let expected: [Int: String] = [27989: "Ori", 24436: "Ori", 32349: "CMa", 11767: "UMi", 91262: "Lyr",
                                       71683: "Cen", 104382: "Oct", 54061: "UMa", 3179: "Cas", 69673: "Boo"]
        for (hip, id) in expected {
            let star = try #require(cat.star(hip: hip), "HIP \(hip) missing from stars.bin")
            #expect(roman.constellation(icrs: star.directionDouble) == id, "HIP \(hip)")
        }
    }

    @Test(.enabled(if: RepoFiles.exists(romanPath) && RepoFiles.exists(vi49Path)))
    func agreesWithVI49PolygonsOnRandomPoints() throws {
        let roman = try RomanLookup(url: RepoFiles.url(Self.romanPath))
        let bounds = try VI49Boundaries(url: RepoFiles.url(Self.vi49Path))
        var g = SplitMixRNG(seed: 1875)
        let target = 100_000
        var accepted = 0, excluded = 0, disagreements = 0, multiple = 0, viaICRSMismatch = 0
        var examples: [String] = []
        while accepted < target {
            let v = randomUnitVector(&g)
            let (lon, lat) = v.lonLat
            let ra = Angle.degrees(lon) / 15, dec = Angle.degrees(lat)
            if bounds.isNearBoundary(raHours: ra, dec: dec, margin: 0.1) { excluded += 1; continue }
            accepted += 1
            let poly = bounds.constellations(raHours: ra, dec: dec)
            if poly.count != 1 { multiple += 1 }
            let table = roman.constellation(raHours1875: ra, decDegrees1875: dec)
            if poly.first != table || poly.count != 1 {
                disagreements += 1
                if examples.count < 5 { examples.append(String(format: "ra %.4fh dec %.4f: VI/42 %@ VI/49 %@", ra, dec, table ?? "nil", poly.joined(separator: ","))) }
            }
            if roman.constellation(icrs: roman.toB1875.transpose * v) != table { viaICRSMismatch += 1 }
        }
        report("Roman VI/42 vs VI/49 polygons: \(accepted) points (\(excluded) within 0.1 deg of a boundary skipped), disagreements \(disagreements), non-unique polygon hits \(multiple), ICRS-path mismatches \(viaICRSMismatch) \(examples)")
        #expect(disagreements == 0)
        #expect(viaICRSMismatch == 0)
    }
}
