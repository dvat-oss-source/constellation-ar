import Foundation
import simd

/// Wahba's problem: the rotation `R` minimising Σ wᵢ‖oᵢ − R sᵢ‖², by Horn's quaternion method (the eigenvector of
/// the largest eigenvalue of a symmetric 4×4 matrix, found with Jacobi sweeps).
public enum AttitudeFit {
    public struct Pair: Sendable {
        public var source: SIMD3<Double>
        public var observed: SIMD3<Double>
        public var weight: Double

        public init(source: SIMD3<Double>, observed: SIMD3<Double>, weight: Double = 1) {
            self.source = simd_normalize(source)
            self.observed = simd_normalize(observed)
            self.weight = weight
        }
    }

    public struct Solution: Sendable {
        /// Active rotation taking each `source` onto its `observed`.
        public var rotation: simd_quatd
        /// Weighted RMS angular residual, radians.
        public var rmsResidual: Double
    }

    public static func solve(_ pairs: [Pair]) -> Solution? {
        guard !pairs.isEmpty else { return nil }
        var s = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in pairs {
            for a in 0..<3 { for b in 0..<3 { s[a][b] += p.weight * p.source[a] * p.observed[b] } }
        }
        let trace = s[0][0] + s[1][1] + s[2][2]
        var n: [[Double]] = [
            [trace, s[1][2] - s[2][1], s[2][0] - s[0][2], s[0][1] - s[1][0]],
            [s[1][2] - s[2][1], s[0][0] - s[1][1] - s[2][2], s[0][1] + s[1][0], s[2][0] + s[0][2]],
            [s[2][0] - s[0][2], s[0][1] + s[1][0], -s[0][0] + s[1][1] - s[2][2], s[1][2] + s[2][1]],
            [s[0][1] - s[1][0], s[2][0] + s[0][2], s[1][2] + s[2][1], -s[0][0] - s[1][1] + s[2][2]],
        ]
        let (values, vectors) = jacobiEigen(&n)
        guard let best = values.indices.max(by: { values[$0] < values[$1] }) else { return nil }
        let q = simd_quatd(real: vectors[0][best], imag: SIMD3(vectors[1][best], vectors[2][best], vectors[3][best])).normalized

        var sum = 0.0, weights = 0.0
        for p in pairs {
            let angle = Angle.separation(q.act(p.source), p.observed)
            sum += p.weight * angle * angle
            weights += p.weight
        }
        return Solution(rotation: q, rmsResidual: weights > 0 ? (sum / weights).squareRoot() : 0)
    }

    /// Eigenvalues and eigenvectors (as columns: `vectors[row][column]`) of a symmetric 4×4 matrix.
    static func jacobiEigen(_ a: inout [[Double]]) -> (values: [Double], vectors: [[Double]]) {
        let size = 4
        var v = (0..<size).map { i in (0..<size).map { $0 == i ? 1.0 : 0.0 } }
        for _ in 0..<60 {
            var off = 0.0
            for i in 0..<size { for j in (i + 1)..<size { off += a[i][j] * a[i][j] } }
            if off < 1e-30 { break }
            for p in 0..<size - 1 {
                for q in (p + 1)..<size where abs(a[p][q]) > 1e-300 {
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<size {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<size {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<size {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        return ((0..<size).map { a[$0][$0] }, v)
    }
}

/// One star seen by the camera, held in the Core Motion reference frame.
public struct StarObservation: Sendable, Equatable {
    public var hostTime: Double
    /// Where the catalog says the star is, as drawn (reference frame).
    public var expected: SIMD3<Double>
    /// Where the camera saw it, with the raw Core Motion attitude (no correction) undone (reference frame).
    public var observed: SIMD3<Double>
    public var sigmaDegrees: Double

    public init(hostTime: Double, expected: SIMD3<Double>, observed: SIMD3<Double>, sigmaDegrees: Double) {
        self.hostTime = hostTime
        self.expected = simd_normalize(expected)
        self.observed = simd_normalize(observed)
        self.sigmaDegrees = sigmaDegrees
    }
}

public enum MultiStarAligner {
    /// Oldest observation used, seconds before `now`; older ones are dropped.
    public static let maxAge = 600.0
    /// Weight half-life, seconds: Core Motion's heading wanders, so recent taps count more.
    public static let halfLife = 180.0
    public static let minimumSeparation = Angle.radians(3)
    /// Model floor on the solution's accuracy, degrees.
    public static let sigmaFloor = 0.15

    public struct Solution: Sendable {
        /// Reference-side correction: reference' = rotation · reference.
        public var correction: simd_quatd
        public var rmsResidualDegrees: Double
        public var sigmaDegrees: Double
        public var count: Int
    }

    /// Needs two or more recent stars at least `minimumSeparation` apart, so that all three axes are determined.
    public static func solve(_ observations: [StarObservation], now: Double) -> Solution? {
        let recent = observations.filter { now - $0.hostTime <= maxAge }
        guard recent.count >= 2 else { return nil }
        var widest = 0.0
        for i in recent.indices { for j in recent.indices where j > i {
            widest = max(widest, Angle.separation(recent[i].expected, recent[j].expected))
        } }
        guard widest >= minimumSeparation else { return nil }

        let pairs = recent.map { o -> AttitudeFit.Pair in
            let sigma = max(o.sigmaDegrees, 0.05)
            let decay = pow(0.5, max(now - o.hostTime, 0) / halfLife)
            return AttitudeFit.Pair(source: o.expected, observed: o.observed, weight: decay / (sigma * sigma))
        }
        guard let solution = AttitudeFit.solve(pairs) else { return nil }
        let n = Double(recent.count)
        let rms = Angle.degrees(solution.rmsResidual)
        let sigma = max(sigmaFloor / n.squareRoot(), rms * (2 * n / (2 * n - 3)).squareRoot())
        return Solution(correction: solution.rotation, rmsResidualDegrees: rms, sigmaDegrees: sigma, count: recent.count)
    }
}
