import Foundation
import Testing
import simd
@testable import SkyCore

@Suite struct RoundTripTests {
    static let date = ISO8601DateFormatter().date(from: "2027-03-01T04:00:00Z")!
    static let location = GeoLocation(latitude: 37.33, longitude: -122.01, height: 30)

    @Test func icrsApparentRoundTrip() {
        let session = SkySession(date: Self.date, location: Self.location)
        var g = SplitMixRNG(seed: 1)
        var worst = 0.0
        for _ in 0..<20_000 {
            let p = randomUnitVector(&g)
            let back = session.icrs(fromApparentOfDate: session.apparentOfDate(icrs: p))
            worst = max(worst, Angle.separation(p, back))
        }
        report(String(format: "round trip ICRS->apparent->ICRS: max %.2e rad", worst))
        #expect(worst < 1e-14)
    }

    @Test func horizonRoundTrip() {
        let session = SkySession(date: Self.date, location: Self.location)
        let instant = session.epoch.adding(seconds: 1234.5)
        let m = session.horizonMatrix(at: instant)
        var g = SplitMixRNG(seed: 2)
        var worst = 0.0
        for _ in 0..<20_000 {
            let v = randomUnitVector(&g)
            let enu = m * v
            let hc = HorizontalCoordinates(enu: enu)
            worst = max(worst, Angle.separation(v, m.transpose * hc.enu))
            let (ha, dec) = session.hourAngleDeclination(ofDate: v, at: instant)
            let lst = session.localSiderealTime(at: instant)
            worst = max(worst, Angle.separation(v, .unit(lon: lst - ha, lat: dec)))
        }
        report(String(format: "round trip of-date->ENU->alt/az->of-date and hour angle: max %.2e rad", worst))
        #expect(worst < 1e-14)
    }

    @Test func refractionRoundTrip() {
        var worst = 0.0
        for r in [Refraction.standard, Refraction(pressureMillibar: 1040, temperatureCelsius: -25),
                  Refraction(pressureMillibar: 700, temperatureCelsius: 30)] {
            var h = -10.0
            while h <= 90 {
                let t = Angle.radians(h)
                let a = r.apparentAltitude(trueAltitude: t)
                worst = max(worst, abs(r.trueAltitude(apparentAltitude: a) - t))
                h += 0.0137
            }
        }
        let horizon = Angle.degrees(Refraction.standard.correction(trueAltitude: 0)) * 60
        let at45 = Angle.degrees(Refraction.standard.correction(trueAltitude: Angle.radians(45))) * 60
        report(String(format: "round trip refraction true->apparent->true: max %.2e rad; R(0)=%.2f' R(45)=%.3f'",
                      worst, horizon, at45))
        #expect(worst < 1e-12)
        #expect(abs(horizon - 28.9) < 0.6)
        #expect(abs(at45 - 1.0) < 0.05)
    }

    @Test func refractionIsMonotonic() {
        let r = Refraction.standard
        var previous = -Double.infinity
        for i in 0..<20_000 {
            let h = Angle.radians(-10 + Double(i) * 0.005)
            let a = r.apparentAltitude(trueAltitude: h)
            #expect(a > previous)
            previous = a
        }
    }

    @Test func screenRoundTrip() {
        let intr = CameraIntrinsics(fx: 1480.3, fy: 1479.1, cx: 961.2, cy: 538.7, bufferWidth: 1920, bufferHeight: 1080)
        let mapping = ScreenMapping.portraitAspectFill(bufferWidth: 1920, bufferHeight: 1080, viewWidth: 393, viewHeight: 852)
        var g = SplitMixRNG(seed: 3)
        var worstRay = 0.0, worstPixel = 0.0
        for _ in 0..<2_000 {
            let forward = randomUnitVector(&g)
            let up = randomUnitVector(&g)
            guard simd_length(simd_cross(forward, up)) > 0.1 else { continue }
            let pose = CameraPose(referenceToDevice: CameraPose.looking(at: forward, up: up).referenceToDevice,
                                  headingCorrection: HeadingCorrection(yaw: Double.random(in: -1...1, using: &g)))
            let projector = Projector(pose: pose, intrinsics: intr, mapping: mapping)
            for _ in 0..<10 {
                let s = SIMD2(Double.random(in: 0...393, using: &g), Double.random(in: 0...852, using: &g))
                let ray = projector.ray(screenPoint: s)
                guard let back = projector.screenPoint(enu: ray) else { Issue.record("ray behind camera"); continue }
                worstPixel = max(worstPixel, simd_distance(back, s))
                let v = simd_normalize(forward + 0.3 * randomUnitVector(&g))
                if let p = projector.screenPoint(enu: v) {
                    worstRay = max(worstRay, Angle.separation(projector.ray(screenPoint: p), v))
                }
            }
        }
        report(String(format: "round trip screen->ray->screen: max %.2e pt; ENU->screen->ray: max %.2e rad", worstPixel, worstRay))
        #expect(worstPixel < 1e-9)
        #expect(worstRay < 1e-12)
    }

    @Test func fullPipelineRoundTrip() {
        let session = SkySession(date: Self.date, location: Self.location)
        let instant = session.epoch.adding(seconds: 600)
        let refraction = Refraction.standard
        let intr = CameraIntrinsics.fieldOfView(horizontalDegrees: 65, bufferWidth: 1920, bufferHeight: 1080)
        let mapping = ScreenMapping.portraitAspectFill(bufferWidth: 1920, bufferHeight: 1080, viewWidth: 393, viewHeight: 852)
        var g = SplitMixRNG(seed: 4)
        var worst = 0.0
        var count = 0
        while count < 5_000 {
            let p = randomUnitVector(&g)
            let enu = refraction.apparent(enu: session.enu(icrs: p, at: instant))
            guard enu.z > 0.02 else { continue }
            let projector = Projector(pose: .looking(at: enu + 0.2 * randomUnitVector(&g)), intrinsics: intr, mapping: mapping)
            guard let s = projector.screenPoint(enu: enu) else { continue }
            let ray = refraction.unrefracted(enu: projector.ray(screenPoint: s))
            let ofDate = session.horizonMatrix(at: instant).transpose * ray
            worst = max(worst, Angle.separation(session.icrs(fromApparentOfDate: ofDate), p))
            count += 1
        }
        report(String(format: "round trip ICRS->refracted ENU->screen->ICRS: max %.2e rad", worst))
        #expect(worst < 1e-10)
    }

    @Test func coreMotionFrameConvention() {
        let enuNorth = SIMD3<Double>(0, 1, 0), enuEast = SIMD3<Double>(1, 0, 0)
        #expect(CameraPose.enuToReference * enuNorth == SIMD3(1, 0, 0))
        #expect(CameraPose.enuToReference * enuEast == SIMD3(0, -1, 0))
        let pose = CameraPose.looking(at: enuEast)
        let deviceZ = pose.enuToDevice * enuEast
        #expect(simd_distance(deviceZ, SIMD3(0, 0, -1)) < 1e-12)
        let up = pose.enuToDevice * SIMD3(0, 0, 1)
        #expect(simd_distance(up, SIMD3(0, 1, 0)) < 1e-12)
        let intr = CameraIntrinsics.fieldOfView(horizontalDegrees: 60, bufferWidth: 1920, bufferHeight: 1080)
        let mapping = ScreenMapping.portraitAspectFill(bufferWidth: 1920, bufferHeight: 1080, viewWidth: 390, viewHeight: 844)
        let projector = Projector(pose: pose, intrinsics: intr, mapping: mapping)
        let centre = projector.screenPoint(enu: enuEast)!
        #expect(simd_distance(centre, SIMD2(195, 422)) < 1e-9)
        let higher = projector.screenPoint(enu: simd_normalize(SIMD3(1, 0, 0.1)))!
        #expect(higher.y < centre.y)
        let southward = projector.screenPoint(enu: simd_normalize(SIMD3(1, -0.1, 0)))!
        #expect(southward.x > centre.x)
    }
}
