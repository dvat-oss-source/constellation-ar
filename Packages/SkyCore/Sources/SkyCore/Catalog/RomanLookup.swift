import Foundation
import simd

/// Roman (1987) constellation identification, VizieR VI/42 (`Data/roman1875.json`).
public struct RomanLookup: Sendable {
    public struct Row: Sendable, Hashable {
        public var raLowHours: Double
        public var raHighHours: Double
        public var decLowDegrees: Double
        public var constellation: String
    }

    public let rows: [Row]
    /// Mean J2000 (ICRS) → mean equator and equinox of B1875.0.
    public let toB1875: simd_double3x3

    /// B1875.0 = JD 2405889.258550475 (TT).
    public static let b1875CenturiesTT = (2_405_889.258550475 - AstroInstant.j2000JD) / 36_525

    public init(rows: [Row]) {
        self.rows = rows
        self.toB1875 = EarthOrientation.precession(centuriesTT: Self.b1875CenturiesTT) * EarthOrientation.frameBias
    }

    public init(url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    public init(data: Data) throws {
        struct File: Decodable {
            var rows: [[Row.Field]]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        var rows: [Row] = []
        rows.reserveCapacity(file.rows.count)
        for r in file.rows {
            guard r.count == 4, case .number(let a) = r[0], case .number(let b) = r[1], case .number(let d) = r[2],
                  case .string(let id) = r[3] else { throw CatalogError.malformed("roman row \(rows.count)") }
            rows.append(Row(raLowHours: a, raHighHours: b, decLowDegrees: d, constellation: id))
        }
        self.init(rows: rows)
    }

    /// Constellation for B1875 coordinates (RA hours, Dec degrees): first row with decLow ≤ dec and
    /// raLow ≤ ra < raHigh.
    public func constellation(raHours1875 ra: Double, decDegrees1875 dec: Double) -> String? {
        var r = ra.truncatingRemainder(dividingBy: 24)
        if r < 0 { r += 24 }
        for row in rows where row.decLowDegrees <= dec && row.raLowHours <= r && r < row.raHighHours {
            return row.constellation
        }
        return nil
    }

    /// Constellation containing an ICRS (J2000) direction.
    public func constellation(icrs v: SIMD3<Double>) -> String? {
        let (ra, dec) = b1875(icrs: v)
        return constellation(raHours1875: ra, decDegrees1875: dec)
    }

    /// (RA hours, Dec degrees) referred to the B1875.0 mean equator and equinox.
    public func b1875(icrs v: SIMD3<Double>) -> (raHours: Double, decDegrees: Double) {
        let (lon, lat) = (toB1875 * simd_normalize(v)).lonLat
        return (Angle.degrees(lon) / 15, Angle.degrees(lat))
    }
}

extension RomanLookup.Row {
    enum Field: Decodable {
        case number(Double), string(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .number(d) } else { self = .string(try c.decode(String.self)) }
        }
    }
}
