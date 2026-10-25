import simd

/// Wahba's problem by Davenport's q-method: the largest eigenvector of a 4×4 symmetric matrix, found with cyclic
/// Jacobi rotations. Always returns a proper rotation (no reflections).
enum PlateWahba {
    /// The rotation `R` minimising Σ |body[i] − R · reference[i]|².
    static func rotation(body: [SIMD3<Double>], reference: [SIMD3<Double>]) -> simd_double3x3? {
        guard body.count == reference.count, body.count >= 2 else { return nil }
        var b = [Double](repeating: 0, count: 9)
        for (v, r) in zip(body, reference) {
            for i in 0..<3 { for j in 0..<3 { b[i * 3 + j] += v[i] * r[j] } }
        }
        let trace = b[0] + b[4] + b[8]
        let z = SIMD3(b[5] - b[7], b[6] - b[2], b[1] - b[3])
        var k = [Double](repeating: 0, count: 16)
        for i in 0..<3 {
            for j in 0..<3 { k[i * 4 + j] = b[i * 3 + j] + b[j * 3 + i] - (i == j ? trace : 0) }
            k[i * 4 + 3] = z[i]
            k[3 * 4 + i] = z[i]
        }
        k[15] = trace
        let q = largestEigenvector(&k)
        let qv = SIMD3(q[0], q[1], q[2]), q4 = q[3]
        let skew = simd_double3x3(rows: [SIMD3(0, -qv.z, qv.y), SIMD3(qv.z, 0, -qv.x), SIMD3(-qv.y, qv.x, 0)])
        let outer = simd_double3x3(columns: (qv * qv.x, qv * qv.y, qv * qv.z))
        let a = (q4 * q4 - simd_dot(qv, qv)) * matrix_identity_double3x3 + 2 * outer - 2 * q4 * skew
        return a
    }

    private static func largestEigenvector(_ a: inout [Double]) -> [Double] {
        var v = [Double](repeating: 0, count: 16)
        for i in 0..<4 { v[i * 5] = 1 }
        for _ in 0..<12 {
            var off = 0.0
            for p in 0..<3 { for q in (p + 1)..<4 { off += a[p * 4 + q] * a[p * 4 + q] } }
            if off < 1e-30 { break }
            for p in 0..<3 {
                for q in (p + 1)..<4 {
                    let apq = a[p * 4 + q]
                    if abs(apq) < 1e-300 { continue }
                    let theta = (a[q * 4 + q] - a[p * 4 + p]) / (2 * apq)
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for r in 0..<4 {
                        let arp = a[r * 4 + p], arq = a[r * 4 + q]
                        a[r * 4 + p] = c * arp - s * arq
                        a[r * 4 + q] = s * arp + c * arq
                    }
                    for r in 0..<4 {
                        let apr = a[p * 4 + r], aqr = a[q * 4 + r]
                        a[p * 4 + r] = c * apr - s * aqr
                        a[q * 4 + r] = s * apr + c * aqr
                    }
                    for r in 0..<4 {
                        let vrp = v[r * 4 + p], vrq = v[r * 4 + q]
                        v[r * 4 + p] = c * vrp - s * vrq
                        v[r * 4 + q] = s * vrp + c * vrq
                    }
                }
            }
        }
        var best = 0
        for i in 1..<4 where a[i * 5] > a[best * 5] { best = i }
        return (0..<4).map { v[$0 * 4 + best] }
    }
}
