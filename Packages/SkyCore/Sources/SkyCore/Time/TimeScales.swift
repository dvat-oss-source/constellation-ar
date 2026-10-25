import Foundation

/// A UTC instant with the derived time scales needed for astrometry.
///
/// UT1 is taken equal to UTC unless `ut1MinusUTC` is supplied; |UT1−UTC| < 0.9 s by IERS rule,
/// which moves sidereal time by at most 13.5″ (0.0038°).
public struct AstroInstant: Sendable, Hashable, Codable {
    public static let j2000JD = 2_451_545.0
    public static let unixEpochJD = 2_440_587.5
    public static let ttMinusTAI = 32.184

    public let jdUTC: Double
    public let ut1MinusUTC: Double
    public let taiMinusUTC: Double

    public init(date: Date, ut1MinusUTC: Double = 0) {
        let unix = date.timeIntervalSince1970
        self.jdUTC = Self.unixEpochJD + unix / 86_400
        self.ut1MinusUTC = ut1MinusUTC
        self.taiMinusUTC = LeapSeconds.taiMinusUTC(unixSeconds: unix)
    }

    public init(jdUTC: Double, ut1MinusUTC: Double = 0) {
        self.jdUTC = jdUTC
        self.ut1MinusUTC = ut1MinusUTC
        self.taiMinusUTC = LeapSeconds.taiMinusUTC(unixSeconds: (jdUTC - Self.unixEpochJD) * 86_400)
    }

    public var date: Date { Date(timeIntervalSince1970: (jdUTC - Self.unixEpochJD) * 86_400) }

    /// TT − UTC in seconds (69.184 s since 2017).
    public var ttMinusUTC: Double { taiMinusUTC + Self.ttMinusTAI }

    public var jdTT: Double { jdUTC + ttMinusUTC / 86_400 }
    public var jdUT1: Double { jdUTC + ut1MinusUTC / 86_400 }

    /// Days of TT since J2000.0.
    public var daysTT: Double { (jdUTC - Self.j2000JD) + ttMinusUTC / 86_400 }
    /// Days of UT1 since J2000.0.
    public var daysUT1: Double { (jdUTC - Self.j2000JD) + ut1MinusUTC / 86_400 }
    /// Julian centuries of TT since J2000.0.
    public var centuriesTT: Double { daysTT / 36_525 }

    public func adding(seconds: Double) -> AstroInstant {
        AstroInstant(jdUTC: jdUTC + seconds / 86_400, ut1MinusUTC: ut1MinusUTC)
    }
}

/// IERS TAI−UTC table (Bulletin C). The last entry stays in force until IERS announces another leap second.
public enum LeapSeconds {
    /// (Unix seconds at which the offset takes effect, TAI−UTC seconds).
    static let table: [(Double, Double)] = [
        (63_072_000, 10), (78_796_800, 11), (94_694_400, 12), (126_230_400, 13),
        (157_766_400, 14), (189_302_400, 15), (220_924_800, 16), (252_460_800, 17),
        (283_996_800, 18), (315_532_800, 19), (362_793_600, 20), (394_329_600, 21),
        (425_865_600, 22), (489_024_000, 23), (567_993_600, 24), (631_152_000, 25),
        (662_688_000, 26), (709_948_800, 27), (741_484_800, 28), (773_020_800, 29),
        (820_454_400, 30), (867_715_200, 31), (915_148_800, 32), (1_136_073_600, 33),
        (1_230_768_000, 34), (1_341_100_800, 35), (1_435_708_800, 36), (1_483_228_800, 37),
    ]

    public static func taiMinusUTC(unixSeconds: Double) -> Double {
        var result = 10.0
        for (start, offset) in table where unixSeconds >= start { result = offset }
        return result
    }
}
