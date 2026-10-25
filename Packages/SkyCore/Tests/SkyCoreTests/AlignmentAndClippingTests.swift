import Foundation
import Testing
import simd
@testable import SkyCore

@Suite struct AlignmentTests {
    static let intr = CameraIntrinsics.fieldOfView(horizontalDegrees: 65, bufferWidth: 1920, bufferHeight: 1080)
    static let mapping = ScreenMapping.portraitAspectFill(bufferWidth: 1920, bufferHeight: 1080, viewWidth: 393, viewHeight: 852)

    static func star(_ hip: Int, mag: Double, alt: Double, az: Double) -> AlignmentCandidate {
        AlignmentCandidate(kind: .star(hip: hip), name: "HIP \(hip)", magnitude: mag,
                           enu: HorizontalCoordinates(altitude: Angle.radians(alt), azimuth: Angle.radians(az)).enu)
    }

    @Test func yawCorrectionPutsObjectUnderFinger() throws {
        var g = SplitMixRNG(seed: 9)
        var worstResidual = 0.0
        for _ in 0..<500 {
            let trueAlt = Double.random(in: 5...70, using: &g), trueAz = Double.random(in: 0..<360, using: &g)
            let headingError = Double.random(in: -12...12, using: &g)
            let target = Self.star(27989, mag: 0.5, alt: trueAlt, az: trueAz)
            let truePose = CameraPose.looking(at: HorizontalCoordinates(altitude: Angle.radians(trueAlt + 3),
                                                                        azimuth: Angle.radians(trueAz - 2)).enu)
            // A heading error means Core Motion's reference is yawed relative to true north.
            let badPose = CameraPose(referenceToDevice: truePose.referenceToDevice * Rotation.rz(Angle.radians(headingError)))
            let trueProjector = Projector(pose: truePose, intrinsics: Self.intr, mapping: Self.mapping)
            let tap = try #require(trueProjector.screenPoint(enu: target.enu))
            guard let result = TapToAlign.align(tap: tap, pose: badPose, intrinsics: Self.intr, mapping: Self.mapping,
                                                candidates: [target], mode: .night,
                                                maxSeparation: Angle.radians(20)) else {
                Issue.record("no alignment"); continue
            }
            var corrected = badPose
            corrected.headingCorrection = result.correction
            let after = Projector(pose: corrected, intrinsics: Self.intr, mapping: Self.mapping)
            let landed = try #require(after.screenPoint(enu: target.enu))
            worstResidual = max(worstResidual, simd_distance(landed, tap))
            #expect(result.residual < 1e-9)
        }
        report(String(format: "tap-to-align: object lands %.2e pt from the tap after yaw correction (500 trials, heading errors up to 12 deg)", worstResidual))
        #expect(worstResidual < 1e-6)
    }

    @Test func candidateFilteringByMode() {
        let bright = Self.star(1, mag: 1.2, alt: 30, az: 100)
        let faint = Self.star(2, mag: 2.5, alt: 30, az: 100.5)
        let venus = AlignmentCandidate(kind: .planet(.venus), name: "Venus", magnitude: -4, enu: bright.enu)
        let mars = AlignmentCandidate(kind: .planet(.mars), name: "Mars", magnitude: 0, enu: bright.enu)
        let sun = AlignmentCandidate(kind: .sun, name: "Sun", magnitude: -26.7, enu: bright.enu)
        let moon = AlignmentCandidate(kind: .moon, name: "Moon", magnitude: -10, enu: bright.enu)
        #expect(TapToAlign.isEligible(bright, mode: .night))
        #expect(!TapToAlign.isEligible(faint, mode: .night))
        #expect(!TapToAlign.isEligible(bright, mode: .day))
        #expect(TapToAlign.isEligible(venus, mode: .day) && TapToAlign.isEligible(venus, mode: .night))
        #expect(!TapToAlign.isEligible(mars, mode: .night))
        #expect(TapToAlign.isEligible(sun, mode: .day) && !TapToAlign.isEligible(sun, mode: .night))
        #expect(TapToAlign.isEligible(moon, mode: .day) && TapToAlign.isEligible(moon, mode: .night))
        #expect(TapToAlign.isEligible(sun, mode: .twilight) && TapToAlign.isEligible(bright, mode: .twilight))
    }

    @Test func picksNearestWithinFiveDegrees() throws {
        let pose = CameraPose.looking(at: HorizontalCoordinates(altitude: Angle.radians(30), azimuth: Angle.radians(100)).enu)
        let projector = Projector(pose: pose, intrinsics: Self.intr, mapping: Self.mapping)
        let a = Self.star(1, mag: 0.1, alt: 30, az: 100)
        let b = Self.star(2, mag: 1.5, alt: 31, az: 101)
        let far = Self.star(3, mag: -1, alt: 40, az: 100)
        let tap = try #require(projector.screenPoint(enu: b.enu)) + SIMD2(2, 0)
        let r = try #require(TapToAlign.align(tap: tap, pose: pose, intrinsics: Self.intr, mapping: Self.mapping,
                                              candidates: [a, b, far], mode: .night))
        #expect(r.candidate.kind == .star(hip: 2))
        let farTap = try #require(projector.screenPoint(enu: HorizontalCoordinates(altitude: Angle.radians(36), azimuth: Angle.radians(100)).enu))
        #expect(TapToAlign.align(tap: farTap, pose: pose, intrinsics: Self.intr, mapping: Self.mapping,
                                 candidates: [a, b], mode: .night) == nil)
    }

    @Test func correctionPersistsAndComposes() throws {
        let c = HeadingCorrection(yaw: 0.1, alignedAt: Date(timeIntervalSince1970: 1_800_000_000), headingAccuracyAtAlignment: 5)
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(HeadingCorrection.self, from: data)
        #expect(back == c)
        let composed = c.composed(withDelta: 0.05)
        #expect(abs(composed.yaw - 0.15) < 1e-15)
        let m = composed.matrix, m2 = c.matrix * HeadingCorrection(yaw: 0.05).matrix
        #expect(rotationAngle(m, m2) < 1e-15)
        #expect(!c.shouldSuggestRealign(currentHeadingAccuracy: 7))
        #expect(c.shouldSuggestRealign(currentHeadingAccuracy: 12))
        #expect(HeadingCorrection.identity.shouldSuggestRealign(currentHeadingAccuracy: 25))
    }
}

@Suite struct ClippingTests {
    static let intr = CameraIntrinsics.fieldOfView(horizontalDegrees: 60, bufferWidth: 1920, bufferHeight: 1080)
    static let mapping = ScreenMapping.portraitAspectFill(bufferWidth: 1920, bufferHeight: 1080, viewWidth: 390, viewHeight: 844)
    static let projector = Projector(pose: .looking(at: SIMD3(0, 1, 0)), intrinsics: intr, mapping: mapping)

    @Test func segmentPartlyBehindCameraKeepsVisiblePart() throws {
        let front = simd_normalize(SIMD3<Double>(0.05, 1, 0.05))
        let behind = simd_normalize(SIMD3<Double>(0.1, -1, 0.3))
        let seg = try #require(Self.projector.clipSegment(front, behind))
        #expect(seg.startT == 0)
        #expect(seg.endT > 0 && seg.endT < 1)
        let p0 = try #require(Self.projector.screenPoint(enu: front))
        #expect(simd_distance(seg.start, p0) < 1e-9)
        #expect(Self.projector.clipSegment(-front, behind) == nil)
    }

    @Test func clippedEndpointsLieOnTheChord() throws {
        var g = SplitMixRNG(seed: 11)
        var worst = 0.0, worstRestricted = 0.0, checked = 0
        func onChord(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD2<Double>? {
            let p = a + (b - a) * t
            guard simd_dot(Self.projector.camera(enu: p), SIMD3(0, 0, 1)) > 0.05 * simd_length(p) else { return nil }
            return Self.projector.screenPoint(enu: simd_normalize(p))
        }
        for _ in 0..<5000 {
            let a = randomUnitVector(&g), b = randomUnitVector(&g)
            guard let seg = Self.projector.clipSegment(a, b, guardBand: 50) else { continue }
            #expect(seg.startT >= 0 && seg.endT <= 1 && seg.startT <= seg.endT)
            for (t, s) in [(seg.startT, seg.start), (seg.endT, seg.end)] {
                guard let q = onChord(a, b, t) else { continue }
                worst = max(worst, simd_distance(q, s))
                checked += 1
            }
            let cut = Double.random(in: 0...1, using: &g)
            if let part = seg.restricted(to: 0, cut) {
                #expect(part.endT <= cut + 1e-12)
                if let q = onChord(a, b, part.endT) { worstRestricted = max(worstRestricted, simd_distance(q, part.end)) }
            }
        }
        report(String(format: "clipping: chord parameter vs screen position max %.2e pt over %d endpoints; partial-draw tip max %.2e pt", worst, checked, worstRestricted))
        #expect(worst < 1e-6)
        #expect(worstRestricted < 1e-6)
    }

    @Test func polylineAndPolygonClipping() {
        let ring = (0..<36).map { i -> SIMD3<Double> in
            let a = Double(i) * 10 * .pi / 180
            return simd_normalize(SIMD3(0.3 * cos(a), 1, 0.3 * sin(a)))
        }
        let polygon = Self.projector.clipPolygon(ring)
        #expect(polygon?.count == 36)
        let backRing = ring.map { SIMD3($0.x, -$0.y, $0.z) }
        #expect(Self.projector.clipPolygon(backRing) == nil)
        let halfRing = (0..<36).map { i -> SIMD3<Double> in
            let a = Double(i) * 10 * .pi / 180
            return SIMD3(cos(a), sin(a), 0.1)
        }
        let clipped = Self.projector.clipPolygon(halfRing)
        #expect(clipped != nil && clipped!.count < 36)
        let lines = Self.projector.clipPolyline(halfRing)
        #expect(!lines.isEmpty)
    }
}
