import Foundation
import simd

public struct PlateSolveOptions: Sendable {
    /// First-pass match radius as a fraction of the image width, used right after a pattern hit.
    public var matchRadius = 0.01
    /// Match radius (fraction of width) once rotation and focal scale have been refined.
    public var refinedRadius = 0.004
    /// A solution is accepted when its expected number of chance solutions per image is below this.
    public var falseMatchThreshold = 1e-5
    /// Allowed fractional error of the prior focal length (checked against each pattern's largest edge).
    public var scaleTolerance = 0.05
    /// Edge-ratio tolerance; nil uses the database's build value.
    public var ratioTolerance: Double?
    public var maxPatternStars = 14
    public var minMatches = 6
    public var timeBudget = 0.75
    public init() {}
}

public struct PlateSolveMatch: Sendable {
    public var pixel: SIMD2<Double>
    /// ICRS direction of the matched catalogue star.
    public var direction: SIMD3<Double>
    public var hip: UInt32
    public var residualPixels: Double
}

public struct PlateSolution: Sendable {
    /// Rotation taking catalogue (ICRS) directions to the camera frame (x image-right, y image-down, z forward).
    public var cameraFromCatalog: simd_double3x3
    /// Prior intrinsics with fx and fy scaled by `focalScale`.
    public var intrinsics: CameraIntrinsics
    public var focalScale: Double
    public var matches: [PlateSolveMatch]
    public var rmsPixels: Double
    public var rmsDegrees: Double
    /// Expected number of chance solutions of this quality per image (tetra3's `Prob`).
    public var falseMatchProbability: Double
    public var patternsTried: Int
    public var solveSeconds: Double
}

public struct PlateSolver: Sendable {
    public let database: SolverDatabase

    public init(database: SolverDatabase) { self.database = database }

    public func solve(stars input: [DetectedStar], intrinsics k: CameraIntrinsics,
                      options o: PlateSolveOptions = .init()) -> PlateSolution? {
        let clock = ContinuousClock()
        let started = clock.now
        let db = database
        let stars = input.sorted { $0.flux > $1.flux }.prefix(db.verificationStars)
        let image = Array(stars)
        guard image.count >= 4 else { return nil }
        let width = k.bufferWidth
        let prior = Context(intrinsics: k, stars: image)

        let separation = width * 0.6 / Double(db.verificationStars).squareRoot()
        var patternStars: [Int] = []
        for i in image.indices where patternStars.count < o.maxPatternStars {
            if !patternStars.contains(where: { simd_distance(image[$0].position, image[i].position) < separation }) {
                patternStars.append(i)
            }
        }
        guard patternStars.count >= 4 else { return nil }

        let tolerance = max(o.ratioTolerance ?? db.patternMaxError, db.patternMaxError)
        let bins = Double(db.patternBins)
        let threshold = o.falseMatchThreshold / Double(max(db.patternCount, 1))
        var tried = 0
        var result: PlateSolution?

        _ = Self.forEachCombination(count: patternStars.count, size: 4) { combo in
            if clock.now - started > .seconds(o.timeBudget) { return false }
            let ids = combo.map { patternStars[$0] }
            let vectors = ids.map { prior.vectors[$0] }
            let imageEdges = Self.edges(vectors)
            let largest = imageEdges.sorted.last!
            let ratios = imageEdges.sorted.dropLast().map { $0 / largest }
            tried += 1

            let ranges: [[Int]] = ratios.map {
                let low = max(0, Int(($0 - tolerance) * bins)), high = min(db.patternBins, Int(($0 + tolerance) * bins))
                return Array(low...max(low, high))
            }
            let measured = ratios.map { Int($0 * bins) }
            var keys: [(Int, [Int])] = [(0, [])]
            for (dim, range) in ranges.enumerated() {
                keys = keys.flatMap { partial in
                    range.map { value in
                        let d = value - measured[dim]
                        return (partial.0 + d * d, partial.1 + [value])
                    }
                }
            }
            keys.sort { $0.0 < $1.0 }

            for (_, key) in keys {
                for slot in db.slots(forKeyHash: SolverDatabase.keyHash(key, bins: db.patternBins)) {
                    let catalogEdgeApprox = db.largestEdge(at: slot)
                    if abs(catalogEdgeApprox / largest - 1) > o.scaleTolerance + 0.01 { continue }
                    let (a, b, c, d) = db.pattern(at: slot)
                    let catalog = [db.directions[a], db.directions[b], db.directions[c], db.directions[d]]
                    let catalogEdges = Self.edges(catalog)
                    let catalogLargest = catalogEdges.sorted.last!
                    let catalogRatios = catalogEdges.sorted.dropLast().map { $0 / catalogLargest }
                    if zip(ratios, catalogRatios).contains(where: { abs($0 - $1) > tolerance }) { continue }
                    if abs(catalogLargest / largest - 1) > o.scaleTolerance { continue }
                    if let solution = attempt(ids: ids, catalog: catalog, catalogLargest: catalogLargest,
                                              largestPair: imageEdges.largestPair, context: prior, options: o,
                                              threshold: threshold) {
                        result = solution
                        return false
                    }
                }
            }
            return true
        }
        guard var solution = result else { return nil }
        solution.patternsTried = tried
        solution.solveSeconds = (clock.now - started) / .seconds(1)
        return solution
    }

    // MARK: Pattern attempt

    struct Context {
        var intrinsics: CameraIntrinsics
        var stars: [DetectedStar]
        var vectors: [SIMD3<Double>]

        init(intrinsics k: CameraIntrinsics, stars: [DetectedStar]) {
            intrinsics = k
            self.stars = stars
            vectors = stars.map { Self.vector($0.position, k, 1) }
        }

        static func vector(_ p: SIMD2<Double>, _ k: CameraIntrinsics, _ scale: Double) -> SIMD3<Double> {
            simd_normalize(SIMD3((p.x - k.cx) / (k.fx * scale), (p.y - k.cy) / (k.fy * scale), 1))
        }
    }

    private func attempt(ids: [Int], catalog: [SIMD3<Double>], catalogLargest: Double, largestPair: (Int, Int),
                         context ctx: Context, options o: PlateSolveOptions, threshold: Double) -> PlateSolution? {
        let k = ctx.intrinsics
        let pixels = ids.map { ctx.stars[$0].position }
        var scale = 1.0
        let (pa, pb) = largestPair
        for _ in 0..<4 {
            let angle = Self.angle(Context.vector(pixels[pa], k, scale), Context.vector(pixels[pb], k, scale))
            scale *= angle / catalogLargest
        }
        let body = pixels.map { Context.vector($0, k, scale) }
        let limit = 0.012 * catalogLargest

        let centroid = body.reduce(.zero, +) / 4
        let order = body.indices.sorted { simd_distance_squared(body[$0], centroid) < simd_distance_squared(body[$1], centroid) }
        let orderedBody = order.map { body[$0] }

        func fit(_ reference: [SIMD3<Double>]) -> (simd_double3x3, Double)? {
            guard let r = PlateWahba.rotation(body: orderedBody, reference: reference) else { return nil }
            let worst = zip(orderedBody, reference).map { Self.angle($0, r * $1) }.max() ?? .infinity
            return (r, worst)
        }
        let catCentroid = catalog.reduce(.zero, +) / 4
        let catOrder = catalog.indices.sorted { simd_distance_squared(catalog[$0], catCentroid) < simd_distance_squared(catalog[$1], catCentroid) }
        var best = fit(catOrder.map { catalog[$0] })
        if best == nil || best!.1 > limit {
            for perm in Self.permutations4 {
                if let f = fit(perm.map { catalog[$0] }), f.1 < (best?.1 ?? .infinity) { best = f }
            }
        }
        guard let (rotation0, worst) = best, worst <= limit else { return nil }

        let width = k.bufferWidth
        var rotation = rotation0
        var focal = scale
        var near = nearbyCatalog(rotation: rotation, focalScale: focal, k: k, limit: 2 * ctx.stars.count)
        var pairs = Self.match(near.map(\.pixel), ctx.stars, radius: o.matchRadius * width)
        let n = ctx.stars.count
        guard pairs.count >= o.minMatches,
              Self.mismatchProbability(imageStars: n, matches: pairs.count, nearby: near.count, radius: o.matchRadius * width, k: k) < threshold
        else { return nil }

        for _ in 0..<3 {
            guard let refined = refine(pairs: pairs, near: near, stars: ctx.stars, rotation: rotation, focal: focal, k: k) else { return nil }
            (rotation, focal) = refined
            near = nearbyCatalog(rotation: rotation, focalScale: focal, k: k, limit: 2 * n)
            pairs = Self.match(near.map(\.pixel), ctx.stars, radius: o.refinedRadius * width)
            if pairs.count < o.minMatches { return nil }
        }
        guard let refined = refine(pairs: pairs, near: near, stars: ctx.stars, rotation: rotation, focal: focal, k: k) else { return nil }
        (rotation, focal) = refined

        let final = Self.projectedMatches(pairs: pairs, near: near, stars: ctx.stars, rotation: rotation, focal: focal, k: k, database: database)
        let probability = Self.mismatchProbability(imageStars: n, matches: final.count, nearby: near.count,
                                                   radius: o.refinedRadius * width, k: k)
        guard final.count >= o.minMatches, probability < threshold else { return nil }
        let rms = (final.map { $0.residualPixels * $0.residualPixels }.reduce(0, +) / Double(final.count)).squareRoot()
        var fitted = k
        fitted.fx *= focal
        fitted.fy *= focal
        return PlateSolution(
            cameraFromCatalog: rotation, intrinsics: fitted, focalScale: focal, matches: final, rmsPixels: rms,
            rmsDegrees: Angle.degrees(rms / (0.5 * (fitted.fx + fitted.fy))),
            falseMatchProbability: min(1, probability * Double(database.patternCount)),
            patternsTried: 0, solveSeconds: 0
        )
    }

    private struct Nearby {
        var index: Int
        var pixel: SIMD2<Double>
    }

    /// Catalogue stars (brightest first) that fall inside the image for the given pose, at most `limit` of them.
    private func nearbyCatalog(rotation r: simd_double3x3, focalScale s: Double, k: CameraIntrinsics, limit: Int) -> [Nearby] {
        let boresight = r.transpose * SIMD3(0, 0, 1)
        let halfDiagonal = atan(hypot(k.bufferWidth / (2 * k.fx * s), k.bufferHeight / (2 * k.fy * s))) + 0.02
        let minCos = cos(halfDiagonal)
        var out: [Nearby] = []
        for (i, v) in database.directions.enumerated() where simd_dot(v, boresight) > minCos {
            let c = r * v
            guard c.z > 0.05 else { continue }
            let p = SIMD2(k.fx * s * c.x / c.z + k.cx, k.fy * s * c.y / c.z + k.cy)
            guard p.x >= 0, p.y >= 0, p.x <= k.bufferWidth, p.y <= k.bufferHeight else { continue }
            out.append(Nearby(index: i, pixel: p))
            if out.count == limit { break }
        }
        return out
    }

    /// Greedy one-to-one pairing, closest first, within `radius` pixels: (index into nearby, index into stars).
    private static func match(_ catalog: [SIMD2<Double>], _ stars: [DetectedStar], radius: Double) -> [(Int, Int)] {
        var candidates: [(Double, Int, Int)] = []
        let r2 = radius * radius
        for (ci, c) in catalog.enumerated() {
            for (si, s) in stars.enumerated() {
                let d2 = simd_distance_squared(c, s.position)
                if d2 < r2 { candidates.append((d2, ci, si)) }
            }
        }
        candidates.sort { $0.0 < $1.0 }
        var usedCatalog = Set<Int>(), usedStar = Set<Int>()
        var pairs: [(Int, Int)] = []
        for (_, ci, si) in candidates where !usedCatalog.contains(ci) && !usedStar.contains(si) {
            usedCatalog.insert(ci); usedStar.insert(si)
            pairs.append((ci, si))
        }
        return pairs
    }

    /// Rotation by Wahba on every pair, then the focal scale by least squares on the pixel offsets.
    private func refine(pairs: [(Int, Int)], near: [Nearby], stars: [DetectedStar], rotation: simd_double3x3, focal: Double,
                        k: CameraIntrinsics) -> (simd_double3x3, Double)? {
        let reference = pairs.map { database.directions[near[$0.0].index] }
        let body = pairs.map { Context.vector(stars[$0.1].position, k, focal) }
        guard let r = PlateWahba.rotation(body: body, reference: reference) else { return nil }
        var num = 0.0, den = 0.0
        for (ref, pair) in zip(reference, pairs) {
            let c = r * ref
            guard c.z > 0.05 else { continue }
            let ax = k.fx * c.x / c.z, ay = k.fy * c.y / c.z
            let p = stars[pair.1].position
            num += ax * (p.x - k.cx) + ay * (p.y - k.cy)
            den += ax * ax + ay * ay
        }
        guard den > 0 else { return nil }
        return (r, num / den)
    }

    private static func projectedMatches(pairs: [(Int, Int)], near: [Nearby], stars: [DetectedStar], rotation r: simd_double3x3,
                                         focal s: Double, k: CameraIntrinsics, database: SolverDatabase) -> [PlateSolveMatch] {
        pairs.map { ci, si in
            let index = near[ci].index
            let c = r * database.directions[index]
            let predicted = SIMD2(k.fx * s * c.x / c.z + k.cx, k.fy * s * c.y / c.z + k.cy)
            let p = stars[si].position
            return PlateSolveMatch(pixel: p, direction: database.directions[index], hip: database.hip[index],
                                   residualPixels: simd_distance(predicted, p))
        }
    }

    /// P(at least `matches − 2` of `imageStars` stars land within `radius` of a catalogue star by chance), tetra3's
    /// criterion with the per-star chance taken as the area fraction covered by the nearby catalogue stars.
    static func mismatchProbability(imageStars n: Int, matches m: Int, nearby: Int, radius: Double, k: CameraIntrinsics) -> Double {
        let need = m - 2
        if need <= 0 { return 1 }
        let p = min(0.999, Double(nearby) * .pi * radius * radius / (k.bufferWidth * k.bufferHeight))
        guard n >= need else { return 0 }
        var total = 0.0
        for i in need...n {
            let logTerm = lgamma(Double(n + 1)) - lgamma(Double(i + 1)) - lgamma(Double(n - i + 1))
                + Double(i) * log(p) + Double(n - i) * log1p(-p)
            total += exp(logTerm)
        }
        return min(total, 1)
    }

    // MARK: Helpers

    private struct EdgeSet {
        var sorted: [Double]
        var largestPair: (Int, Int)
    }

    private static func edges(_ v: [SIMD3<Double>]) -> EdgeSet {
        var all: [(Double, Int, Int)] = []
        for i in 0..<4 { for j in (i + 1)..<4 { all.append((angle(v[i], v[j]), i, j)) } }
        all.sort { $0.0 < $1.0 }
        return EdgeSet(sorted: all.map(\.0), largestPair: (all.last!.1, all.last!.2))
    }

    static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { 2 * asin(min(1, 0.5 * simd_distance(a, b))) }

    private static let permutations4: [[Int]] = {
        var out: [[Int]] = []
        for a in 0..<4 { for b in 0..<4 where b != a { for c in 0..<4 where c != a && c != b {
            out.append([a, b, c, 6 - a - b - c])
        } } }
        return out
    }()

    /// Breadth-first combinations (tetra3 / Cedar-Solve order): subsets of the brightest stars come first.
    /// `body` returns false to stop; the result is false if it was stopped.
    @discardableResult
    static func forEachCombination(count n: Int, size r: Int, _ body: ([Int]) -> Bool) -> Bool {
        if r == 1 {
            for i in 0..<n where !body([i]) { return false }
            return true
        }
        var index = r - 1
        while index < n {
            let last = index
            if !forEachCombination(count: index, size: r - 1, { body($0 + [last]) }) { return false }
            index += 1
        }
        return true
    }
}
