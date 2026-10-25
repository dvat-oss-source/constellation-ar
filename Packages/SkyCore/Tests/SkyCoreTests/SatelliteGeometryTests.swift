import Foundation
import simd
import Testing
@testable import SkyCore

@Suite struct SatelliteGeometryTests {
    /// Vallado et al. (2006) "Revisiting Spacetrack Report #3", tcppver.out for satellite 00005.
    @Test func sgp4MatchesValladoVerification() throws {
        let sat = try TrackedSatellite(record: SatelliteTestData.vallado00005)
        let cases: [(minutes: Double, r: SIMD3<Double>, v: SIMD3<Double>)] = [
            (0, SIMD3(7022.46529266, -1400.08296755, 0.03995155), SIMD3(1.893841015, 6.405893759, 4.534807250)),
            (360, SIMD3(-7154.03120202, -3783.17682504, -3536.19412294), SIMD3(4.741887409, -4.151817765, -2.093935425)),
        ]
        for c in cases {
            let t = AstroInstant(date: sat.epoch.addingTimeInterval(c.minutes * 60))
            let r = try sat.temeKilometres(at: t)
            let v = try sat.temeVelocity(at: t)
            SatelliteTestData.report("Vallado 00005 t=\(c.minutes) min |dr| = \(simd_length(r - c.r) * 1000) m, |dv| = \(simd_length(v - c.v) * 1e6) mm/s")
            #expect(simd_length(r - c.r) < 0.005)
            #expect(simd_length(v - c.v) < 5e-6)
        }
    }

    @Test func issOrbitSanity() throws {
        let sat = try TrackedSatellite(record: SatelliteTestData.iss2018)
        #expect(abs(sat.periodMinutes - 92.66) < 0.05)
        for hours in stride(from: 0.0, through: 48, by: 1.7) {
            let t = AstroInstant(date: sat.epoch.addingTimeInterval(hours * 3_600))
            let r = try sat.temeKilometres(at: t)
            let v = try sat.temeVelocity(at: t)
            let height = simd_length(r) - 6378.137
            #expect(height > 390 && height < 440)
            #expect(abs(simd_length(v) - 7.66) < 0.05)
            let itrs = try sat.itrsKilometres(at: t)
            #expect(abs(simd_length(itrs) - simd_length(r)) < 1e-9)
            #expect(abs(itrs.z - r.z) < 1e-9)
        }
    }

    @Test func gmst1982MatchesVallado() {
        // Vallado, Fundamentals of Astrodynamics, Example 3-5: 1992-08-20 12:14:00 UT1 → GMST 152.578787810°.
        let jd = 2_448_855.009722222
        let gmst = Angle.degrees(EarthOrientation.gmst1982(daysUT1: jd - AstroInstant.j2000JD))
        #expect(abs(gmst - 152.578787810) < 1e-6)
        let instant = AstroInstant(jdUTC: jd)
        let x = SatelliteFrames.temeToITRS(at: instant) * SIMD3<Double>(1, 0, 0)
        let g = Angle.radians(gmst)
        #expect(simd_length(x - SIMD3(cos(g), -sin(g), 0)) < 1e-9)
    }

    @Test func topocentricDirections() {
        let observer = SatelliteObserver(location: GeoLocation(latitude: 40, longitude: -75, height: 100))
        let m = observer.itrsToENU
        let east = m.transpose * SIMD3<Double>(1, 0, 0)
        let north = m.transpose * SIMD3<Double>(0, 1, 0)
        let up = m.transpose * SIMD3<Double>(0, 0, 1)
        let t = AstroInstant(jdUTC: 2_461_000.5)

        let zenith = observer.topocentric(itrsKilometres: observer.itrsKilometres + 420 * up, at: t)
        #expect(abs(zenith.altitudeDegrees - 90) < 1e-9)
        #expect(abs(zenith.rangeKilometres - 420) < 1e-9)

        let n = observer.topocentric(itrsKilometres: observer.itrsKilometres + 1000 * north, at: t)
        #expect(abs(n.altitudeDegrees) < 1e-9 && abs(Angle.wrapPi(Angle.radians(n.azimuthDegrees))) < 1e-9)
        let e = observer.topocentric(itrsKilometres: observer.itrsKilometres + 1000 * east, at: t)
        #expect(abs(e.azimuthDegrees - 90) < 1e-9)

        let d = simd_normalize(north + up)
        let ne = observer.topocentric(itrsKilometres: observer.itrsKilometres + 500 * d, at: t)
        #expect(abs(ne.altitudeDegrees - 45) < 1e-9)
        #expect(abs(Angle.wrapPi(Angle.radians(ne.azimuthDegrees))) < 1e-9)
        #expect(abs(simd_length(ne.enu) - 1) < 1e-12)
        let h = ne.horizontal
        #expect(abs(Angle.degrees(h.altitude) - 45) < 1e-9)

        // Geodetic up differs from the geocentric radial direction by ~0.19° at 40° latitude.
        let tilt = Angle.degrees(Angle.separation(up, observer.itrsKilometres))
        #expect(tilt > 0.18 && tilt < 0.2)
    }

    @Test func shadowGeometry() {
        let au = 149_597_870.7
        let sun = SIMD3<Double>(au, 0, 0)
        func lit(_ x: Double, _ y: Double, _ z: Double) -> Bool {
            EarthShadow.isSunlit(satelliteKilometres: SIMD3(x, y, z), sunKilometres: sun)
        }
        #expect(!lit(-7000, 0, 0))
        #expect(!lit(-7000, 6300, 0))
        #expect(lit(-7000, 6450, 0))
        #expect(lit(7000, 0, 0))
        #expect(lit(0, 7000, 0))
        #expect(lit(0, 0, -6800))
        #expect(!lit(-400_000, 0, 6000))

        // Equivalent formulation: shadowed iff behind the Earth and closer than R to the Earth–satellite→Sun line.
        var generator = SplitMix64(seed: 7)
        var checked = 0
        for _ in 0..<20_000 {
            let r = SIMD3((0..<3).map { _ in Double.random(in: -9000...9000, using: &generator) })
            guard simd_length(r) > 6600 else { continue }
            let toSun = simd_normalize(sun - r)
            let along = simd_dot(-r, toSun)
            let miss = simd_length(-r - along * toSun)
            guard abs(miss - EarthShadow.earthRadiusKilometres) > 1e-6 else { continue }
            let shadowed = along > 0 && miss < EarthShadow.earthRadiusKilometres
            #expect(EarthShadow.isSunlit(satelliteKilometres: r, sunKilometres: sun) == !shadowed)
            checked += 1
        }
        #expect(checked > 5_000)
    }

    @Test func sunAltitudeMatchesSolarSystem() throws {
        let location = GeoLocation(latitude: 51.48, longitude: -0.0015, height: 45)
        let observer = SatelliteObserver(location: location)
        for jd in stride(from: 2_461_330.0, to: 2_461_332.0, by: 0.173) {
            let instant = AstroInstant(jdUTC: jd)
            let session = SkySession(epoch: instant, location: location)
            let reference = try SolarSystem.sunAltitudeDegrees(at: instant, session: session)
            let mine = try observer.sunAltitudeDegrees(at: instant)
            #expect(abs(mine - reference) < 0.003, "jd \(jd): \(mine) vs \(reference)")
        }
    }

    @Test func observationAndPath() throws {
        let sat = try TrackedSatellite(record: SatelliteTestData.iss2018)
        let observer = SatelliteObserver(location: GeoLocation(latitude: 29.56, longitude: -95.09, height: 10))
        let t = AstroInstant(date: sat.epoch.addingTimeInterval(5_000))
        let path = try sat.predictedPath(observer: observer, around: t, pastSeconds: 60, futureSeconds: 180, stepSeconds: 10)
        #expect(path.count == 25)
        #expect(path.first?.offsetSeconds == -60 && path.last?.offsetSeconds == 180)
        let now = try sat.observation(at: t, observer: observer)
        let center = try #require(path.first { $0.offsetSeconds == 0 })
        #expect(simd_length(center.enu - now.position.enu) < 1e-12)
        #expect(center.isSunlit == now.isSunlit)
        for (a, b) in zip(path, path.dropFirst()) {
            // ISS angular speed seen from the ground is < 1.2°/s, so 10 s steps move < 12°.
            #expect(Angle.degrees(Angle.separation(a.enu, b.enu)) < 12)
        }
    }

    @Test func compassNames() {
        #expect(CompassDirection.name(azimuthDegrees: 0) == "N")
        #expect(CompassDirection.name(azimuthDegrees: 359) == "N")
        #expect(CompassDirection.name(azimuthDegrees: 315) == "NW")
        #expect(CompassDirection.name(azimuthDegrees: 200) == "S")
        #expect(CompassDirection.name(azimuthDegrees: -45) == "NW")
        #expect(CompassDirection.name(azimuthDegrees: 292.5, points: 16) == "WNW")
        #expect(CompassDirection.name(azimuthDegrees: 100, points: 16) == "E")
    }
}
