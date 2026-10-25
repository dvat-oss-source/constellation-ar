import QuartzCore
import SkyCore
import UIKit
import simd

enum SkyEvent {
    case locked(id: String, narrate: Bool)
    case unlocked(id: String)
}

/// Turns catalogs + the frame's projector into overlay batches, in the spec's draw order (back → front): Milky Way,
/// artwork, constellation lines, asterisms, stars, deep-sky objects, planets/Sun/Moon, satellites, labels.
/// Owns the per-session sky transform, the constellation lock and the solar-system snapshot.
@MainActor
final class SkyEngine {
    let layers: LayerSettings
    let satellites: SatelliteTracker
    var onEvent: ((SkyEvent) -> Void)?

    private(set) var data: SkyData? {
        didSet { coordinator = data.map { ConstellationLockCoordinator(schedules: $0.schedules, seed: 0x5EED) } }
    }

    let refraction = Refraction.standard
    private(set) var session: SkySession?
    /// Catalog directions with annual aberration applied (ICRS axes); valid for `session`.
    private var aberrated: [SIMD3<Double>] = []
    /// Apparent (refracted) ENU of every figure star for the current frame, indexed by catalog index.
    private var figureENU: [SIMD3<Double>] = []
    private var coordinator: ConstellationLockCoordinator<SplitMix64>?
    /// User-pinned constellation; overrides automatic lock scoring until cleared.
    var focusOverrideID: String?
    private var solar: (snapshot: SolarSystemSnapshot, date: Date, latitude: Double, longitude: Double)?
    private var nightCache: (date: Date, latitude: Double, longitude: Double, factor: Double)?
    private var artworkVertices: [String: [ArtworkPlacement.Vertex]] = [:]
    private(set) var lockedID: String?
    /// Exponential average of the overlay build time, milliseconds.
    private(set) var frameMilliseconds = 0.0

    init(layers: LayerSettings, satellites: SatelliteTracker) {
        self.layers = layers
        self.satellites = satellites
    }

    func install(_ data: SkyData) {
        self.data = data
        session = nil
        figureENU = Array(repeating: .zero, count: data.catalog.stars.count)
    }

    // MARK: Session and solar system

    func session(for date: Date, observer: ObserverLocation) -> SkySession {
        if let session, abs(date.timeIntervalSince(session.epoch.date)) < 86_400,
           abs(session.location.latitude - observer.latitude) < 0.001, abs(session.location.longitude - observer.longitude) < 0.001 {
            return session
        }
        let fresh = SkySession(date: date, location: GeoLocation(latitude: observer.latitude, longitude: observer.longitude,
                                                                 height: observer.altitude))
        session = fresh
        aberrated = data?.directions.map { SkySession.aberrate($0, beta: fresh.earthVelocityOverC) } ?? []
        return fresh
    }

    /// 0 (day) … 1 (night) from the Sun's altitude; recomputed at most every few seconds of sky time.
    func nightFactor(date: Date, observer: ObserverLocation?) -> Double {
        guard let observer else { return 0 }
        if let cache = nightCache, abs(date.timeIntervalSince(cache.date)) < 5,
           abs(cache.latitude - observer.latitude) < 0.05, abs(cache.longitude - observer.longitude) < 0.05 {
            return cache.factor
        }
        let session = session(for: date, observer: observer)
        let altitude = (try? SolarSystem.sunAltitudeDegrees(at: AstroInstant(date: date), session: session)) ?? 0
        let factor = DaylightState(sunAltitudeDegrees: altitude).nightFactor
        nightCache = (date, observer.latitude, observer.longitude, factor)
        return factor
    }

    func solarSystem(date: Date, instant: AstroInstant, session: SkySession) -> SolarSystemSnapshot? {
        let location = session.location
        if let solar, abs(date.timeIntervalSince(solar.date)) < 2,
           abs(solar.latitude - location.latitude) < 0.01, abs(solar.longitude - location.longitude) < 0.01 {
            return solar.snapshot
        }
        guard let snapshot = try? SolarSystem.snapshot(at: instant, session: session) else { return solar?.snapshot }
        solar = (snapshot, date, location.latitude, location.longitude)
        return snapshot
    }

    // MARK: Frame

    func frame(_ context: OverlayContext) -> OverlayFrame {
        guard let data, let observer = context.observer else { return HorizonOverlay.frame(context) }
        let started = CACurrentMediaTime()
        defer { frameMilliseconds = frameMilliseconds * 0.95 + (CACurrentMediaTime() - started) * 1000 * 0.05 }

        let date = context.skyDate
        let session = session(for: date, observer: observer)
        let instant = AstroInstant(date: date)
        let icrsToENU = session.icrsToENU(at: instant)
        let projector = context.projector
        let style = SkyStyle(night: Float(context.lighting), px: Float(context.contentScale))
        let isNight = context.lighting >= 0.5
        func on(_ layer: SkyLayer) -> Bool { layers.isOn(layer, night: isNight) }

        let visuals = updateLock(context: context, data: data, session: session, instant: instant, icrsToENU: icrsToENU)
        let beta = session.earthVelocityOverC
        func apparent(icrs v: SIMD3<Double>) -> SIMD3<Double> {
            refraction.apparent(enu: icrsToENU * SkySession.aberrate(v, beta: beta))
        }
        for i in data.figureStarIndices { figureENU[i] = refraction.apparent(enu: icrsToENU * aberrated[i]) }

        var frame = OverlayFrame()
        var placer = LabelPlacer(viewport: context.camera.drawableSize, contentScale: context.contentScale)
        let center = projector.viewCenter
        let viewDirection = projector.ray(screenPoint: center)
        let cullCos = cos(projector.halfDiagonalAngle + 0.03)

        // Milky Way
        if on(.milkyWay), context.lighting > 0.02 {
            let icrsFromScreen = icrsToENU.transpose * context.enuFromScreen
            frame.add(OverlayMilkyWay(icrsFromScreen: Self.float(icrsFromScreen), intensity: Float(context.lighting)))
        }

        // Artwork of the locked constellation
        if on(.artwork) {
            for visual in visuals where visual.artwork > 0.01 {
                if let mesh = artworkMesh(for: visual.id, alpha: Float(visual.artwork) * 0.55, data: data, projector: projector,
                                          icrsToENU: icrsToENU, beta: beta) {
                    frame.add(mesh)
                }
            }
        }

        // Constellation lines: dim resting figures, then the locked figure's draw-in on top.
        var highlightPoints: [OverlayPoint] = []
        if on(.lines) {
            var resting: [OverlaySegment] = []
            resting.reserveCapacity(800)
            for figure in data.figures {
                for (a, b) in figure.pairs {
                    let pa = figureENU[a], pb = figureENU[b]
                    if pa.z < -0.02 && pb.z < -0.02 { continue }
                    guard let c = projector.clipSegment(pa, pb) else { continue }
                    resting.append(OverlaySegment(a: SIMD2<Float>(c.start), b: SIMD2<Float>(c.end), width: style.lineWidth,
                                                  color: style.restingLineColor, outlineWidth: style.lineOutline,
                                                  glow: StyleTokens.restingLineGlow))
                }
            }
            frame.add(resting)

            var lit: [OverlaySegment] = []
            for visual in visuals {
                for seg in visual.segments where seg.alpha > 0.01 && seg.progress > 0 {
                    guard let a = data.hipIndex[seg.fromHip], let b = data.hipIndex[seg.toHip] else { continue }
                    let from = figureENU[a], to = figureENU[b]
                    guard let c = projector.drawnPart(of: seg, from: from, to: to) else { continue }
                    var color = style.highlightColor
                    color.w = Float(seg.alpha)
                    lit.append(OverlaySegment(a: SIMD2<Float>(c.start), b: SIMD2<Float>(c.end), width: style.litLineWidth, color: color,
                                              outlineWidth: style.lineOutline, glow: StyleTokens.litLineGlow * Float(0.45 * seg.alpha + 0.55 * seg.glow)))
                    if seg.glow > 0.05 {
                        let tip = simd_normalize(simd_normalize(from) + seg.glowPosition * (simd_normalize(to) - simd_normalize(from)))
                        if let p = projector.screenPoint(enu: tip), projector.isOnScreen(p, margin: 30) {
                            highlightPoints.append(OverlayPoint(position: SIMD2<Float>(p), radius: (3 + 6 * Float(seg.glow)) * style.px,
                                                                color: SIMD4(1, 1, 1, Float(seg.glow))))
                        }
                    }
                }
                for star in visual.stars where star.alpha > 0.01 {
                    guard let i = data.hipIndex[star.hip], let p = projector.screenPoint(enu: figureENU[i]),
                          projector.isOnScreen(p, margin: 30), figureENU[i].z > -0.02 else { continue }
                    let radius = max(1.6, 0.42 * (6.5 - data.styles[i].vmag)) * 1.5 * style.px
                    highlightPoints.append(OverlayPoint(position: SIMD2<Float>(p), radius: radius,
                                                        color: SIMD4(1, 1, 1, Float(star.alpha))))
                }
            }
            frame.add(lit)
        }

        // Asterisms
        if on(.asterisms) {
            let fov = horizontalFieldOfView(projector)
            var dashes: [OverlaySegment] = []
            for entry in data.asterisms where entry.asterism.priority <= (fov < 30 ? 6 : 3) {
                for line in projector.project(icrsPolylines: entry.polylines, icrsToENU: icrsToENU, refraction: refraction) {
                    var travelled: Float = 0
                    for k in 0..<(line.count - 1) {
                        let a = SIMD2<Float>(line[k]), b = SIMD2<Float>(line[k + 1])
                        dashes.append(OverlaySegment(a: a, b: b, width: 1.2 * style.px, color: SIMD4(1.0, 0.82, 0.5, 0.35 + 0.4 * (1 - style.night)),
                                                     outlineWidth: style.lineOutline * 0.6, dashed: true, dashPhase: travelled))
                        travelled += simd_distance(a, b)
                    }
                }
            }
            frame.add(dashes)
        }

        // Stars (the catalog is sorted brightest first, so the magnitude cut ends the loop)
        let magnitudeLimit = Float(2.0 + 4.5 * context.lighting)
        if on(.stars) {
            var points: [OverlayPoint] = []
            points.reserveCapacity(2500)
            for i in data.styles.indices {
                let star = data.styles[i]
                if star.vmag > magnitudeLimit { break }
                let enu = icrsToENU * aberrated[i]
                if enu.z < -0.01 || simd_dot(enu, viewDirection) < cullCos { continue }
                guard let p = projector.screenPoint(enu: refraction.apparent(enu: enu)), projector.isOnScreen(p, margin: 24) else { continue }
                let radius = max(0.9, 0.42 * (6.5 - star.vmag)) * style.px
                points.append(OverlayPoint(position: SIMD2<Float>(p), radius: radius,
                                           color: SIMD4(star.tint, min(1, 0.55 + 0.2 * (6.5 - star.vmag)))))
            }
            frame.add(points)
        }
        frame.add(highlightPoints)

        // Deep-sky objects
        var dsoSelection: [VisibleDeepSkyObject] = []
        if on(.deepSky) || on(.labels) {
            dsoSelection = DeepSkySelection().select(data.deepSky.objects, projector: projector, icrsToENU: icrsToENU,
                                                     refraction: refraction, horizontalFOVDegrees: horizontalFieldOfView(projector))
        }
        if on(.deepSky) {
            var symbols: [OverlaySegment] = []
            for item in dsoSelection {
                let o = item.object
                let c = SIMD2<Float>(item.screenPoint)
                let radius = max(6 * style.px, min(Float(item.majorAxisPoints) / 2, 44 * style.px))
                let ratio = Float((o.minAxArcmin ?? 0) / max(o.majAxArcmin ?? 0, 0.01))
                symbols += SkySymbols.segments(kind: o.kind, center: c, radius: radius, axisRatio: ratio > 0 ? ratio : 0.5,
                                               majorAxis: galaxyAxis(of: o, projector: projector, icrsToENU: icrsToENU, beta: beta, at: item.screenPoint),
                                               width: 1.1 * style.px, color: SkySymbols.color(for: o.kind))
            }
            frame.add(symbols)
        }

        // Planets, Sun and Moon
        let solarSystem = solarSystem(date: date, instant: instant, session: session)
        var bodyPoints: [OverlayPoint] = []
        if on(.planets), let solarSystem {
            let horizon = session.horizonMatrix(at: instant)
            for body in solarSystem.bodies {
                let enu = refraction.apparent(enu: horizon * body.ofDate)
                guard enu.z > -0.01, let p = projector.screenPoint(enu: enu), projector.isOnScreen(p, margin: 40) else { continue }
                let marker = bodyMarker(body, solarSystem: solarSystem, style: style, projector: projector)
                bodyPoints.append(OverlayPoint(position: SIMD2<Float>(p), radius: marker.radius, color: marker.color, style: marker.style))
                if on(.labels) {
                    placer.add(OverlayLabel(text: marker.label, position: SIMD2<Float>(p) + SIMD2(marker.radius + 5 * style.px, 0),
                                            color: SIMD4(1, 0.95, 0.8, 1), fontSize: 13, anchor: SIMD2(0, 0.5), bold: true), priority: 80)
                }
            }
        }
        frame.add(bodyPoints)

        // Satellites
        if on(.satellites) { addSatellites(to: &frame, placer: &placer, context: context, style: style, labels: on(.labels)) }

        // Labels
        if on(.labels) {
            addLabels(to: &placer, data: data, context: context, style: style, icrsToENU: icrsToENU, beta: beta, visuals: visuals,
                      viewDirection: viewDirection, cullCos: cullCos, dso: on(.deepSky) ? dsoSelection : [])
        }
        frame.add(placer.place())
        return frame
    }

    // MARK: Lock

    private func updateLock(context: OverlayContext, data: SkyData, session: SkySession, instant: AstroInstant,
                            icrsToENU: simd_double3x3) -> [ConstellationVisual] {
        guard var coordinator else { return [] }
        let projector = context.projector
        coordinator.timeline.reduceMotion = UIAccessibility.isReduceMotionEnabled
        let official = ConstellationScorer.officialConstellation(enu: projector.ray(screenPoint: projector.viewCenter),
                                                                 session: session, at: instant, roman: data.roman)
        var scores = data.scorer.scores(projector: projector, skyToENU: icrsToENU, officialID: official)
        if let override = focusOverrideID {
            for key in scores.keys { scores[key] = key == override ? 1.0 : 0.0 }
            if scores[override] == nil { scores[override] = 1.0 }
        }
        let update = coordinator.update(time: context.displayTime, scores: scores)
        let visuals = coordinator.frame(at: context.displayTime)
        self.coordinator = coordinator

        lockedID = coordinator.currentLock
        for event in update.events {
            switch event {
            case .locked(let id), .changed(from: _, to: let id): onEvent?(.locked(id: id, narrate: update.narrate == id))
            case .unlocked(let id): onEvent?(.unlocked(id: id))
            }
        }
        return visuals
    }

    /// Immediate draw-in for a user-pinned constellation.
    func applyFocusPin(_ id: String?, context: OverlayContext) {
        focusOverrideID = id
        guard let id, var coordinator, let data else { return }
        var scores: [String: Double] = [:]
        for figure in data.figures { scores[figure.id] = figure.id == id ? 1.0 : 0.0 }
        let t = context.displayTime
        _ = coordinator.update(time: t, scores: scores)
        let update = coordinator.update(time: t + 0.35, scores: scores)
        self.coordinator = coordinator
        lockedID = coordinator.currentLock
        for event in update.events {
            switch event {
            case .locked(let lid), .changed(from: _, to: let lid):
                onEvent?(.locked(id: lid, narrate: false))
            case .unlocked: break
            }
        }
        if coordinator.currentLock == nil { onEvent?(.locked(id: id, narrate: false)) }
    }

    // MARK: Pieces

    private func artworkMesh(for id: String, alpha: Float, data: SkyData, projector: Projector, icrsToENU: simd_double3x3,
                             beta: SIMD3<Double>) -> OverlayMesh? {
        guard let info = data.artwork[id], let placement = data.placements[id] else { return nil }
        let columns = 8, rows = 8
        let grid: [ArtworkPlacement.Vertex]
        if let cached = artworkVertices[id] {
            grid = cached
        } else {
            grid = placement.mesh(columns: columns, rows: rows)
            artworkVertices[id] = grid
        }
        let screen = grid.map { v -> SIMD2<Double>? in
            let enu = refraction.apparent(enu: icrsToENU * SkySession.aberrate(SIMD3<Double>(v.direction), beta: beta))
            return projector.screenPoint(enu: enu)
        }
        var vertices: [OverlayMeshVertex] = []
        vertices.reserveCapacity(columns * rows * 6)
        func corner(_ index: Int) -> OverlayMeshVertex? {
            screen[index].map { OverlayMeshVertex(position: SIMD2<Float>($0), uv: grid[index].uv) }
        }
        for j in 0..<rows {
            for i in 0..<columns {
                let a = j * (columns + 1) + i, b = a + 1, c = a + columns + 1, d = c + 1
                for tri in [[a, c, b], [b, c, d]] {
                    if let v0 = corner(tri[0]), let v1 = corner(tri[1]), let v2 = corner(tri[2]) { vertices += [v0, v1, v2] }
                }
            }
        }
        return OverlayMesh(textureID: info.file, vertices: vertices, alpha: alpha)
    }

    private struct BodyMarker {
        var radius: Float
        var color: SIMD4<Float>
        var style: Float
        var label: String
    }

    private func bodyMarker(_ body: SolarSystemPosition, solarSystem: SolarSystemSnapshot, style: SkyStyle,
                            projector: Projector) -> BodyMarker {
        let px = style.px
        switch body.body {
        case .sun:
            return BodyMarker(radius: 11 * px, color: SIMD4(1, 0.86, 0.42, 1), style: 0, label: "Sun")
        case .moon:
            let pixelsPerDegree = Float(projector.intrinsics.fx * projector.mapping.scale * .pi / 180)
            let radius = min(max(Float(body.angularDiameterDegrees) / 2 * pixelsPerDegree, 10 * px), 30 * px)
            let phase = solarSystem.moonPhase
            return BodyMarker(radius: radius, color: SIMD4(0.95, 0.95, 0.88, 1),
                              style: OverlayPoint.moonStyle(illuminatedFraction: phase.illuminatedFraction, waxing: phase.isWaxing),
                              label: "Moon \(Int((phase.illuminatedFraction * 100).rounded()))%")
        default:
            let radius = min(max(3.4 - 0.45 * Float(body.magnitude), 2.6), 6.2) * px
            return BodyMarker(radius: radius, color: Self.planetColor(body.body), style: 0, label: body.body.name)
        }
    }

    static func planetColor(_ body: SolarSystemBody) -> SIMD4<Float> {
        switch body {
        case .mercury: SIMD4(0.82, 0.8, 0.78, 1)
        case .venus: SIMD4(1, 0.97, 0.85, 1)
        case .mars: SIMD4(1, 0.55, 0.4, 1)
        case .jupiter: SIMD4(1, 0.9, 0.75, 1)
        case .saturn: SIMD4(0.95, 0.85, 0.6, 1)
        case .uranus: SIMD4(0.7, 0.95, 1, 1)
        case .neptune: SIMD4(0.6, 0.7, 1, 1)
        case .sun, .moon: SIMD4(1, 1, 1, 1)
        }
    }

    private func addSatellites(to frame: inout OverlayFrame, placer: inout LabelPlacer, context: OverlayContext,
                               style: SkyStyle, labels: Bool) {
        guard let snapshot = satellites.snapshot else { return }
        let projector = context.projector
        var points: [OverlayPoint] = []
        for sample in snapshot.samples where sample.visible || sample.isISS {
            guard let enu = satellites.enu(of: sample, at: context.skyDate), enu.z > -0.01,
                  let p = projector.screenPoint(enu: refraction.apparent(enu: enu)), projector.isOnScreen(p, margin: 30) else { continue }
            let color: SIMD4<Float> = sample.visible ? SIMD4(0.7, 1, 0.9, 1) : SIMD4(0.65, 0.7, 0.75, 0.55)
            points.append(OverlayPoint(position: SIMD2<Float>(p), radius: (sample.isISS ? 4.2 : 2.4) * style.px, color: color))
            if labels, sample.isISS {
                placer.add(OverlayLabel(text: sample.visible ? "ISS" : "ISS (not visible)", position: SIMD2<Float>(p) + SIMD2(8 * style.px, 0),
                                        color: color, fontSize: 12, anchor: SIMD2(0, 0.5), bold: true), priority: 70)
            }
        }
        if let iss = snapshot.samples.first(where: \.isISS) {
            let path = snapshot.issPath.map { refraction.apparent(enu: $0.enu) }
            var dashes: [OverlaySegment] = []
            let color: SIMD4<Float> = iss.visible ? SIMD4(0.7, 1, 0.9, 0.7) : SIMD4(0.65, 0.7, 0.75, 0.4)
            for line in projector.clipPolyline(path) {
                var travelled: Float = 0
                for k in 0..<(line.count - 1) {
                    let a = SIMD2<Float>(line[k]), b = SIMD2<Float>(line[k + 1])
                    dashes.append(OverlaySegment(a: a, b: b, width: 1.4 * style.px, color: color,
                                                 outlineWidth: style.lineOutline * 0.6, dashed: true, dashPhase: travelled))
                    travelled += simd_distance(a, b)
                }
            }
            frame.add(dashes)
        }
        frame.add(points)
    }

    private func addLabels(to placer: inout LabelPlacer, data: SkyData, context: OverlayContext, style: SkyStyle,
                           icrsToENU: simd_double3x3, beta: SIMD3<Double>, visuals: [ConstellationVisual],
                           viewDirection: SIMD3<Double>, cullCos: Double, dso: [VisibleDeepSkyObject]) {
        let projector = context.projector
        let px = style.px
        for label in data.starLabels {
            guard let i = data.hipIndex[label.hip] else { continue }
            let enu = icrsToENU * aberrated[i]
            if enu.z < 0 || simd_dot(enu, viewDirection) < cullCos { continue }
            guard let p = projector.screenPoint(enu: refraction.apparent(enu: enu)), projector.isOnScreen(p) else { continue }
            let radius = max(0.9, 0.42 * (6.5 - data.styles[i].vmag)) * px
            placer.add(OverlayLabel(text: label.name, position: SIMD2<Float>(p) + SIMD2(radius + 4 * px, 0),
                                    color: style.labelColor, fontSize: 12, anchor: SIMD2(0, 0.5)),
                       priority: 40 - Float(label.vmag))
        }
        let lockedLabel = Dictionary(visuals.map { ($0.id, $0.label) }, uniquingKeysWith: max)
        for figure in data.figures {
            guard let centroid = figure.centroid else { continue }
            let enu = refraction.apparent(enu: icrsToENU * SkySession.aberrate(centroid, beta: beta))
            guard enu.z > 0, let p = projector.screenPoint(enu: enu), projector.isOnScreen(p, margin: -10) else { continue }
            let emphasis = Float(lockedLabel[figure.id] ?? 0)
            var color = SIMD4<Float>(0.7, 0.8, 1.0, 0.55 + 0.45 * emphasis)
            if emphasis > 0 { color = SIMD4(1, 1, 1, 0.55 + 0.45 * emphasis) }
            placer.add(OverlayLabel(text: figure.name.uppercased(), position: SIMD2<Float>(p), color: color,
                                    fontSize: 12 + 5 * emphasis, bold: emphasis > 0.3),
                       priority: emphasis > 0 ? 30 + emphasis : 10,
                       fallbacks: [SIMD2(0, 26), SIMD2(0, -26), SIMD2(0, 52), SIMD2(0, -52)])
        }
        for item in dso where item.object.messier != nil {
            let c = SIMD2<Float>(item.screenPoint)
            let radius = max(6 * px, min(Float(item.majorAxisPoints) / 2, 44 * px))
            placer.add(OverlayLabel(text: "M\(item.object.messier!)", position: c + SIMD2(radius + 4 * px, 0),
                                    color: SkySymbols.color(for: item.object.kind), fontSize: 11, anchor: SIMD2(0, 0.5)), priority: 5)
        }
    }

    /// Unit screen direction of a galaxy's long axis (position angle runs from celestial north toward east).
    private func galaxyAxis(of o: DeepSkyObject, projector: Projector, icrsToENU: simd_double3x3, beta: SIMD3<Double>,
                            at screen: SIMD2<Double>) -> SIMD2<Float> {
        guard o.kind == .galaxy, let pa = o.posAngle else { return SIMD2(1, 0) }
        let v = o.direction
        let northPole = SIMD3<Double>(0, 0, 1)
        let towardNorth = northPole - simd_dot(northPole, v) * v
        guard simd_length(towardNorth) > 1e-9 else { return SIMD2(1, 0) }
        let nudged = simd_normalize(v + 0.002 * simd_normalize(towardNorth))
        let enu = refraction.apparent(enu: icrsToENU * SkySession.aberrate(nudged, beta: beta))
        guard let p = projector.screenPoint(enu: enu), simd_distance(p, screen) > 1e-6 else { return SIMD2(1, 0) }
        let n = simd_normalize(p - screen)
        let east = SIMD2<Double>(n.y, -n.x)
        let angle = Angle.radians(pa)
        return SIMD2<Float>(n * cos(angle) + east * sin(angle))
    }

    func horizontalFieldOfView(_ projector: Projector) -> Double {
        let y = projector.mapping.viewSize.y / 2, x = projector.mapping.viewSize.x
        return Angle.degrees(Angle.separation(projector.ray(screenPoint: SIMD2(0, y)), projector.ray(screenPoint: SIMD2(x, y))))
    }

    static func float(_ m: simd_double3x3) -> simd_float3x3 {
        simd_float3x3(SIMD3<Float>(m.columns.0), SIMD3<Float>(m.columns.1), SIMD3<Float>(m.columns.2))
    }
}
