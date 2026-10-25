import Foundation
import simd

public enum CatalogError: Error, Sendable, Equatable {
    case badMagic
    case unsupportedVersion(UInt32)
    case badRecordSize(UInt32)
    case truncated
    case malformed(String)
}

public struct CatalogStar: Sendable, Hashable {
    public var hip: Int
    /// ICRS unit vector at the catalog's proper-motion epoch.
    public var direction: SIMD3<Float>
    public var vmag: Float
    /// B−V colour index, NaN if unknown.
    public var bv: Float
    /// Parallax in milliarcseconds, NaN if unknown.
    public var parallaxMas: Float

    public var directionDouble: SIMD3<Double> { simd_normalize(SIMD3<Double>(direction)) }
}

/// `Data/stars.bin` (little-endian, 24-byte header, 28-byte records, sorted by vmag ascending).
public struct StarCatalog: Sendable {
    public let pmEpoch: Double
    public let stars: [CatalogStar]
    private let indexByHip: [Int: Int]

    public init(pmEpoch: Double, stars: [CatalogStar]) {
        self.pmEpoch = pmEpoch
        self.stars = stars
        var index: [Int: Int] = [:]
        index.reserveCapacity(stars.count)
        for (i, s) in stars.enumerated() where index[s.hip] == nil { index[s.hip] = i }
        self.indexByHip = index
    }

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        guard data.count >= 24 else { throw CatalogError.truncated }
        let parsed: (Double, [CatalogStar]) = try data.withUnsafeBytes { raw in
            func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
            func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
            guard raw[0] == 0x53, raw[1] == 0x4B, raw[2] == 0x59, raw[3] == 0x53 else { throw CatalogError.badMagic }
            let version = u32(4)
            guard version == 1 else { throw CatalogError.unsupportedVersion(version) }
            let count = Int(u32(8))
            let recordSize = u32(12)
            guard recordSize == 28 else { throw CatalogError.badRecordSize(recordSize) }
            let epoch = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
            guard raw.count >= 24 + count * 28 else { throw CatalogError.truncated }
            var stars: [CatalogStar] = []
            stars.reserveCapacity(count)
            for i in 0..<count {
                let o = 24 + i * 28
                stars.append(CatalogStar(
                    hip: Int(u32(o)),
                    direction: SIMD3(f32(o + 4), f32(o + 8), f32(o + 12)),
                    vmag: f32(o + 16), bv: f32(o + 20), parallaxMas: f32(o + 24)
                ))
            }
            return (epoch, stars)
        }
        self.init(pmEpoch: parsed.0, stars: parsed.1)
    }

    public func star(hip: Int) -> CatalogStar? { indexByHip[hip].map { stars[$0] } }
}

public struct ConstellationFigure: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var segments: [[Int]]

    /// Segments as HIP pairs (malformed entries dropped).
    public var pairs: [(Int, Int)] { segments.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil } }
    public var starHips: Set<Int> { Set(segments.flatMap { $0 }) }
}

/// `Data/lines.json`.
public struct ConstellationLines: Sendable, Codable {
    public var version: Int
    public var source: String?
    public var constellations: [ConstellationFigure]

    public init(url: URL) throws { self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
    public init(data: Data) throws { self = try JSONDecoder().decode(Self.self, from: data) }

    public func figure(_ id: String) -> ConstellationFigure? { constellations.first { $0.id == id } }
}

public struct StarName: Sendable, Hashable, Codable {
    public var hip: Int
    public var name: String
    public var label: Bool?
}

/// `Data/names.json`.
public struct StarNames: Sendable, Codable {
    public var stars: [StarName]

    public init(url: URL) throws { self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
    public init(data: Data) throws { self = try JSONDecoder().decode(Self.self, from: data) }

    public var byHip: [Int: StarName] { Dictionary(stars.map { ($0.hip, $0) }, uniquingKeysWith: { a, _ in a }) }
}

public struct ConstellationInfo: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var genitive: String?
}

/// `Data/constellations.json`.
public enum ConstellationList {
    public static func load(url: URL) throws -> [ConstellationInfo] {
        try JSONDecoder().decode([ConstellationInfo].self, from: Data(contentsOf: url))
    }
}
