import Testing
import simd
@testable import SkyCore

@Suite struct AngleTests {
    @Test func wrapping() {
        #expect(abs(Angle.wrapTwoPi(-0.5) - (2 * .pi - 0.5)) < 1e-15)
        #expect(abs(Angle.wrapPi(3 * .pi / 2) + .pi / 2) < 1e-15)
    }

    @Test func separation() {
        let a = SIMD3<Double>(1, 0, 0)
        let b = SIMD3<Double>(0, 1, 0)
        #expect(abs(Angle.separation(a, b) - .pi / 2) < 1e-15)
    }
}
