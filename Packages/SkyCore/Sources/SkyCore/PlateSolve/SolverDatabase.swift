import Foundation
import simd

public enum SolverDatabaseError: Error, Sendable, Equatable {
    case badMagic
    case unsupportedVersion(UInt32)
    case truncated
}

/// `Data/solver_db.bin` as written by `tools/build_solver_db.py` (layout documented there).
public struct SolverDatabase: Sendable {
    public static let headerSize = 64
    static let starRecordSize = 20
    static let patternSize = 4
    static let hashMultiplier: UInt64 = 2_654_435_761

    public let patternCount: Int
    public let tableLength: Int
    public let patternBins: Int
    public let patternMaxError: Double
    public let minFovDegrees: Double
    public let maxFovDegrees: Double
    public let magnitudeLimit: Double
    public let verificationStars: Int
    public let hip: [UInt32]
    /// ICRS unit vectors at the catalogue's proper-motion epoch, brightest first.
    public let directions: [SIMD3<Double>]
    public let magnitudes: [Float]
    let patterns: [UInt16]
    let keyHashes: [UInt16]
    let largestEdgeHalf: [UInt16]

    public var starCount: Int { directions.count }

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        guard data.count >= Self.headerSize else { throw SolverDatabaseError.truncated }
        let parsed: ParsedHeader = try data.withUnsafeBytes { raw in
            guard raw[0] == 0x53, raw[1] == 0x4F, raw[2] == 0x4C, raw[3] == 0x56 else { throw SolverDatabaseError.badMagic }
            func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
            func f32(_ o: Int) -> Double { Double(Float(bitPattern: u32(o))) }
            guard u32(4) == 1 else { throw SolverDatabaseError.unsupportedVersion(u32(4)) }
            return ParsedHeader(stars: Int(u32(8)), patterns: Int(u32(12)), table: Int(u32(16)), bins: Int(u32(20)),
                                maxError: f32(24), minFov: f32(28), maxFov: f32(32), magLimit: f32(36),
                                verification: Int(u32(44)))
        }
        let starBytes = parsed.stars * Self.starRecordSize
        let tableBytes = parsed.table * (Self.patternSize * 2 + 2 + 2)
        guard data.count >= Self.headerSize + starBytes + tableBytes else { throw SolverDatabaseError.truncated }
        patternCount = parsed.patterns
        tableLength = parsed.table
        patternBins = parsed.bins
        patternMaxError = parsed.maxError
        minFovDegrees = parsed.minFov
        maxFovDegrees = parsed.maxFov
        magnitudeLimit = parsed.magLimit
        verificationStars = parsed.verification
        (hip, directions, magnitudes, patterns, keyHashes, largestEdgeHalf) = data.withUnsafeBytes { raw in
            func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
            func u16(_ o: Int) -> UInt16 { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
            var hips: [UInt32] = [], dirs: [SIMD3<Double>] = [], mags: [Float] = []
            for i in 0..<parsed.stars {
                let o = Self.headerSize + i * Self.starRecordSize
                hips.append(u32(o))
                let v = SIMD3(Double(Float(bitPattern: u32(o + 4))), Double(Float(bitPattern: u32(o + 8))),
                              Double(Float(bitPattern: u32(o + 12))))
                dirs.append(simd_normalize(v))
                mags.append(Float(bitPattern: u32(o + 16)))
            }
            let tableStart = Self.headerSize + starBytes
            let n = parsed.table
            let pat = (0..<(n * Self.patternSize)).map { u16(tableStart + $0 * 2) }
            let keyStart = tableStart + n * Self.patternSize * 2
            let keys = (0..<n).map { u16(keyStart + $0 * 2) }
            let edgeStart = keyStart + n * 2
            let edges = (0..<n).map { u16(edgeStart + $0 * 2) }
            return (hips, dirs, mags, pat, keys, edges)
        }
    }

    private struct ParsedHeader {
        var stars: Int, patterns: Int, table: Int, bins: Int
        var maxError: Double, minFov: Double, maxFov: Double, magLimit: Double
        var verification: Int
    }

    // MARK: Lookup

    @inline(__always) static func keyHash(_ key: [Int], bins: Int) -> UInt64 {
        var hash: UInt64 = 0
        var power: UInt64 = 1
        for k in key {
            hash &+= UInt64(k) &* power
            power &*= UInt64(bins)
        }
        return hash
    }

    /// Table slots whose 16-bit key check equals that of `hash`, following the quadratic probe sequence until an empty slot.
    func slots(forKeyHash hash: UInt64) -> [Int] {
        let length = UInt64(tableLength)
        let base = (hash &* Self.hashMultiplier) % length
        let check = UInt16(truncatingIfNeeded: hash)
        var found: [Int] = []
        var c: UInt64 = 0
        while c < length {
            let slot = Int((base &+ c &* c) % length)
            let p = slot * Self.patternSize
            if patterns[p] == 0, patterns[p + 1] == 0, patterns[p + 2] == 0, patterns[p + 3] == 0 { break }
            if keyHashes[slot] == check { found.append(slot) }
            c += 1
        }
        return found
    }

    func pattern(at slot: Int) -> (Int, Int, Int, Int) {
        let p = slot * Self.patternSize
        return (Int(patterns[p]), Int(patterns[p + 1]), Int(patterns[p + 2]), Int(patterns[p + 3]))
    }

    /// Largest edge of the pattern in radians (stored as a half float of milliradians).
    func largestEdge(at slot: Int) -> Double { Double(Float16(bitPattern: largestEdgeHalf[slot])) / 1000 }
}
