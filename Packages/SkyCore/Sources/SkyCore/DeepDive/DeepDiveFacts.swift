import Foundation
import simd

/// Constellation membership of every catalog star via the Roman (VI/42) lookup.
public struct ConstellationMembership: Sendable {
    /// Constellation id per catalog index (parallel to `StarCatalog.stars`).
    public let idByStarIndex: [String?]
    /// Catalog indices per constellation, brightest first.
    public let starIndicesByID: [String: [Int]]

    public init(catalog: StarCatalog, roman: RomanLookup) {
        var ids: [String?] = []
        ids.reserveCapacity(catalog.stars.count)
        var byID: [String: [Int]] = [:]
        for (i, s) in catalog.stars.enumerated() {
            let id = roman.constellation(icrs: s.directionDouble)
            ids.append(id)
            if let id { byID[id, default: []].append(i) }
        }
        for (k, v) in byID { byID[k] = v.sorted { catalog.stars[$0].vmag < catalog.stars[$1].vmag } }
        idByStarIndex = ids
        starIndicesByID = byID
    }
}

/// Facts for the Phase 4 deep-dive prompt about the locked constellation.
public struct DeepDiveFacts: Sendable, Hashable, Codable {
    public struct StarFact: Sendable, Hashable, Codable {
        public var hip: Int
        public var name: String?
        public var vmag: Double
        public var altitudeDegrees: Double
    }

    public struct PlanetFact: Sendable, Hashable, Codable {
        public var name: String
        public var magnitude: Double
        /// Angle from the constellation's centre, degrees.
        public var separationDegrees: Double
        public var inConstellation: Bool
        public var altitudeDegrees: Double
    }

    public struct DeepSkyFact: Sendable, Hashable, Codable {
        public var name: String
        public var kind: String
        public var magnitude: Double?
    }

    public struct PassFact: Sendable, Hashable, Codable {
        public var name: String
        public var start: Date
        public var maximum: Date
        public var end: Date
        public var maxAltitudeDegrees: Double
        public var startDirection: String
        public var endDirection: String
        public var visible: Bool

        public init(name: String, start: Date, maximum: Date, end: Date, maxAltitudeDegrees: Double,
                    startDirection: String, endDirection: String, visible: Bool) {
            self.name = name; self.start = start; self.maximum = maximum; self.end = end
            self.maxAltitudeDegrees = maxAltitudeDegrees
            self.startDirection = startDirection; self.endDirection = endDirection; self.visible = visible
        }

        public init(_ summary: SatellitePassSummary) {
            self.init(name: summary.satelliteName, start: summary.start, maximum: summary.maximum, end: summary.end,
                      maxAltitudeDegrees: summary.maxAltitudeDegrees, startDirection: summary.startDirection,
                      endDirection: summary.endDirection, visible: summary.isVisible)
        }
    }

    public var constellationID: String
    public var constellationName: String
    public var brightestVisibleStars: [StarFact]
    public var planetsNearby: [PlanetFact]
    public var deepSkyObjectsInView: [DeepSkyFact]
    public var nextISSPass: PassFact?
    public var date: Date
    public var timeZoneIdentifier: String
    public var localTime: String
    /// Altitude of the constellation's centre above the horizon, degrees.
    public var constellationAltitudeDegrees: Double
    public var observerLatitude: Double
    public var observerLongitude: Double
    public var observerElevationMeters: Double
    public var daylight: DaylightState.Phase
    public var sunAltitudeDegrees: Double
    public var moonIlluminatedFraction: Double
    public var moonPhaseName: String

    /// Plain-text fact sheet for the prompt.
    public var promptText: String {
        func f(_ x: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", x) }
        var lines: [String] = []
        lines.append("Constellation: \(constellationName) (\(constellationID)), centre altitude \(f(constellationAltitudeDegrees))°")
        let stars = brightestVisibleStars.map { "\($0.name ?? "HIP \($0.hip)") (mag \(f($0.vmag, 2)))" }
        lines.append("Brightest visible stars: " + (stars.isEmpty ? "none above the horizon" : stars.joined(separator: ", ")))
        let planets = planetsNearby.map {
            "\($0.name) (mag \(f($0.magnitude)), \(f($0.separationDegrees))° from centre\($0.inConstellation ? ", inside the constellation" : ""))"
        }
        lines.append("Planets nearby: " + (planets.isEmpty ? "none" : planets.joined(separator: ", ")))
        let dsos = deepSkyObjectsInView.map { o in "\(o.name) (\(o.kind)\(o.magnitude.map { ", mag \(f($0))" } ?? ""))" }
        lines.append("Deep-sky objects in view: " + (dsos.isEmpty ? "none" : dsos.joined(separator: ", ")))
        if let p = nextISSPass {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
            fmt.dateFormat = "EEE HH:mm"
            lines.append("Next \(p.visible ? "visible " : "")\(p.name) pass: \(fmt.string(from: p.start)) from \(p.startDirection), max \(f(p.maxAltitudeDegrees, 0))° at \(fmt.string(from: p.maximum)), ends \(p.endDirection) at \(fmt.string(from: p.end))")
        } else {
            lines.append("Next ISS pass: unknown")
        }
        lines.append("Local time: \(localTime)")
        lines.append("Observer: latitude \(f(observerLatitude, 2))°, longitude \(f(observerLongitude, 2))°, elevation \(f(observerElevationMeters, 0)) m")
        lines.append("Sky: \(daylight.rawValue) (Sun altitude \(f(sunAltitudeDegrees))°), Moon: \(moonPhaseName), \(f(moonIlluminatedFraction * 100, 0))% lit")
        return lines.joined(separator: "\n")
    }
}

public enum DeepDiveFactsBuilder {
    /// Gathers the deep-dive facts. `inView` is typically `DeepSkySelection.select(...)` output for the current
    /// frame; planets within `planetRadiusDegrees` of the constellation centre are listed.
    public static func build(constellationID id: String, constellationName: String, figure: ConstellationFigure?,
                             catalog: StarCatalog, membership: ConstellationMembership, names: StarNames?,
                             session: SkySession, instant: AstroInstant, solarSystem: SolarSystemSnapshot,
                             roman: RomanLookup, inView: [DeepSkyObject], nextISSPass: DeepDiveFacts.PassFact?,
                             timeZone: TimeZone, planetRadiusDegrees: Double = 30, maxDeepSky: Int = 5) -> DeepDiveFacts {
        let icrsToENU = session.icrsToENU(at: instant)
        let namesByHip = names?.byHip ?? [:]
        func altitude(icrs v: SIMD3<Double>) -> Double {
            Angle.degrees(HorizontalCoordinates(enu: icrsToENU * SkySession.aberrate(v, beta: session.earthVelocityOverC)).altitude)
        }
        var stars: [DeepDiveFacts.StarFact] = []
        for i in membership.starIndicesByID[id] ?? [] {
            let s = catalog.stars[i]
            let alt = altitude(icrs: s.directionDouble)
            guard alt > 0 else { continue }
            stars.append(.init(hip: s.hip, name: namesByHip[s.hip]?.name, vmag: Double(s.vmag), altitudeDegrees: alt))
            if stars.count == 3 { break }
        }
        let members = membership.starIndicesByID[id] ?? []
        let centre = figure.flatMap { SkyLabels.figureCentroid($0, catalog: catalog) }
            ?? simd_normalize(members.prefix(20).map { catalog.stars[$0].directionDouble }.reduce(.zero, +))
        let centreENU = icrsToENU * centre
        let enuToOfDate = session.horizonMatrix(at: instant).transpose
        var planets: [DeepDiveFacts.PlanetFact] = []
        for p in solarSystem.bodies where p.body != .sun && p.body != .moon {
            let sep = Angle.degrees(Angle.separation(p.enu, centreENU))
            let inside = roman.constellation(icrs: session.icrs(fromApparentOfDate: enuToOfDate * p.enu)) == id
            guard sep <= planetRadiusDegrees || inside else { continue }
            planets.append(.init(name: p.body.name, magnitude: p.magnitude, separationDegrees: sep, inConstellation: inside,
                                 altitudeDegrees: Angle.degrees(p.horizontal.altitude)))
        }
        planets.sort { $0.separationDegrees < $1.separationDegrees }
        let dsos = inView.prefix(maxDeepSky).map {
            DeepDiveFacts.DeepSkyFact(name: $0.displayName, kind: $0.kind.rawValue, magnitude: $0.mag)
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd HH:mm zzz (EEEE)"
        let sun = solarSystem.position(.sun)
        return DeepDiveFacts(
            constellationID: id, constellationName: constellationName,
            brightestVisibleStars: stars, planetsNearby: planets, deepSkyObjectsInView: Array(dsos),
            nextISSPass: nextISSPass, date: instant.date, timeZoneIdentifier: timeZone.identifier,
            localTime: fmt.string(from: instant.date),
            constellationAltitudeDegrees: Angle.degrees(HorizontalCoordinates(enu: centreENU).altitude),
            observerLatitude: session.location.latitude, observerLongitude: session.location.longitude,
            observerElevationMeters: session.location.height,
            daylight: solarSystem.daylight.phase,
            sunAltitudeDegrees: sun.map { Angle.degrees($0.horizontal.altitude) } ?? solarSystem.daylight.sunAltitudeDegrees,
            moonIlluminatedFraction: solarSystem.moonPhase.illuminatedFraction, moonPhaseName: solarSystem.moonPhase.name
        )
    }
}
