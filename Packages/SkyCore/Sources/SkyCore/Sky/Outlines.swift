import Foundation
import simd

/// `[raDeg, decDeg]` pair (ICRS/J2000) → unit vector.
@inlinable func icrsVector(_ p: [Double]) -> SIMD3<Double> {
    .unit(lon: Angle.radians(p[0]), lat: Angle.radians(p[1]))
}

public struct Asterism: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    /// 1 = most prominent … 6 = star-hopping pointer lines.
    public var priority: Int
    public var label: [Double]?
    /// Polylines of [raDeg, decDeg].
    public var lines: [[[Double]]]

    public var polylines: [[SIMD3<Double>]] { lines.map { $0.map(icrsVector) } }
    public var labelDirection: SIMD3<Double>? { label.map(icrsVector) }
}

/// `Data/asterisms.json`.
public struct AsterismCatalog: Sendable, Codable {
    public var version: Int
    public var source: String?
    public var asterisms: [Asterism]

    public init(url: URL) throws { self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
}

extension Projector {
    /// Screen polylines for ICRS polylines; `icrsToENU` from `SkySession.icrsToENU(at:)`.
    public func project(icrsPolylines: [[SIMD3<Double>]], icrsToENU: simd_double3x3,
                        refraction: Refraction? = .standard, guardBand: Double = 64) -> [[SIMD2<Double>]] {
        icrsPolylines.flatMap { line in
            clipPolyline(line.map { v in
                let enu = icrsToENU * v
                return refraction?.apparent(enu: enu) ?? enu
            }, guardBand: guardBand)
        }
    }
}

/// `Data/milkyway.json`: nested brightness levels of closed RA/Dec rings with an even-odd membership rule
/// (a ray due north along the meridian; edges linear in RA/Dec along the shorter RA direction).
public struct MilkyWay: Sendable, Codable {
    public struct Level: Sendable, Codable {
        public var level: Int
        /// Closed rings of [raDeg, decDeg].
        public var polygons: [[[Double]]]
    }

    public let version: Int
    public let source: String?
    public let levels: [Level]
    private let edgeTable: [[Edge]]

    enum CodingKeys: String, CodingKey { case version, source, levels }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        levels = try c.decode([Level].self, forKey: .levels)
        edgeTable = levels.map(Self.edges(of:))
    }

    public init(url: URL) throws { self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }

    /// Rings as ICRS unit vectors per level, for near-plane clipping with `Projector.clipPolygon`.
    public var ringsByLevel: [(level: Int, rings: [[SIMD3<Double>]])] {
        levels.map { ($0.level, $0.polygons.map { $0.map(icrsVector) }) }
    }

    struct Edge {
        let raStart: Double
        let width: Double
        let decStart: Double
        let decEnd: Double

        func crossingDec(atRA ra: Double) -> Double? {
            var d = (ra - raStart).truncatingRemainder(dividingBy: 360)
            if d < 0 { d += 360 }
            guard d < width else { return nil }
            return decStart + (decEnd - decStart) * (d / width)
        }
    }

    private static func edges(of level: Level) -> [Edge] {
        var result: [Edge] = []
        for ring in level.polygons where ring.count > 1 {
            for k in 0..<ring.count {
                let a = ring[k], b = ring[(k + 1) % ring.count]
                if a[0] == b[0] && a[1] == b[1] { continue }
                var w = (b[0] - a[0]).truncatingRemainder(dividingBy: 360)
                if w < 0 { w += 360 }
                if w == 0 { continue }
                if w <= 180 {
                    result.append(Edge(raStart: a[0], width: w, decStart: a[1], decEnd: b[1]))
                } else {
                    result.append(Edge(raStart: b[0], width: 360 - w, decStart: b[1], decEnd: a[1]))
                }
            }
        }
        return result
    }

    /// Highest level (0 = outside the Milky Way) containing an ICRS direction.
    public func level(at icrs: SIMD3<Double>) -> Int {
        let (lon, lat) = icrs.lonLat
        return level(raDegrees: Angle.degrees(lon), decDegrees: Angle.degrees(lat))
    }

    /// Exactly below a vertical outline edge the answer depends on which side of it the RA falls, so callers
    /// comparing against `rasterize` should pass the raster's own RA/Dec rather than a round-tripped vector.
    func level(raDegrees ra: Double, decDegrees dec: Double) -> Int {
        var best = 0
        for i in levels.indices {
            var inside = false
            for e in edgeTable[i] {
                if let d = e.crossingDec(atRA: ra), d > dec { inside.toggle() }
            }
            if inside { best = max(best, levels[i].level) }
        }
        return best
    }

    /// Equirectangular ICRS map of levels (row-major, row 0 at Dec +90°, column 0 at RA 0° increasing with
    /// column index). Suitable as a texture on the celestial sphere.
    public func rasterize(width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        let decs = (0..<height).map { 90 - (Double($0) + 0.5) * 180 / Double(height) }
        for i in levels.indices {
            let level = UInt8(clamping: levels[i].level)
            let edges = edgeTable[i]
            var byColumn = [[Double]](repeating: [], count: width)
            for e in edges {
                let first = Int(((e.raStart / 360) * Double(width) - 0.5).rounded(.up)) - 1
                let last = Int(((e.raStart + e.width) / 360 * Double(width) - 0.5).rounded(.up)) + 1
                for c in first..<last {
                    let col = ((c % width) + width) % width
                    let ra = (Double(col) + 0.5) * 360 / Double(width)
                    if let d = e.crossingDec(atRA: ra) { byColumn[col].append(d) }
                }
            }
            for col in 0..<width {
                let crossings = byColumn[col].sorted(by: >)
                var k = 0
                for row in 0..<height {
                    while k < crossings.count && crossings[k] > decs[row] { k += 1 }
                    if k % 2 == 1 { out[row * width + col] = max(out[row * width + col], level) }
                }
            }
        }
        return out
    }
}
