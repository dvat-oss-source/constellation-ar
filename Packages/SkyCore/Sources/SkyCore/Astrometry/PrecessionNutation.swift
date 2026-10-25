import Foundation
import simd

/// IAU 2006 precession (Capitaine et al. 2003 angles), IAU 2000B nutation truncated to its 20 largest
/// terms (residual < 0.4″ vs IAU 2000A), IERS 2003 frame bias, and IAU 2006 sidereal time.
public enum EarthOrientation {
    static let arcsec = Angle.radiansPerArcsecond
    static let eps0Arcsec = 84_381.406

    /// Mean obliquity of the ecliptic (IAU 2006), radians.
    public static func meanObliquity(centuriesTT t: Double) -> Double {
        let a = ((((-0.0000000434 * t - 0.000000576) * t + 0.00200340) * t - 0.0001831) * t - 46.836769) * t
        return (eps0Arcsec + a) * arcsec
    }

    /// ICRS → mean J2000 frame bias.
    public static let frameBias: simd_double3x3 = {
        let dPsiB = -0.041775 * arcsec
        let dEpsB = -0.0068192 * arcsec
        let dRA0 = -0.0146 * arcsec
        return Rotation.rx(-dEpsB) * Rotation.ry(dPsiB * sin(eps0Arcsec * arcsec)) * Rotation.rz(dRA0)
    }()

    /// Mean J2000 → mean equator and equinox of date. Valid for |t| up to a few centuries (used for B1875 too).
    public static func precession(centuriesTT t: Double) -> simd_double3x3 {
        let psiA = ((((-0.0000000951 * t + 0.000132851) * t - 0.00114045) * t - 1.0790069) * t + 5038.481507) * t
        let omegaA = ((((0.0000003337 * t - 0.000000467) * t - 0.00772503) * t + 0.0512623) * t - 0.025754) * t + eps0Arcsec
        let chiA = ((((-0.0000000560 * t + 0.000170663) * t - 0.00121197) * t - 2.3814292) * t + 10.556403) * t
        return Rotation.rz(chiA * arcsec) * Rotation.rx(-omegaA * arcsec) * Rotation.rz(-psiA * arcsec)
            * Rotation.rx(eps0Arcsec * arcsec)
    }

    public struct Nutation: Sendable, Hashable {
        /// Nutation in longitude, radians.
        public let dPsi: Double
        /// Nutation in obliquity, radians.
        public let dEps: Double
        /// Longitude of the Moon's ascending node, radians (for equation-of-equinoxes complementary terms).
        public let omega: Double
    }

    private struct Term {
        let l: Double, lp: Double, f: Double, d: Double, om: Double
        let ps: Double, pst: Double, pc: Double, ec: Double, ect: Double, es: Double
        init(_ l: Double, _ lp: Double, _ f: Double, _ d: Double, _ om: Double,
             _ ps: Double, _ pst: Double, _ pc: Double, _ ec: Double, _ ect: Double, _ es: Double) {
            self.l = l; self.lp = lp; self.f = f; self.d = d; self.om = om
            self.ps = ps; self.pst = pst; self.pc = pc; self.ec = ec; self.ect = ect; self.es = es
        }
    }

    /// Units of 0.1 µas.
    private static let terms: [Term] = [
        Term(0, 0, 0, 0, 1, -172064161, -174666, 33386, 92052331, 9086, 15377),
        Term(0, 0, 2, -2, 2, -13170906, -1675, -13696, 5730336, -3015, -4587),
        Term(0, 0, 2, 0, 2, -2276413, -234, 2796, 978459, -485, 1374),
        Term(0, 0, 0, 0, 2, 2074554, 207, -698, -897492, 470, -291),
        Term(0, 1, 0, 0, 0, 1475877, -3633, 11817, 73871, -184, -1924),
        Term(0, 1, 2, -2, 2, -516821, 1226, -524, 224386, -677, -174),
        Term(1, 0, 0, 0, 0, 711159, 73, -872, -6750, 0, 358),
        Term(0, 0, 2, 0, 1, -387298, -367, 380, 200728, 18, 318),
        Term(1, 0, 2, 0, 2, -301461, -36, 816, 129025, -63, 367),
        Term(0, -1, 2, -2, 2, 215829, -494, 111, -95929, 299, 132),
        Term(0, 0, 2, -2, 1, 128227, 137, 181, -68982, -9, 39),
        Term(-1, 0, 2, 0, 2, 123457, 11, 19, -53311, 32, -4),
        Term(-1, 0, 0, 2, 0, 156994, 10, -168, -1235, 0, 82),
        Term(1, 0, 0, 0, 1, 63110, 63, 27, -33228, 0, -9),
        Term(-1, 0, 0, 0, 1, -57976, -63, -189, 31429, 0, -75),
        Term(-1, 0, 2, 2, 2, -59641, -11, 149, 25543, -11, 66),
        Term(1, 0, 2, 0, 1, -51613, -42, 129, 26366, 0, 78),
        Term(-2, 0, 2, 0, 1, 45893, 50, 31, -24236, -10, 20),
        Term(0, 0, 0, 2, 0, 63384, 11, -150, -1220, 0, 29),
        Term(0, 0, 2, 2, 2, -38571, -1, 158, 16452, -11, 68),
    ]

    public static func nutation(centuriesTT t: Double) -> Nutation {
        let turn = 1_296_000.0
        let l = (485_868.249036 + 1_717_915_923.2178 * t).truncatingRemainder(dividingBy: turn) * arcsec
        let lp = (1_287_104.79305 + 129_596_581.0481 * t).truncatingRemainder(dividingBy: turn) * arcsec
        let f = (335_779.526232 + 1_739_527_262.8478 * t).truncatingRemainder(dividingBy: turn) * arcsec
        let d = (1_072_260.70369 + 1_602_961_601.2090 * t).truncatingRemainder(dividingBy: turn) * arcsec
        let om = (450_160.398036 - 6_962_890.5431 * t).truncatingRemainder(dividingBy: turn) * arcsec
        var dp = 0.0, de = 0.0
        for k in terms.reversed() {
            let arg = k.l * l + k.lp * lp + k.f * f + k.d * d + k.om * om
            let s = sin(arg), c = cos(arg)
            dp += (k.ps + k.pst * t) * s + k.pc * c
            de += (k.ec + k.ect * t) * c + k.es * s
        }
        let unit = 1e-7 * arcsec
        let planetaryPsi = -0.135e-3 * arcsec
        let planetaryEps = 0.388e-3 * arcsec
        return Nutation(dPsi: dp * unit + planetaryPsi, dEps: de * unit + planetaryEps, omega: om)
    }

    /// Mean equator/equinox of date → true equator/equinox of date.
    public static func nutationMatrix(_ n: Nutation, meanObliquity epsA: Double) -> simd_double3x3 {
        Rotation.rx(-(epsA + n.dEps)) * Rotation.rz(-n.dPsi) * Rotation.rx(epsA)
    }

    /// ICRS → true equator and equinox of date (bias · precession · nutation).
    public static func biasPrecessionNutation(centuriesTT t: Double) -> simd_double3x3 {
        let n = nutation(centuriesTT: t)
        return nutationMatrix(n, meanObliquity: meanObliquity(centuriesTT: t)) * precession(centuriesTT: t) * frameBias
    }

    /// ICRS → mean equator and equinox of date (no nutation).
    public static func biasPrecession(centuriesTT t: Double) -> simd_double3x3 {
        precession(centuriesTT: t) * frameBias
    }

    /// Earth rotation angle (IAU 2000), radians in [0, 2π).
    public static func earthRotationAngle(daysUT1 du: Double) -> Double {
        let frac = du - du.rounded(.down)
        return Angle.wrapTwoPi(2 * .pi * (frac + 0.7790572732640 + 0.00273781191135448 * du))
    }

    /// Greenwich mean sidereal time (IAU 2006), radians in [0, 2π).
    public static func gmst(daysUT1 du: Double, centuriesTT t: Double) -> Double {
        let poly = (((((-0.0000000368 * t - 0.000029956) * t - 0.00000044) * t + 1.3915817) * t + 4612.156534) * t
            + 0.014506)
        return Angle.wrapTwoPi(earthRotationAngle(daysUT1: du) + poly * arcsec)
    }

    /// Equation of the equinoxes (IAU 2000, with the two largest complementary terms), radians.
    public static func equationOfEquinoxes(_ n: Nutation, meanObliquity epsA: Double) -> Double {
        n.dPsi * cos(epsA) + (0.00264096 * sin(n.omega) + 0.00006352 * sin(2 * n.omega)) * arcsec
    }

    /// Greenwich apparent sidereal time, radians in [0, 2π).
    public static func gast(_ instant: AstroInstant) -> Double {
        let t = instant.centuriesTT
        let n = nutation(centuriesTT: t)
        let ee = equationOfEquinoxes(n, meanObliquity: meanObliquity(centuriesTT: t))
        return Angle.wrapTwoPi(gmst(daysUT1: instant.daysUT1, centuriesTT: t) + ee)
    }

    /// IAU 1982 GMST, the sidereal time that defines the TEME frame used by SGP4. Radians in [0, 2π).
    public static func gmst1982(daysUT1 du: Double) -> Double {
        let t = du / 36_525
        let seconds = 67_310.54841 + (876_600 * 3600 + 8_640_184.812866) * t + 0.093104 * t * t - 6.2e-6 * t * t * t
        let r = seconds.truncatingRemainder(dividingBy: 86_400) / 86_400 * 2 * .pi
        return Angle.wrapTwoPi(r)
    }
}
