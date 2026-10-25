import Foundation
import SatelliteKit

public enum SatelliteError: Error, Sendable, Hashable {
    case invalidRecord(String)
    case notAnOMMArray
    case propagationFailed(noradID: Int, minutesFromEpoch: Double, reason: String)
    case sunUnavailable(String)
    case httpStatus(Int)
    case noUsableSatellites
}

/// One CelesTrak OMM (CCSDS Orbit Mean-Elements Message) record in JSON form. Numeric fields may be JSON numbers
/// or strings; optional bookkeeping fields fall back to the TLE defaults.
public struct OMMRecord: Sendable, Hashable, Codable {
    public var objectName: String
    public var objectID: String
    public var epoch: String
    public var meanMotion: Double
    public var eccentricity: Double
    public var inclination: Double
    public var raOfAscendingNode: Double
    public var argumentOfPericenter: Double
    public var meanAnomaly: Double
    public var ephemerisType: Int
    public var classificationType: String
    public var noradCatalogID: Int
    public var elementSetNumber: Int
    public var revolutionAtEpoch: Int
    public var bstar: Double
    public var meanMotionDot: Double
    public var meanMotionDDot: Double

    enum CodingKeys: String, CodingKey {
        case objectName = "OBJECT_NAME"
        case objectID = "OBJECT_ID"
        case epoch = "EPOCH"
        case meanMotion = "MEAN_MOTION"
        case eccentricity = "ECCENTRICITY"
        case inclination = "INCLINATION"
        case raOfAscendingNode = "RA_OF_ASC_NODE"
        case argumentOfPericenter = "ARG_OF_PERICENTER"
        case meanAnomaly = "MEAN_ANOMALY"
        case ephemerisType = "EPHEMERIS_TYPE"
        case classificationType = "CLASSIFICATION_TYPE"
        case noradCatalogID = "NORAD_CAT_ID"
        case elementSetNumber = "ELEMENT_SET_NO"
        case revolutionAtEpoch = "REV_AT_EPOCH"
        case bstar = "BSTAR"
        case meanMotionDot = "MEAN_MOTION_DOT"
        case meanMotionDDot = "MEAN_MOTION_DDOT"
    }

    public init(objectName: String, objectID: String = "", epoch: String, meanMotion: Double, eccentricity: Double,
                inclination: Double, raOfAscendingNode: Double, argumentOfPericenter: Double, meanAnomaly: Double,
                noradCatalogID: Int, bstar: Double, ephemerisType: Int = 0, classificationType: String = "U",
                elementSetNumber: Int = 999, revolutionAtEpoch: Int = 0, meanMotionDot: Double = 0,
                meanMotionDDot: Double = 0) {
        self.objectName = objectName
        self.objectID = objectID
        self.epoch = epoch
        self.meanMotion = meanMotion
        self.eccentricity = eccentricity
        self.inclination = inclination
        self.raOfAscendingNode = raOfAscendingNode
        self.argumentOfPericenter = argumentOfPericenter
        self.meanAnomaly = meanAnomaly
        self.ephemerisType = ephemerisType
        self.classificationType = classificationType
        self.noradCatalogID = noradCatalogID
        self.elementSetNumber = elementSetNumber
        self.revolutionAtEpoch = revolutionAtEpoch
        self.bstar = bstar
        self.meanMotionDot = meanMotionDot
        self.meanMotionDDot = meanMotionDDot
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        noradCatalogID = try c.lenientInt(.noradCatalogID)
        objectID = (try? c.decodeIfPresent(String.self, forKey: .objectID)) ?? ""
        let name = (try? c.decodeIfPresent(String.self, forKey: .objectName)) ?? ""
        objectName = name.isEmpty ? (objectID.isEmpty ? "NORAD \(noradCatalogID)" : objectID) : name
        epoch = try c.decode(String.self, forKey: .epoch)
        meanMotion = try c.lenientDouble(.meanMotion)
        eccentricity = try c.lenientDouble(.eccentricity)
        inclination = try c.lenientDouble(.inclination)
        raOfAscendingNode = try c.lenientDouble(.raOfAscendingNode)
        argumentOfPericenter = try c.lenientDouble(.argumentOfPericenter)
        meanAnomaly = try c.lenientDouble(.meanAnomaly)
        bstar = try c.lenientDoubleIfPresent(.bstar) ?? 0
        ephemerisType = try c.lenientIntIfPresent(.ephemerisType) ?? 0
        classificationType = (try? c.decodeIfPresent(String.self, forKey: .classificationType)) ?? "U"
        elementSetNumber = try c.lenientIntIfPresent(.elementSetNumber) ?? 999
        revolutionAtEpoch = try c.lenientIntIfPresent(.revolutionAtEpoch) ?? 0
        meanMotionDot = try c.lenientDoubleIfPresent(.meanMotionDot) ?? 0
        meanMotionDDot = try c.lenientDoubleIfPresent(.meanMotionDDot) ?? 0
    }

    /// Reasons this record cannot be propagated, or nil when it is usable.
    public var validationFailure: String? {
        let values = [meanMotion, eccentricity, inclination, raOfAscendingNode, argumentOfPericenter, meanAnomaly, bstar]
        if !values.allSatisfy(\.isFinite) { return "non-finite element" }
        if noradCatalogID <= 0 { return "NORAD_CAT_ID \(noradCatalogID)" }
        if !(meanMotion > 0) { return "MEAN_MOTION \(meanMotion)" }
        if !(0..<1).contains(eccentricity) { return "ECCENTRICITY \(eccentricity)" }
        if !(0...180).contains(inclination) { return "INCLINATION \(inclination)" }
        if OMMParser.parseEpoch(epoch) == nil { return "EPOCH '\(epoch)'" }
        return nil
    }
}

private extension KeyedDecodingContainer {
    func lenientDouble(_ key: Key) throws -> Double {
        if let v = try? decode(Double.self, forKey: key) { return v }
        let text = try decode(String.self, forKey: key)
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not a number: '\(text)'")
        }
        return v
    }

    func lenientDoubleIfPresent(_ key: Key) throws -> Double? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        return try lenientDouble(key)
    }

    func lenientInt(_ key: Key) throws -> Int {
        if let v = try? decode(Int.self, forKey: key) { return v }
        let text = try decode(String.self, forKey: key)
        guard let v = Int(text.trimmingCharacters(in: .whitespaces)) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not an integer: '\(text)'")
        }
        return v
    }

    func lenientIntIfPresent(_ key: Key) throws -> Int? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        return try lenientInt(key)
    }
}

/// A satellite ready for SGP4 propagation.
public struct TrackedSatellite: Sendable, Identifiable {
    public let record: OMMRecord
    /// Element-set epoch (UTC).
    public let epoch: Date
    public let satellite: Satellite

    public var id: Int { noradID }
    public var noradID: Int { record.noradCatalogID }
    public var name: String { record.objectName }
    public var internationalDesignator: String { record.objectID }
    public var isISS: Bool { noradID == CelesTrak.issNoradID }
    public var periodMinutes: Double { 1440 / record.meanMotion }

    public init(record: OMMRecord) throws {
        if let failure = record.validationFailure { throw SatelliteError.invalidRecord(failure) }
        guard let epoch = OMMParser.parseEpoch(record.epoch) else { throw SatelliteError.invalidRecord("EPOCH") }
        self.record = record
        self.epoch = epoch
        // EPHEMERIS_TYPE is forced to 0 so SatelliteKit picks SGP4/SDP4 by period, as python-sgp4 does.
        let elements = Elements(
            commonName: record.objectName, noradIndex: UInt(record.noradCatalogID), launchName: record.objectID,
            t₀: epoch, e₀: record.eccentricity, i₀: record.inclination, ω₀: record.argumentOfPericenter,
            Ω₀: record.raOfAscendingNode, M₀: record.meanAnomaly, n₀: record.meanMotion,
            ephemType: 0, tleClass: record.classificationType, tleNumber: record.elementSetNumber,
            revNumber: record.revolutionAtEpoch, dragCoeff: record.bstar)
        self.satellite = Satellite(elements: elements)
    }

    /// Seconds from the element epoch to `now` (positive once the elements are in the past).
    public func elementAge(at now: Date) -> TimeInterval { now.timeIntervalSince(epoch) }
}

public struct OMMParseResult: Sendable {
    public struct Skipped: Sendable, Hashable {
        public var index: Int
        public var noradID: Int?
        public var reason: String
    }

    public var satellites: [TrackedSatellite]
    public var skipped: [Skipped]

    public func satellite(noradID: Int) -> TrackedSatellite? { satellites.first { $0.noradID == noradID } }
}

public enum OMMParser {
    /// Parses a CelesTrak OMM JSON array (or single object). Malformed records are skipped and reported; duplicates
    /// keep the newest epoch. Throws only when the payload is not JSON objects at all.
    public static func parse(_ data: Data) throws -> OMMParseResult {
        let decoder = JSONDecoder()
        let entries: [LenientEntry]
        if let array = try? decoder.decode([LenientEntry].self, from: data) {
            entries = array
        } else if let single = try? decoder.decode(LenientEntry.self, from: data), single.isObject {
            entries = [single]
        } else {
            throw SatelliteError.notAnOMMArray
        }

        var satellites: [TrackedSatellite] = []
        var indexByID: [Int: Int] = [:]
        var skipped: [OMMParseResult.Skipped] = []
        for (index, entry) in entries.enumerated() {
            guard let record = entry.record else {
                skipped.append(.init(index: index, noradID: entry.noradID, reason: entry.failure ?? "undecodable"))
                continue
            }
            do {
                let sat = try TrackedSatellite(record: record)
                if let existing = indexByID[sat.noradID] {
                    if sat.epoch > satellites[existing].epoch { satellites[existing] = sat }
                    skipped.append(.init(index: index, noradID: sat.noradID, reason: "duplicate"))
                } else {
                    indexByID[sat.noradID] = satellites.count
                    satellites.append(sat)
                }
            } catch {
                skipped.append(.init(index: index, noradID: record.noradCatalogID, reason: "\(error)"))
            }
        }
        return OMMParseResult(satellites: satellites, skipped: skipped)
    }

    public static func satellites(from data: Data) throws -> [TrackedSatellite] { try parse(data).satellites }

    /// Parses `YYYY-MM-DDTHH:MM:SS[.fraction][Z]` (any number of fractional digits, or none) as UTC with full
    /// sub-millisecond precision (`DateFormatter` truncates to milliseconds).
    public static func parseEpoch(_ text: String) -> Date? {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.hasSuffix("Z") || s.hasSuffix("z") { s = s.dropLast() }
        let parts = s.split(maxSplits: 1, whereSeparator: { $0 == "T" || $0 == " " })
        guard let datePart = parts.first else { return nil }
        let ymd = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard ymd.count == 3, ymd[0].count == 4, let year = Int(ymd[0]), let month = Int(ymd[1]),
              let day = Int(ymd[2]), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var seconds = 0.0
        if parts.count == 2 {
            let hms = parts[1].split(separator: ":", omittingEmptySubsequences: false)
            guard (2...3).contains(hms.count), let h = Int(hms[0]), let m = Int(hms[1]),
                  (0...23).contains(h), (0...59).contains(m) else { return nil }
            var sec = 0.0
            if hms.count == 3 {
                guard hms[2].first?.isNumber == true, let v = Double(hms[2]), v >= 0, v < 61 else { return nil }
                sec = v
            }
            seconds = Double(h * 3600 + m * 60) + sec
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        return Date(timeIntervalSince1970: Double(days) * 86_400 + seconds)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

/// Decodes one array element without ever failing, so one bad record cannot sink the whole array.
private struct LenientEntry: Decodable {
    var record: OMMRecord?
    var failure: String?
    var noradID: Int?
    var isObject = true

    init(from decoder: any Decoder) throws {
        do {
            record = try OMMRecord(from: decoder)
        } catch {
            failure = Self.describe(error)
            if let c = try? decoder.container(keyedBy: OMMRecord.CodingKeys.self) {
                noradID = (try? c.decode(Int.self, forKey: .noradCatalogID))
                    ?? (try? c.decode(String.self, forKey: .noradCatalogID)).flatMap { Int($0) }
            } else {
                isObject = false
            }
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "missing \(key.stringValue)"
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
            "bad \(ctx.codingPath.last?.stringValue ?? "value")"
        case DecodingError.dataCorrupted(let ctx): ctx.debugDescription
        default: "\(error)"
        }
    }
}
