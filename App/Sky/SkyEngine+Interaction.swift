import Foundation
import SkyCore
import simd

struct ObjectInfo: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var lines: [String]
    /// Set when the tap also re-aligned the compass heading.
    var alignmentNote: String?
}

struct CardStar: Identifiable, Hashable, Sendable {
    var name: String
    var vmag: Double
    var distanceLy: Double?
    var id: String { name }
}

extension SkyEngine {
    struct TapOutcome {
        var info: ObjectInfo?
        var yawDelta: Double?
    }

    private struct Target {
        var title: String
        var enu: SIMD3<Double>
        var lines: [String]
    }

    // MARK: Tap

    /// Re-aligns the heading when the tap lands within 5° of an eligible object (stars brighter than magnitude 2 at
    /// night; the Moon, Venus, Jupiter or the Sun marker by day) and returns what is under the finger.
    func handleTap(at point: SIMD2<Double>, context: OverlayContext, canAlign: Bool, headingAccuracy: Double?) -> TapOutcome {
        guard let data, let observer = context.observer else { return TapOutcome() }
        let session = session(for: context.skyDate, observer: observer)
        let instant = AstroInstant(date: context.skyDate)
        let icrsToENU = session.icrsToENU(at: instant)
        let beta = session.earthVelocityOverC
        let projector = context.projector
        func apparent(icrs v: SIMD3<Double>) -> SIMD3<Double> {
            refraction.apparent(enu: icrsToENU * SkySession.aberrate(v, beta: beta))
        }

        var targets: [Target] = []
        var candidates: [AlignmentCandidate] = []
        let solarSystem = solarSystem(date: context.skyDate, instant: instant, session: session)
        if let solarSystem {
            let horizon = session.horizonMatrix(at: instant)
            for body in solarSystem.bodies {
                let enu = refraction.apparent(enu: horizon * body.ofDate)
                guard enu.z > -0.01 else { continue }
                let kind: AlignmentCandidate.Kind = switch body.body {
                case .sun: .sun
                case .moon: .moon
                default: .planet(body.body)
                }
                candidates.append(AlignmentCandidate(kind: kind, name: body.body.name, magnitude: body.magnitude, enu: enu))
                targets.append(Target(title: body.body.name, enu: enu, lines: Self.bodyLines(body, solarSystem: solarSystem, enu: enu)))
            }
        }
        for i in data.brightStarIndices {
            let enu = apparent(icrs: data.directions[i])
            guard enu.z > -0.01 else { continue }
            let star = data.catalog.stars[i]
            candidates.append(AlignmentCandidate(kind: .star(hip: star.hip), name: data.displayName(hip: star.hip) ?? "HIP \(star.hip)",
                                                 magnitude: Double(star.vmag), enu: enu))
        }
        for label in data.starLabels {
            guard let i = data.hipIndex[label.hip] else { continue }
            let enu = apparent(icrs: data.directions[i])
            guard enu.z > -0.01 else { continue }
            targets.append(Target(title: label.name, enu: enu, lines: starLines(index: i, enu: enu, data: data, session: session, instant: instant)))
        }
        if let iss = satellites.snapshot?.samples.first(where: \.isISS),
           let enu = satellites.enu(of: iss, at: context.skyDate), enu.z > -0.01 {
            let apparentENU = refraction.apparent(enu: enu)
            let (az, alt) = Self.azimuthAltitude(apparentENU)
            targets.append(Target(title: "International Space Station", enu: apparentENU, lines: [
                String(format: "Altitude %.0f°, azimuth %.0f° (%@)", alt, az, CompassDirection.name(azimuthDegrees: az)),
                iss.visible ? "Sunlit against a dark sky: visible now." : (iss.sunlit ? "Sunlit, but the sky is too bright to see it." : "In Earth's shadow: not visible."),
            ]))
        }
        for item in DeepSkySelection().select(data.deepSky.objects, projector: projector, icrsToENU: icrsToENU, refraction: refraction,
                                              horizontalFOVDegrees: horizontalFieldOfView(projector)) {
            let o = item.object
            let enu = apparent(icrs: o.direction)
            var lines = [o.kind.rawValue.capitalized + (o.mag.map { String(format: ", magnitude %.1f", $0) } ?? "")]
            let (az, alt) = Self.azimuthAltitude(enu)
            lines.append(String(format: "Altitude %.0f°, azimuth %.0f° (%@)", alt, az, CompassDirection.name(azimuthDegrees: az)))
            targets.append(Target(title: o.displayName, enu: enu, lines: lines))
        }

        var outcome = TapOutcome()
        let mode = context.lighting <= 0.02 ? AlignmentMode.day : (context.lighting >= 0.98 ? .night : .twilight)
        var alignedName: String?
        if canAlign, let result = TapToAlign.align(tap: point, pose: CameraPose(referenceToDevice: context.deviceFromReference),
                                                   intrinsics: context.camera.skyIntrinsics, mapping: context.camera.mapping,
                                                   candidates: candidates, mode: mode, headingAccuracy: headingAccuracy) {
            outcome.yawDelta = result.yawDelta
            alignedName = result.candidate.name
        }

        let reach = 44 * context.contentScale
        var best: (Target, Double)?
        for target in targets {
            guard let p = projector.screenPoint(enu: target.enu) else { continue }
            let d = simd_distance(p, point)
            if d <= reach, d < (best?.1 ?? .infinity) { best = (target, d) }
        }
        let named = alignedName.flatMap { name in targets.first { $0.title == name } }
        if let target = named ?? best?.0 {
            outcome.info = ObjectInfo(title: target.title, lines: target.lines)
        }
        if let alignedName, let yaw = outcome.yawDelta {
            let note = String(format: "Heading aligned on %@ (%+.1f°).", alignedName, Angle.degrees(yaw))
            if outcome.info != nil { outcome.info?.alignmentNote = note } else { outcome.info = ObjectInfo(title: alignedName, lines: [], alignmentNote: note) }
        }
        return outcome
    }

    private static func azimuthAltitude(_ enu: SIMD3<Double>) -> (azimuth: Double, altitude: Double) {
        let h = HorizontalCoordinates(enu: enu)
        return (Angle.degrees(h.azimuth), Angle.degrees(h.altitude))
    }

    private static func bodyLines(_ body: SolarSystemPosition, solarSystem: SolarSystemSnapshot, enu: SIMD3<Double>) -> [String] {
        let (az, alt) = azimuthAltitude(enu)
        let position = String(format: "Altitude %.0f°, azimuth %.0f° (%@)", alt, az, CompassDirection.name(azimuthDegrees: az))
        switch body.body {
        case .sun:
            return [position, "Never look at the Sun. The phone only marks where it is."]
        case .moon:
            let phase = solarSystem.moonPhase
            return [position, "\(phase.name), \(Int((phase.illuminatedFraction * 100).rounded()))% lit, \(phase.isWaxing ? "waxing" : "waning")."]
        default:
            return [position, String(format: "Magnitude %.1f, %.2f AU away.", body.magnitude, body.distanceAU)]
        }
    }

    private func starLines(index i: Int, enu: SIMD3<Double>, data: SkyData, session: SkySession, instant: AstroInstant) -> [String] {
        let star = data.catalog.stars[i]
        let (az, alt) = Self.azimuthAltitude(enu)
        var lines = [String(format: "Star, magnitude %.2f", star.vmag) + (data.distanceLightYears(starIndex: i).map { String(format: ", %.0f light years", $0) } ?? "")]
        if let id = data.roman.constellation(icrs: data.directions[i]) { lines.append("In \(data.name(ofConstellation: id)).") }
        lines.append(String(format: "Altitude %.0f°, azimuth %.0f° (%@)", alt, az, CompassDirection.name(azimuthDegrees: az)))
        return lines
    }

    // MARK: Readout

    func readout(_ context: OverlayContext) -> SkyReadout {
        guard let data, let observer = context.observer else { return SkyReadout() }
        let session = session(for: context.skyDate, observer: observer)
        let instant = AstroInstant(date: context.skyDate)
        let apparent = context.projector.ray(screenPoint: context.projector.viewCenter)
        let icrs = ConstellationScorer.icrs(fromENU: refraction.unrefracted(enu: apparent), session: session, at: instant)
        let (ra, dec) = icrs.lonLat
        let raHours = Angle.degrees(ra) / 15
        let decDegrees = Angle.degrees(dec)
        let lst = Angle.degrees(session.localSiderealTime(at: instant)) / 15
        var readout = SkyReadout()
        readout.raDec = Self.hms(raHours) + " " + Self.dms(decDegrees) + " (J2000)"
        readout.siderealTime = Self.hms(lst)
        readout.constellation = data.roman.constellation(icrs: icrs).map { data.name(ofConstellation: $0) } ?? "unknown"
        return readout
    }

    private static func hms(_ hours: Double) -> String {
        let total = Int((hours * 3600).rounded()) % 86_400
        return String(format: "%02dh %02dm %02ds", total / 3600, total % 3600 / 60, total % 60)
    }

    private static func dms(_ degrees: Double) -> String {
        let total = Int((abs(degrees) * 3600).rounded())
        return String(format: "%@%02d° %02d′ %02d″", degrees < 0 ? "−" : "+", total / 3600, total % 3600 / 60, total % 60)
    }

    // MARK: Constellation card

    /// Brightest stars of a constellation from the catalog (the card's fallback when narration is missing).
    func catalogStars(for id: String, limit: Int = 3) -> [CardStar] {
        guard let data else { return [] }
        return (data.membership.starIndicesByID[id] ?? []).prefix(limit).map { i in
            let star = data.catalog.stars[i]
            return CardStar(name: data.displayName(hip: star.hip) ?? "HIP \(star.hip)", vmag: Double(star.vmag),
                            distanceLy: data.distanceLightYears(starIndex: i))
        }
    }

    func constellationName(_ id: String) -> String { data?.name(ofConstellation: id) ?? id }

    func narrationCard(_ id: String) -> NarrationFile.Card? { data?.narration?.card(id: id) }

    var hasNarrationFile: Bool { data?.narration != nil }

    /// Facts for the "Tell me more" prompt, from the frame the user is looking at.
    func deepDiveFacts(for id: String, context: OverlayContext) -> DeepDiveFacts? {
        guard let data, let observer = context.observer else { return nil }
        let session = session(for: context.skyDate, observer: observer)
        let instant = AstroInstant(date: context.skyDate)
        guard let solarSystem = solarSystem(date: context.skyDate, instant: instant, session: session) else { return nil }
        let inView = DeepSkySelection().select(data.deepSky.objects, projector: context.projector, icrsToENU: session.icrsToENU(at: instant),
                                               refraction: refraction, horizontalFOVDegrees: horizontalFieldOfView(context.projector))
            .map(\.object)
        return DeepDiveFactsBuilder.build(
            constellationID: id, constellationName: data.name(ofConstellation: id), figure: data.figureByID[id], catalog: data.catalog,
            membership: data.membership, names: data.names, session: session, instant: instant, solarSystem: solarSystem,
            roman: data.roman, inView: inView, nextISSPass: satellites.nextISSPass.map(DeepDiveFacts.PassFact.init),
            timeZone: .current)
    }
}
