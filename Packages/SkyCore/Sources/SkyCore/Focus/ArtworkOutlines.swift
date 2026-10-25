import Foundation
import simd

/// `Data/artwork_outlines.json`: illustrative silhouettes of the constellation art, in image pixels.
public struct ArtworkOutlines: Sendable {
    /// Constellations whose art is shared or missing in the Stellarium set: they have no outline.
    public static let idsWithoutOwnArtwork: Set<String> = ["Pup", "Vel", "Ser"]

    public struct Outline: Sendable, Hashable {
        public var id: String
        /// Image size in pixels; path coordinates are in this space (origin top-left, +y down).
        public var size: SIMD2<Double>
        /// Closed loops (first point repeated last): outer silhouettes and holes, in the order of the data file.
        public var paths: [[SIMD2<Double>]]
    }

    public let outlines: [String: Outline]

    public init(outlines: [Outline]) {
        self.outlines = Dictionary(outlines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public init(url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    public init(data: Data) throws {
        struct File: Decodable {
            struct Entry: Decodable {
                var size: [Double]
                var paths: [[[Double]]]
            }
            var outlines: [String: Entry]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        var list: [Outline] = []
        for (id, e) in file.outlines.sorted(by: { $0.key < $1.key }) {
            guard e.size.count == 2, e.paths.allSatisfy({ $0.count >= 4 && $0.allSatisfy { $0.count == 2 } }) else {
                throw CatalogError.malformed("outline \(id)")
            }
            list.append(Outline(id: id, size: SIMD2(e.size[0], e.size[1]),
                                paths: e.paths.map { $0.map { SIMD2($0[0], $0[1]) } }))
        }
        self.init(outlines: list)
    }

    public func outline(for id: String) -> Outline? { outlines[id] }

    /// False for `idsWithoutOwnArtwork` (and any id without art).
    public func hasOutline(for id: String) -> Bool { outlines[id] != nil }

    /// The outline of `id` on the sky, placed with the same three-anchor fit as the artwork mesh. nil without an outline
    /// or artwork entry.
    public func skyOutline(for id: String, artwork: [ArtworkInfo], catalog: StarCatalog) throws -> SkyOutline? {
        guard let outline = outlines[id], let info = artwork.first(where: { $0.id == id }) else { return nil }
        return SkyOutline(outline: outline, placement: try ArtworkPlacement(info: info, catalog: catalog))
    }
}

/// An outline mapped to sky directions with cumulative arc length, for trace-in animation.
public struct SkyOutline: Sendable {
    public struct Path: Sendable, Hashable {
        /// ICRS (J2000) unit vectors, first point repeated last.
        public var points: [SIMD3<Double>]
        /// Cumulative angular length in radians along `points`; `cumulativeLength[0] == 0`, last == `length`.
        public var cumulativeLength: [Double]
        public var length: Double { cumulativeLength.last ?? 0 }
    }

    public let id: String
    public let paths: [Path]
    /// Sum of the path lengths, radians.
    public let totalLength: Double

    public init(outline: ArtworkOutlines.Outline, placement: ArtworkPlacement) {
        id = outline.id
        var built: [Path] = []
        for path in outline.paths {
            let points = path.map { placement.direction(pixel: $0) }
            var cumulative = [0.0]
            cumulative.reserveCapacity(points.count)
            for (a, b) in zip(points, points.dropFirst()) { cumulative.append(cumulative[cumulative.count - 1] + Angle.separation(a, b)) }
            built.append(Path(points: points, cumulativeLength: cumulative))
        }
        paths = built
        totalLength = built.reduce(0) { $0 + $1.length }
    }

    /// Every loop drawn from its start to the same fraction `progress` (0...1) of its own length, with the last
    /// segment cut by interpolation. Loops shorter than two points are dropped.
    public func partialPaths(progress: Double) -> [[SIMD3<Double>]] {
        let t = min(max(progress, 0), 1)
        return paths.compactMap { path -> [SIMD3<Double>]? in
            let target = path.length * t
            guard target > 0 else { return nil }
            if t >= 1 { return path.points }
            guard let k = path.cumulativeLength.firstIndex(where: { $0 >= target }), k > 0 else { return nil }
            let span = path.cumulativeLength[k] - path.cumulativeLength[k - 1]
            let f = span > 0 ? (target - path.cumulativeLength[k - 1]) / span : 1
            let (p0, p1) = (path.points[k - 1], path.points[k])
            let theta = acos(min(1, simd_dot(p0, p1)))
            let end = theta > 1e-12 ? (p0 * sin((1 - f) * theta) + p1 * sin(f * theta)) / sin(theta) : p0
            return Array(path.points[..<k]) + [end]
        }
    }
}
