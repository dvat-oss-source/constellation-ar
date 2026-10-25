import Foundation
import Observation
import SkyCore
import simd

/// Tap-to-focus: normal sky taps pick a constellation; Align mode performs one tap-to-align then returns here.
@MainActor
@Observable
final class ConstellationFocus {
    enum SkyTapMode: String, CaseIterable, Identifiable {
        case explore = "Explore"
        case align = "Align"
        var id: Self { self }
    }

    enum PinState: Equatable {
        case auto
        case pinned(String)
    }

    let resources = FocusResources()
    var tapMode: SkyTapMode = .explore
    private(set) var pinState: PinState = .auto
    private(set) var pinnedName: String?

    var pinnedID: String? {
        if case .pinned(let id) = pinState { return id }
        return nil
    }

    var isPinned: Bool { pinnedID != nil }

    func load() { resources.load() }

    func dismissPin() {
        pinState = .auto
        pinnedName = nil
    }

    func pin(constellation id: String, name: String) {
        pinState = .pinned(id)
        pinnedName = name
    }

    /// Screen tap → IAU constellation id via boundary hit test.
    func constellation(at point: SIMD2<Double>, engine: SkyEngine, context: OverlayContext) -> (id: String, name: String)? {
        guard let hitTest = resources.hitTest, let data = engine.dataForFocus else { return nil }
        guard let observer = context.observer else { return nil }
        let session = engine.session(for: context.skyDate, observer: observer)
        let instant = AstroInstant(date: context.skyDate)
        let ref = context.referenceDirection(screen: point)
        let enu = OverlayContext.enu(reference: ref)
        let icrs = ConstellationScorer.icrs(fromENU: engine.refractionForFocus.unrefracted(enu: enu), session: session, at: instant)
        guard let hit = hitTest.hit(icrs: icrs) else { return nil }
        let name = data.name(ofConstellation: hit.constellation)
        return (hit.constellation, name)
    }

    func facts(for id: String, context: OverlayContext, engine: SkyEngine) -> ConstellationFacts? {
        guard let atlas = resources.atlas, let observer = context.observer else { return nil }
        let instant = AstroInstant(date: context.skyDate)
        let geo = GeoLocation(latitude: observer.latitude, longitude: observer.longitude, height: observer.altitude)
        return try? atlas.facts(for: id, location: geo, at: instant)
    }

    func pinnedEdgeScreenPoint(context: OverlayContext, engine: SkyEngine) -> SIMD2<Double>? {
        guard let id = pinnedID, let atlas = resources.atlas else { return nil }
        return FocusEdgeArrow.referenceScreenPoint(id: id, atlas: atlas, engine: engine, context: context)
    }
}
