import Foundation
import Testing
import simd
@testable import SkyCore

@Suite struct SolarSystemTests {
    static let fixturePath = "Data/fixtures/horizons.json"

    @Test(.enabled(if: RepoFiles.exists(fixturePath)))
    func astronomyKitMatchesHorizons() throws {
        let f = try RepoFiles.decode(HorizonsFixture.self, Self.fixturePath)
        var worst: [String: Double] = [:]
        for e in f.entries {
            let body = try #require(SolarSystemBody(rawValue: e.body))
            let instant = f.times[e.time].instant(useDUT1: false)
            let (ra, dec, _) = try SolarSystem.apparentEquatorial(body, at: instant, location: f.observers[e.observer].location)
            let got = SIMD3<Double>.unit(lon: Angle.radians(ra * 15), lat: Angle.radians(dec))
            let expected = SIMD3<Double>.unit(lon: Angle.radians(e.ra_deg), lat: Angle.radians(e.dec_deg))
            worst[e.body] = max(worst[e.body] ?? 0, Angle.separation(got, expected))
        }
        let line = SolarSystemBody.allCases.map { String(format: "%@ %.1f\"", $0.rawValue, arcsec(worst[$0.rawValue] ?? .nan)) }
        report("solar system vs Horizons (\(f.entries.count) entries): " + line.joined(separator: ", "))
        for (body, w) in worst { #expect(w < Angle.radians(0.05), "\(body)") }
    }

    @Test(.enabled(if: RepoFiles.exists(fixturePath)))
    func moonTopocentricShiftIsApplied() throws {
        let f = try RepoFiles.decode(HorizonsFixture.self, Self.fixturePath)
        let instant = f.times[0].instant(useDUT1: false)
        let topo = try SolarSystem.apparentEquatorial(.moon, at: instant, location: f.observers[1].location)
        let geo = try SolarSystem.apparentEquatorial(.moon, at: instant, location: GeoLocation(latitude: 0, longitude: 0, height: -6_378_137))
        let shift = Angle.separation(.unit(lon: Angle.radians(topo.raHours * 15), lat: Angle.radians(topo.decDegrees)),
                                     .unit(lon: Angle.radians(geo.raHours * 15), lat: Angle.radians(geo.decDegrees)))
        report(String(format: "Moon topocentric vs geocentric shift at Boulder: %.3f deg", Angle.degrees(shift)))
        #expect(shift > Angle.radians(0.1))
    }

    @Test func snapshotAndDaylight() throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-25T21:00:00Z")!
        let session = SkySession(date: date, location: GeoLocation(latitude: 37.77, longitude: -122.42))
        let snap = try SolarSystem.snapshot(at: session.epoch, session: session)
        #expect(snap.bodies.count == 9)
        #expect(snap.daylight.phase == .day)
        let moon = try #require(snap.position(.moon))
        #expect(moon.angularDiameterDegrees > 0.48 && moon.angularDiameterDegrees < 0.57)
        #expect((0...1).contains(snap.moonPhase.illuminatedFraction))
        let night = DaylightState(sunAltitudeDegrees: -20)
        #expect(night.phase == .night && night.nightFactor == 1)
        let day = DaylightState(sunAltitudeDegrees: 10)
        #expect(day.phase == .day && day.nightFactor == 0)
        let civil = DaylightState(sunAltitudeDegrees: -3)
        #expect(civil.phase == .civilTwilight && civil.nightFactor > 0 && civil.nightFactor < 1)
        var previous = -1.0
        for h in stride(from: 5.0, through: -15, by: -0.1) {
            let f = DaylightState(sunAltitudeDegrees: h).nightFactor
            #expect(f >= previous && (0...1).contains(f))
            previous = f
        }
    }
}
