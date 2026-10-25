import simd

enum RotationConvention: String, Sendable {
    /// R·(0,0,−1) = gravity: CMAttitude.rotationMatrix maps reference-frame vectors into the device frame.
    case matrixIsDeviceFromReference = "R·(0,0,−1) = g"
    /// Rᵀ·(0,0,−1) = gravity: the matrix maps device vectors into the reference frame, so its transpose is used.
    case matrixIsReferenceFromDevice = "Rᵀ·(0,0,−1) = g"
}

/// Settles the rotationMatrix direction on hardware by comparing both candidates against CMDeviceMotion.gravity.
struct RotationConventionTest: Sendable, Equatable {
    enum Verdict: Sendable, Equatable {
        case pending
        case decided(RotationConvention)
        case inconclusive
    }

    static let requiredSamples = 100
    /// Below this separation the two candidates point the same way and the sample says nothing.
    static let minimumSeparation = 10.0 * Double.pi / 180

    private(set) var samples = 0
    private(set) var skipped = 0
    private(set) var sumErrorDirect = 0.0
    private(set) var sumErrorTransposed = 0.0
    private(set) var verdict: Verdict = .pending

    var meanErrorDirectDegrees: Double { samples == 0 ? .nan : sumErrorDirect / Double(samples) * 180 / .pi }
    var meanErrorTransposedDegrees: Double { samples == 0 ? .nan : sumErrorTransposed / Double(samples) * 180 / .pi }

    /// Convention to use now; before a verdict the direct reading is assumed.
    var convention: RotationConvention {
        if case .decided(let convention) = verdict { return convention }
        return .matrixIsDeviceFromReference
    }

    mutating func add(matrix r: simd_double3x3, gravity g: SIMD3<Double>) {
        guard verdict == .pending, length(g) > 0.5 else { return }
        let down = SIMD3<Double>(0, 0, -1)
        let direct = r * down
        let transposed = r.transpose * down
        // A phone that only yaws (e.g. flat on a table) makes both candidates coincide.
        guard Self.angle(direct, transposed) >= Self.minimumSeparation else {
            skipped += 1
            return
        }
        let gravity = normalize(g)
        sumErrorDirect += Self.angle(direct, gravity)
        sumErrorTransposed += Self.angle(transposed, gravity)
        samples += 1
        guard samples >= Self.requiredSamples else { return }

        let directError = meanErrorDirectDegrees, transposedError = meanErrorTransposedDegrees
        if min(directError, transposedError) < 5, max(directError, transposedError) > 3 * min(directError, transposedError) {
            verdict = .decided(directError < transposedError ? .matrixIsDeviceFromReference : .matrixIsReferenceFromDevice)
        } else {
            verdict = .inconclusive
        }
    }

    var summary: String {
        let errors = samples == 0 ? "" : String(format: " (mean error R %.2f°, Rᵀ %.2f°, n=%d, skipped %d)",
                                                meanErrorDirectDegrees, meanErrorTransposedDegrees, samples, skipped)
        switch verdict {
        case .pending: return "pending: tilt the phone\(errors)"
        case .decided(let convention): return "\(convention.rawValue)\(errors)"
        case .inconclusive: return "inconclusive\(errors)"
        }
    }

    private static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        atan2(length(cross(a, b)), dot(a, b))
    }
}
