import Foundation
import simd

/// `Data/designations.json`: Yale Bright Star Catalogue designations joined to Hipparcos by HD number.
/// Values are "α Ori" (Bayer, Unicode Greek and superscripts), "58 Ori" (Flamsteed) or "HR 1234" (no Bayer/Flamsteed).
public struct StarDesignations: Sendable {
    public let byHip: [Int: String]

    public init(byHip: [Int: String]) { self.byHip = byHip }
    public init(url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    public init(data: Data) throws {
        struct File: Decodable { var designations: [String: String] }
        let file = try JSONDecoder().decode(File.self, from: data)
        var map: [Int: String] = [:]
        map.reserveCapacity(file.designations.count)
        for (k, v) in file.designations {
            guard let hip = Int(k) else { throw CatalogError.malformed("designation key \(k)") }
            map[hip] = v
        }
        byHip = map
    }

    public subscript(hip: Int) -> String? { byHip[hip] }
}

public enum ConstellationVisibility: String, Sendable, Hashable, Codable {
    case risesAndSets, circumpolar, neverRises
}

/// Everything the info sheet shows for one constellation, for an observer and an instant.
public struct ConstellationFacts: Sendable {
    public struct BrightStar: Sendable, Hashable {
        public var hip: Int
        /// IAU WGSN proper name ("Betelgeuse").
        public var iauName: String?
        /// Yale BSC designation with the IAU abbreviation: "α Ori", "58 Ori", or "HR 1234".
        public var designation: String?
        /// Same with the genitive: "α Orionis", "58 Orionis".
        public var designationGenitive: String?
        /// IAU name, else designation, else "HIP n".
        public var displayName: String
        public var vmag: Double
        /// 1000 / parallax in light-years; nil without a positive catalogue parallax. Not error-filtered.
        public var distanceLightYears: Double?
        /// ICRS (J2000) unit vector at the catalogue epoch.
        public var direction: SIMD3<Double>
    }

    public var id: String
    public var name: String
    public var genitive: String?

    /// ICRS unit vector of the reference point: normalised mean of the stick-figure stars' directions.
    public var referencePoint: SIMD3<Double>
    /// Apparent altitude of the reference point (standard refraction applied), degrees.
    public var altitudeDegrees: Double
    /// Azimuth from north through east, degrees.
    public var azimuthDegrees: Double
    /// Airless altitude, degrees (what the rise/set times are computed with).
    public var airlessAltitudeDegrees: Double
    /// Airless altitude above `ConstellationAtlas.horizonAltitudeDegrees` (−0.5667°).
    public var isAboveHorizon: Bool
    public var sunAltitudeDegrees: Double
    /// Reference point above the horizon and the Sun below civil twilight (−6°).
    public var isVisibleNow: Bool

    public var visibility: ConstellationVisibility
    /// First occurrence within `window` (the 24 hours from the requested instant). nil when `visibility` rules it out.
    public var rise: Date?
    public var set: Date?
    /// Upper culmination; always present.
    public var transit: Date
    public var transitAltitudeDegrees: Double
    public var window: DateInterval

    /// Brightest catalogue stars inside the border (Hipparcos V from stars.bin), brightest first.
    public var brightestStars: [BrightStar]
    /// Deep-sky objects inside the border, brightest first, at most `deepSkyLimit` of `deepSkyTotal`.
    public var deepSkyObjects: [DeepSkyObject]
    public var deepSkyTotal: Int
    /// Sun, Moon and planets whose apparent position is inside the border right now.
    public var bodies: [SolarSystemPosition]
}

/// Static sky data joined up for per-constellation queries.
public struct ConstellationAtlas: Sendable {
    /// Airless altitude of the reference point at rise and set: 34′ of standard refraction at the horizon, no semidiameter.
    public static let horizonAltitudeDegrees = -0.5667
    public static let visibleSunAltitudeDegrees = DaylightState.civilAltitude

    public let constellations: [ConstellationInfo]
    public let boundaries: ConstellationBoundaries
    let infoByID: [String: ConstellationInfo]
    let references: [String: SIMD3<Double>]
    let starsByConstellation: [String: [Int]]
    let deepSkyByConstellation: [String: [Int]]
    let catalog: StarCatalog
    let names: [Int: String]
    let designations: StarDesignations
    let deepSky: DeepSkyCatalog

    public init(constellations: [ConstellationInfo], lines: ConstellationLines, catalog: StarCatalog, names: StarNames,
                designations: StarDesignations, boundaries: ConstellationBoundaries, deepSky: DeepSkyCatalog) {
        self.constellations = constellations
        self.boundaries = boundaries
        self.catalog = catalog
        self.designations = designations
        self.deepSky = deepSky
        infoByID = Dictionary(uniqueKeysWithValues: constellations.map { ($0.id, $0) })
        self.names = Dictionary(names.stars.map { ($0.hip, $0.name) }, uniquingKeysWith: { a, _ in a })

        var refs: [String: SIMD3<Double>] = [:]
        for figure in lines.constellations {
            let sum = figure.starHips.sorted().compactMap { catalog.star(hip: $0)?.directionDouble }.reduce(SIMD3<Double>.zero, +)
            if simd_length(sum) > 1e-9 { refs[figure.id] = simd_normalize(sum) }
        }
        references = refs

        var stars: [String: [Int]] = [:]
        for (i, s) in catalog.stars.enumerated() {
            if let id = boundaries.constellation(icrs: s.directionDouble) { stars[id, default: []].append(i) }
        }
        starsByConstellation = stars
        var dso: [String: [Int]] = [:]
        for (i, o) in deepSky.objects.enumerated() {
            if let id = boundaries.constellation(icrs: o.direction) { dso[id, default: []].append(i) }
        }
        for key in dso.keys {
            dso[key]!.sort { (deepSky.objects[$0].mag ?? 99, $0) < (deepSky.objects[$1].mag ?? 99, $1) }
        }
        deepSkyByConstellation = dso
    }

    /// Loads the bundled files from a directory holding the contents of `Data/`.
    public init(dataDirectory dir: URL) throws {
        try self.init(
            constellations: ConstellationList.load(url: dir.appendingPathComponent("constellations.json")),
            lines: ConstellationLines(url: dir.appendingPathComponent("lines.json")),
            catalog: StarCatalog(url: dir.appendingPathComponent("stars.bin")),
            names: StarNames(url: dir.appendingPathComponent("names.json")),
            designations: StarDesignations(url: dir.appendingPathComponent("designations.json")),
            boundaries: ConstellationBoundaries(url: dir.appendingPathComponent("boundaries.json")),
            deepSky: DeepSkyCatalog(url: dir.appendingPathComponent("dso.json")))
    }

    /// The point the constellation's alt/az and rise/transit/set refer to: the normalised mean of the unit vectors of
    /// its stick-figure stars (ICRS, catalogue epoch). nil for ids without a figure.
    public func referencePoint(of id: String) -> SIMD3<Double>? { references[id] }

    /// Brightest stars inside the constellation's border.
    public func brightestStars(in id: String, count: Int = 5) -> [ConstellationFacts.BrightStar] {
        (starsByConstellation[id] ?? []).prefix(count).map { brightStar(catalog.stars[$0], constellation: id) }
    }

    func brightStar(_ s: CatalogStar, constellation id: String) -> ConstellationFacts.BrightStar {
        let designation = designations[s.hip]
        var genitive = designation
        if let designation, let space = designation.lastIndex(of: " "), let g = infoByID[String(designation[designation.index(after: space)...])]?.genitive {
            genitive = String(designation[..<space]) + " " + g
        }
        let iau = names[s.hip]
        return ConstellationFacts.BrightStar(
            hip: s.hip, iauName: iau, designation: designation, designationGenitive: genitive,
            displayName: iau ?? designation ?? "HIP \(s.hip)", vmag: Double(s.vmag),
            distanceLightYears: s.parallaxMas > 0 ? 3261.563777 / Double(s.parallaxMas) : nil,
            direction: s.directionDouble)
    }

    /// Facts for one constellation. `instant` carries UT1−UTC; events are searched in the 24 hours after it.
    public func facts(for id: String, location: GeoLocation, at instant: AstroInstant, brightestCount: Int = 5,
                      deepSkyLimit: Int = 12) throws -> ConstellationFacts {
        guard let info = infoByID[id], let ref = references[id] else { throw CatalogError.malformed("unknown constellation \(id)") }
        let session = SkySession(epoch: instant, location: location)
        let apparent = session.apparentOfDate(icrs: ref)
        let enu = session.horizonMatrix(at: instant) * apparent
        let horizontal = HorizontalCoordinates(enu: enu)
        let airless = Angle.degrees(horizontal.altitude)
        let sunAltitude = try SolarSystem.sunAltitudeDegrees(at: instant, session: session)
        let events = Self.events(apparent: apparent, session: session, start: instant)

        let snapshot = try SolarSystem.snapshot(at: instant, session: session)
        let bodies = snapshot.bodies.filter { boundaries.constellation(icrs: session.icrs(fromApparentOfDate: $0.ofDate)) == id }
        let dsoIndices = deepSkyByConstellation[id] ?? []
        let above = airless > Self.horizonAltitudeDegrees
        return ConstellationFacts(
            id: id, name: info.name, genitive: info.genitive, referencePoint: ref,
            altitudeDegrees: Angle.degrees(Refraction.standard.apparentAltitude(trueAltitude: horizontal.altitude)),
            azimuthDegrees: Angle.degrees(horizontal.azimuth), airlessAltitudeDegrees: airless,
            isAboveHorizon: above, sunAltitudeDegrees: sunAltitude,
            isVisibleNow: above && sunAltitude < Self.visibleSunAltitudeDegrees,
            visibility: events.visibility, rise: events.rise, set: events.set, transit: events.transit,
            transitAltitudeDegrees: events.transitAltitude,
            window: DateInterval(start: instant.date, duration: 86_400),
            brightestStars: brightestStars(in: id, count: brightestCount),
            deepSkyObjects: dsoIndices.prefix(deepSkyLimit).map { deepSky.objects[$0] }, deepSkyTotal: dsoIndices.count,
            bodies: bodies)
    }

    struct Events {
        var visibility: ConstellationVisibility
        var rise: Date?
        var set: Date?
        var transit: Date
        var transitAltitude: Double
    }

    /// Rise, upper transit and set of a fixed true-of-date direction: the first of each after `start`.
    static func events(apparent: SIMD3<Double>, session: SkySession, start: AstroInstant) -> Events {
        let (alpha, delta) = apparent.lonLat
        let phi = Angle.radians(session.location.latitude)
        let sinH0 = sin(Angle.radians(horizonAltitudeDegrees))
        let sinProduct = sin(phi) * sin(delta)
        let denominator = cos(phi) * cos(delta)
        let visibility: ConstellationVisibility
        var hourAngleAtHorizon = 0.0
        if abs(denominator) < 1e-12 {
            visibility = sinProduct > sinH0 ? .circumpolar : .neverRises
        } else {
            let x = (sinH0 - sinProduct) / denominator
            if x <= -1 {
                visibility = .circumpolar
            } else if x >= 1 {
                visibility = .neverRises
            } else {
                visibility = .risesAndSets
                hourAngleAtHorizon = acos(x)
            }
        }
        let siderealRate = 2 * Double.pi / 86_164.0905
        func time(hourAngle target: Double) -> Date {
            var t = start
            var diff = Angle.wrapTwoPi(target + alpha - session.localSiderealTime(at: start))
            for _ in 0..<8 {
                t = t.adding(seconds: diff / siderealRate)
                diff = Angle.wrapPi(target + alpha - session.localSiderealTime(at: t))
                if abs(diff) < 1e-10 { break }
            }
            return t.date
        }
        let transitAltitude = asin(min(1, max(-1, sinProduct + denominator)))
        return Events(
            visibility: visibility,
            rise: visibility == .risesAndSets ? time(hourAngle: -hourAngleAtHorizon) : nil,
            set: visibility == .risesAndSets ? time(hourAngle: hourAngleAtHorizon) : nil,
            transit: time(hourAngle: 0), transitAltitude: Angle.degrees(transitAltitude))
    }
}
