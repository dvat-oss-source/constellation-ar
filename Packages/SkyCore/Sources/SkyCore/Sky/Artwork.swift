import Foundation
import simd

/// `Data/artwork.json` entry: Stellarium-style constellation art with three (pixel, HIP) anchors.
/// Pixel coordinates are image pixels, origin top-left, +y down.
public struct ArtworkInfo: Sendable, Hashable, Codable {
    public struct Anchor: Sendable, Hashable, Codable {
        public var pos: [Double]
        public var hip: Int
    }

    public var id: String
    public var file: String
    public var size: [Double]
    public var anchors: [Anchor]

    public static func load(url: URL) throws -> [ArtworkInfo] {
        try JSONDecoder().decode([ArtworkInfo].self, from: Data(contentsOf: url))
    }
}

public enum ArtworkError: Error, Sendable, Equatable {
    case needsThreeAnchors
    case missingStar(Int)
    case degenerateAnchors
}

/// Linear map M with M·(x, y, 1) ∥ sky direction (ICRS), solved from the three anchors so each anchor pixel maps
/// exactly onto its star; directions are M·p normalised (as Stellarium does).
public struct ArtworkPlacement: Sendable {
    public let id: String
    public let imageSize: SIMD2<Double>
    public let pixelToICRS: simd_double3x3

    public init(info: ArtworkInfo, catalog: StarCatalog) throws {
        guard info.anchors.count == 3, info.size.count == 2 else { throw ArtworkError.needsThreeAnchors }
        var stars: [SIMD3<Double>] = []
        for a in info.anchors {
            guard let s = catalog.star(hip: a.hip) else { throw ArtworkError.missingStar(a.hip) }
            stars.append(s.directionDouble)
        }
        try self.init(id: info.id, imageSize: SIMD2(info.size[0], info.size[1]),
                      anchorPixels: info.anchors.map { SIMD2($0.pos[0], $0.pos[1]) }, anchorDirections: stars)
    }

    public init(id: String, imageSize: SIMD2<Double>, anchorPixels: [SIMD2<Double>], anchorDirections: [SIMD3<Double>]) throws {
        guard anchorPixels.count == 3, anchorDirections.count == 3 else { throw ArtworkError.needsThreeAnchors }
        let p = simd_double3x3(columns: (SIMD3(anchorPixels[0], 1), SIMD3(anchorPixels[1], 1), SIMD3(anchorPixels[2], 1)))
        guard abs(p.determinant) > 1e-6 else { throw ArtworkError.degenerateAnchors }
        let s = simd_double3x3(columns: (simd_normalize(anchorDirections[0]), simd_normalize(anchorDirections[1]),
                                         simd_normalize(anchorDirections[2])))
        self.id = id
        self.imageSize = imageSize
        self.pixelToICRS = s * p.inverse
    }

    /// ICRS unit vector for an image pixel.
    public func direction(pixel: SIMD2<Double>) -> SIMD3<Double> {
        simd_normalize(pixelToICRS * SIMD3(pixel, 1))
    }

    public struct Vertex: Sendable, Hashable {
        /// Texture coordinate in [0,1]², origin top-left.
        public var uv: SIMD2<Float>
        public var direction: SIMD3<Float>
    }

    /// (columns+1)×(rows+1) grid of textured vertices, row-major from the top-left, for drawing the image
    /// as a mesh (project each direction like a star).
    public func mesh(columns: Int = 8, rows: Int = 8) -> [Vertex] {
        var v: [Vertex] = []
        v.reserveCapacity((columns + 1) * (rows + 1))
        for j in 0...rows {
            for i in 0...columns {
                let uv = SIMD2(Double(i) / Double(columns), Double(j) / Double(rows))
                v.append(Vertex(uv: SIMD2<Float>(uv), direction: SIMD3<Float>(direction(pixel: uv * imageSize))))
            }
        }
        return v
    }

    /// Triangle indices for `mesh(columns:rows:)`.
    public static func meshIndices(columns: Int = 8, rows: Int = 8) -> [UInt16] {
        var idx: [UInt16] = []
        for j in 0..<rows {
            for i in 0..<columns {
                let a = UInt16(j * (columns + 1) + i), b = a + 1
                let c = a + UInt16(columns + 1), d = c + 1
                idx += [a, c, b, b, c, d]
            }
        }
        return idx
    }
}
