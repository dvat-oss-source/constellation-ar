import Foundation
import Testing
import simd
@testable import SkyCore

@Suite struct StarPositionTests {
    static let fixturePath = "Data/fixtures/stars_skyfield.json"
    static let tolerance = Angle.radians(0.01)

    struct Errors {
        var altAz = 0.0
        var radec = 0.0
        var worst = ""
    }

    enum Input { case astrometric, catalog(StarCatalog) }

    /// Max angular error of (alt/az direction, apparent RA/Dec direction) over the fixture.
    static func errors(_ f: StarFixture, input: Input, useDUT1: Bool, nutation: Bool = true, aberration: Bool = true) -> Errors {
        var e = Errors()
        var sessions: [Int: SkySession] = [:]
        for row in f.results {
            let si = Int(row[0]), ti = Int(row[1]), oi = Int(row[2])
            let key = ti * 100 + oi
            let instant = f.times[ti].instant(useDUT1: useDUT1)
            let session = sessions[key] ?? SkySession(epoch: instant, location: f.observers[oi].location,
                                                      includeNutation: nutation, includeAberration: aberration)
            sessions[key] = session
            let p: SIMD3<Double>
            switch input {
            case .astrometric:
                p = SIMD3(f.stars[si].astrometric[ti])
            case .catalog(let cat):
                guard let s = cat.star(hip: f.stars[si].hip) else { continue }
                p = s.directionDouble
            }
            let ofDate = session.apparentOfDate(icrs: p)
            let enu = session.horizonMatrix(at: instant) * ofDate
            let expectedENU = HorizontalCoordinates(altitude: Angle.radians(row[3]), azimuth: Angle.radians(row[4])).enu
            let expectedOfDate = SIMD3<Double>.unit(lon: Angle.radians(row[5] * 15), lat: Angle.radians(row[6]))
            let a = Angle.separation(enu, expectedENU)
            if a > e.altAz { e.altAz = a; e.worst = "HIP \(f.stars[si].hip) \(f.times[ti].utc) \(f.observers[oi].name)" }
            e.radec = max(e.radec, Angle.separation(ofDate, expectedOfDate))
        }
        return e
    }

    @Test(.enabled(if: RepoFiles.exists(fixturePath)))
    func starsMatchSkyfieldWithinBudget() throws {
        let f = try RepoFiles.decode(StarFixture.self, Self.fixturePath)
        let full = Self.errors(f, input: .astrometric, useDUT1: true)
        let noDUT1 = Self.errors(f, input: .astrometric, useDUT1: false)
        let precessionOnly = Self.errors(f, input: .astrometric, useDUT1: true, nutation: false, aberration: false)
        let noAberration = Self.errors(f, input: .astrometric, useDUT1: true, aberration: false)
        let noNutation = Self.errors(f, input: .astrometric, useDUT1: true, nutation: false)
        report(String(format: "stars vs Skyfield (%d rows): full alt/az %.3f\" radec %.3f\" (worst %@)",
                      f.results.count, arcsec(full.altAz), arcsec(full.radec), full.worst))
        report(String(format: "stars vs Skyfield UT1=UTC: alt/az %.3f\"", arcsec(noDUT1.altAz)))
        report(String(format: "stars precession only: alt/az %.2f\" (%.4f deg); without aberration %.2f\"; without nutation %.2f\"",
                      arcsec(precessionOnly.altAz), Angle.degrees(precessionOnly.altAz),
                      arcsec(noAberration.altAz), arcsec(noNutation.altAz)))
        #expect(full.altAz < Self.tolerance)
        #expect(full.radec < Self.tolerance)
        #expect(noDUT1.altAz < Self.tolerance)
        #expect(full.altAz < Angle.radians(1.0 / 3600))
    }

    @Test(.enabled(if: RepoFiles.exists(fixturePath) && RepoFiles.exists("Data/stars.bin")))
    func catalogStarsMatchSkyfield() throws {
        let f = try RepoFiles.decode(StarFixture.self, Self.fixturePath)
        let cat = try StarCatalog(url: RepoFiles.url("Data/stars.bin"))
        let e = Self.errors(f, input: .catalog(cat), useDUT1: false)
        var maxEpochResidual = 0.0, worst = 0
        let key = String(format: "%.1f", cat.pmEpoch)
        for s in f.stars {
            guard let c = cat.star(hip: s.hip), let ref = s.catalog_icrs[key] else { continue }
            let r = Angle.separation(c.directionDouble, SIMD3(ref))
            if r > maxEpochResidual { maxEpochResidual = r; worst = s.hip }
        }
        report(String(format: "stars.bin (pmEpoch %.2f, UT1=UTC) vs Skyfield: alt/az %.3f\" radec %.3f\" (worst %@); stars.bin vs linear space motion at pmEpoch: %.4f\" (HIP %d)",
                      cat.pmEpoch, arcsec(e.altAz), arcsec(e.radec), e.worst, arcsec(maxEpochResidual), worst))
        #expect(e.altAz < Self.tolerance)
        #expect(maxEpochResidual < Angle.radians(0.1 / 3600))
    }

    @Test func northCelestialPoleAltitudeEqualsLatitude() {
        var worst = 0.0
        let date = ISO8601DateFormatter().date(from: "2027-02-01T03:30:00Z")!
        for lat in stride(from: -89.5, through: 89.5, by: 7.25) {
            for lon in [-170.0, -45.5, 0, 33.3, 151.2] {
                let loc = GeoLocation(latitude: lat, longitude: lon, height: 100)
                let session = SkySession(date: date, location: loc)
                for minutes in stride(from: 0.0, to: 1440, by: 97) {
                    let instant = session.epoch.adding(seconds: minutes * 60)
                    let m = session.horizonMatrix(at: instant)
                    let north = HorizontalCoordinates(enu: m * SIMD3(0, 0, 1))
                    let south = HorizontalCoordinates(enu: m * SIMD3(0, 0, -1))
                    worst = max(worst, abs(north.altitude - Angle.radians(lat)), abs(south.altitude + Angle.radians(lat)))
                    if lat > 0 { #expect(abs(Angle.wrapPi(north.azimuth)) < 1e-9) }
                }
            }
        }
        report(String(format: "pole altitude - latitude: max %.3e rad", worst))
        #expect(worst < 1e-12)
    }
}
