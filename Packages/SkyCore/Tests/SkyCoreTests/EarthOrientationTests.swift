import Foundation
import Testing
import simd
@testable import SkyCore

@Suite struct EarthOrientationTests {
    static let fixturePath = "Data/fixtures/earth_orientation.json"

    @Test(.enabled(if: RepoFiles.exists(fixturePath)))
    func nutationSiderealTimeAndMatrixMatchSkyfield() throws {
        let f = try RepoFiles.decode(OrientationFixture.self, Self.fixturePath)
        var maxPsi = 0.0, maxEps = 0.0, maxGMST = 0.0, maxGAST = 0.0, maxNPB = 0.0, maxPB = 0.0, maxObl = 0.0
        for r in f.rows {
            let instant = AstroInstant(jdUTC: r.jd_utc, ut1MinusUTC: r.dut1)
            #expect(abs((instant.jdTT - r.jd_tt) * 86_400) < 1e-3, "TT for \(r.utc)")
            let t = instant.centuriesTT
            let n = EarthOrientation.nutation(centuriesTT: t)
            maxPsi = max(maxPsi, abs(arcsec(n.dPsi) - r.dpsi_arcsec))
            maxEps = max(maxEps, abs(arcsec(n.dEps) - r.deps_arcsec))
            maxObl = max(maxObl, abs(arcsec(EarthOrientation.meanObliquity(centuriesTT: t)) - r.mean_obliquity_arcsec))
            let gmst = EarthOrientation.gmst(daysUT1: instant.daysUT1, centuriesTT: t)
            maxGMST = max(maxGMST, abs(arcsec(Angle.wrapPi(gmst - r.gmst_hours * .pi / 12))))
            let gast = EarthOrientation.gast(instant)
            maxGAST = max(maxGAST, abs(arcsec(Angle.wrapPi(gast - r.gast_hours * .pi / 12))))
            maxNPB = max(maxNPB, arcsec(rotationAngle(EarthOrientation.biasPrecessionNutation(centuriesTT: t),
                                                      matrix(rows: r.icrs_to_true_of_date))))
            maxPB = max(maxPB, arcsec(rotationAngle(EarthOrientation.biasPrecession(centuriesTT: t),
                                                    matrix(rows: r.icrs_to_mean_of_date))))
        }
        report(String(format: "orientation vs Skyfield: dpsi %.3f\" deps %.3f\" obliquity %.4f\" GMST %.4f\" GAST %.3f\" NPB %.3f\" PB %.4f\"",
                      maxPsi, maxEps, maxObl, maxGMST, maxGAST, maxNPB, maxPB))
        #expect(maxPsi < 0.5)
        #expect(maxEps < 0.5)
        #expect(maxGMST < 0.01)
        #expect(maxGAST < 0.5)
        #expect(maxNPB < 0.5)
        #expect(maxPB < 0.01)
    }

    @Test func leapSecondsAndTT() {
        let d = ISO8601DateFormatter().date(from: "2026-10-25T21:00:00Z")!
        let i = AstroInstant(date: d)
        #expect(i.taiMinusUTC == 37)
        #expect(abs(i.ttMinusUTC - 69.184) < 1e-12)
        let before2017 = AstroInstant(date: ISO8601DateFormatter().date(from: "2016-12-31T23:59:59Z")!)
        #expect(before2017.taiMinusUTC == 36)
        #expect(abs(i.jdUTC - 2_461_339.375) < 1e-9)
    }
}
