import Foundation
import Testing
import simd
@testable import SkyCore

@Suite struct FocusHitTestTests {
    static let enabled = FocusData.allFiles && RepoFiles.exists("Data/test/vi49_bounds.json") && RepoFiles.exists("Data/roman1875.json")

    /// B1875 coordinates of an ICRS ray, from the independent VI/42 lookup's matrix.
    static func b1875(_ v: SIMD3<Double>) -> (ra: Double, dec: Double) {
        let (lon, lat) = (FocusData.roman.toB1875 * v).lonLat
        return (Angle.degrees(lon) / 15, Angle.degrees(lat))
    }

    @Test(.enabled(if: enabled))
    func boundaryLookupAgreesWithVI49OnRandomRays() {
        var g = SplitMixRNG(seed: 49)
        var accepted = 0, excluded = 0, disagreements = 0
        var examples: [String] = []
        while accepted < 100_000 {
            let v = randomUnitVector(&g)
            let (ra, dec) = Self.b1875(v)
            if FocusData.vi49.isNearBoundary(raHours: ra, dec: dec, margin: 0.1) { excluded += 1; continue }
            accepted += 1
            let expected = FocusData.vi49.constellations(raHours: ra, dec: dec)
            let got = FocusData.boundaries.constellation(icrs: v)
            if expected.count != 1 || expected.first != got {
                disagreements += 1
                if examples.count < 5 { examples.append("ra \(ra) dec \(dec): VI/49 \(expected) got \(got ?? "nil")") }
            }
        }
        report("hit test boundary lookup vs VI/49: \(accepted) random ICRS rays (\(excluded) within 0.1 deg of a boundary skipped), disagreements \(disagreements) \(examples)")
        #expect(disagreements == 0)
    }

    @Test(.enabled(if: enabled))
    func fullHitTestAgreesWithVI49AwayFromEdgeBand() {
        var g = SplitMixRNG(seed: 1930)
        let band = FocusData.hitTest.edgeBandDegrees
        var accepted = 0, disagreements = 0, nonBoundary = 0
        while accepted < 100_000 {
            let v = randomUnitVector(&g)
            let (ra, dec) = Self.b1875(v)
            if FocusData.vi49.isNearBoundary(raHours: ra, dec: dec, margin: band + 0.2) { continue }
            accepted += 1
            let hit = FocusData.hitTest.hit(icrs: v)
            if hit?.boundaryConstellation != FocusData.vi49.constellations(raHours: ra, dec: dec).first { disagreements += 1 }
            if let hit, hit.source != .boundary, hit.edgeDistanceDegrees >= band { nonBoundary += 1 }
            if let hit, hit.edgeDistanceDegrees >= band, hit.constellation != hit.boundaryConstellation { nonBoundary += 1 }
        }
        report("hit test full (edge band \(band) deg): \(accepted) rays, disagreements \(disagreements), figure fallbacks outside the edge band \(nonBoundary)")
        #expect(disagreements == 0 && nonBoundary == 0)
    }

    @Test(.enabled(if: enabled), arguments: ["Cir", "CrA", "Pic", "Vol"])
    func smallConstellationInteriorsAreHit(id: String) throws {
        let file = try RepoFiles.decode(VI49Boundaries.File.self, "Data/test/vi49_bounds.json")
        let verts = try #require(file.constellations.first { $0.id == id }).polygons.flatMap(\.vertices)
        let raLo = verts.map { $0[0] }.min()!, raHi = verts.map { $0[0] }.max()!
        let sinLo = sin(Angle.radians(verts.map { $0[1] }.min()!)), sinHi = sin(Angle.radians(verts.map { $0[1] }.max()!))
        var g = SplitMixRNG(seed: id.utf8.reduce(7) { $0 &* 31 &+ UInt64($1) })
        var interior = 0, deep = 0, boundaryMisses = 0, hitMisses = 0, tries = 0
        while interior < 300 && tries < 2_000_000 {
            tries += 1
            let ra = Double.random(in: raLo..<raHi, using: &g)
            let dec = Angle.degrees(asin(Double.random(in: sinLo...sinHi, using: &g)))
            guard FocusData.vi49.constellations(raHours: ra, dec: dec) == [id],
                  !FocusData.vi49.isNearBoundary(raHours: ra, dec: dec, margin: 0.1) else { continue }
            interior += 1
            let v = FocusData.boundaries.icrs(raHours1875: ra, decDegrees1875: dec)
            if FocusData.boundaries.constellation(icrs: v) != id { boundaryMisses += 1 }
            let hit = FocusData.hitTest.hit(icrs: v)
            if hit?.boundaryConstellation != id { hitMisses += 1 }
            if hit?.constellation == id { deep += 1 } else if hit?.source != .figureFallback || hit!.edgeDistanceDegrees >= FocusData.hitTest.edgeBandDegrees { hitMisses += 1 }
        }
        report("hit test interior \(id): \(interior) interior rays (\(deep) answered by the boundary itself, the rest by the edge-band figure rule) boundary misses \(boundaryMisses), hit misses \(hitMisses)")
        #expect(interior == 300)
        #expect(boundaryMisses == 0 && hitMisses == 0)
    }

    @Test(.enabled(if: enabled))
    func figureFallbackOnlyAtTheEdgeAndOnlyWithinRadius() {
        var g = SplitMixRNG(seed: 3)
        let ht = FocusData.hitTest
        var fallbacks = 0, edgeRays = 0
        for _ in 0..<60_000 {
            let v = randomUnitVector(&g)
            guard let hit = ht.hit(icrs: v) else { Issue.record("no hit for \(v)"); continue }
            #expect(hit.edgeDistanceDegrees >= 0)
            if hit.edgeDistanceDegrees < ht.edgeBandDegrees { edgeRays += 1 }
            if hit.source == .figureFallback {
                fallbacks += 1
                #expect(hit.edgeDistanceDegrees < ht.edgeBandDegrees, "fallback deep inside \(hit.boundaryConstellation)")
                #expect(hit.constellation != hit.boundaryConstellation)
                let d = hit.figureDistanceDegrees ?? 99
                #expect(d <= ht.figureRadiusDegrees)
                let nearestOwn = ht.segments.filter { $0.constellation == hit.boundaryConstellation }
                    .map { Angle.degrees(SphereGeometry.distance(from: v, toArc: $0.a, $0.b)) }.min() ?? .infinity
                #expect(d < nearestOwn)
                let nearestAny = ht.segments.map { ($0.constellation, Angle.degrees(SphereGeometry.distance(from: v, toArc: $0.a, $0.b))) }
                    .min { $0.1 < $1.1 }!
                #expect(nearestAny.0 == hit.constellation)
            } else {
                #expect(hit.constellation == hit.boundaryConstellation)
            }
        }
        report("hit test fallback: 60000 random rays, \(edgeRays) in an edge band, \(fallbacks) answered by a neighbouring figure")
        #expect(fallbacks > 0 && edgeRays > fallbacks)
    }

    @Test(.enabled(if: enabled))
    func figureStarsResolveToTheirOwnConstellation() throws {
        for (hip, id) in [(27989, "Ori"), (91262, "Lyr"), (11767, "UMi"), (54061, "UMa")] {
            let star = try #require(FocusData.catalog.star(hip: hip))
            #expect(FocusData.hitTest.hit(icrs: star.directionDouble)?.constellation == id, "HIP \(hip)")
        }
    }

    @Test(.enabled(if: enabled))
    func edgeDistanceMatchesBruteForce() {
        var g = SplitMixRNG(seed: 11)
        let b = FocusData.boundaries
        var worst = 0.0
        for _ in 0..<300 {
            let v = randomUnitVector(&g)
            guard let index = b.polygonIndices(raHours1875: b.b1875(icrs: v).raHours, decDegrees1875: b.b1875(icrs: v).decDegrees).first else { continue }
            let d = b.distanceToEdge(icrs: v, polygon: index)
            // Brute force: densified border polyline of that polygon, nearest vertex at 0.01 deg spacing.
            let ring = BoundaryGeometry.ring(b.polygons[index].vertices, step: 0.01).map { b.toB1875.transpose * $0 }
            let brute = ring.map { Angle.degrees(Angle.separation(v, $0)) }.min()!
            worst = max(worst, abs(brute - d))
            #expect(brute >= d - 1e-9)
        }
        report("boundary edge distance vs 0.01-degree brute force: max difference \(String(format: "%.4f", worst)) deg")
        #expect(worst < 0.006)
    }

    // MARK: Boundary geometry

    @Test(.enabled(if: enabled))
    func boundaryPolylinesFollowMeridiansAndParallels() {
        let geometry = BoundaryGeometry(boundaries: FocusData.boundaries, maxStepDegrees: 0.5)
        let b = FocusData.boundaries
        var points = 0, worstStep = 0.0, offCurve = 0, polygonsSeen = 0
        for polygon in b.polygons {
            polygonsSeen += 1
            #expect(!geometry.polylines(for: polygon.constellation).isEmpty)
        }
        for (id, rings) in geometry.rings {
            for ring in rings {
                #expect(simd_distance(ring.first!, ring.last!) < 1e-12, "\(id) ring is closed")
                for (a, c) in zip(ring, ring.dropFirst()) { worstStep = max(worstStep, Angle.degrees(Angle.separation(a, c))) }
                let polys = b.polygons.filter { $0.constellation == id }
                let vertexRAs = Set(polys.flatMap { $0.vertices.map(\.x) }), vertexDecs = Set(polys.flatMap { $0.vertices.map(\.y) })
                for p in ring {
                    points += 1
                    let (ra, dec) = b.b1875(icrs: p)
                    let onMeridian = vertexRAs.contains { abs(Angle.wrapPi(Angle.radians((ra - $0) * 15))) < 1e-9 }
                    let onParallel = vertexDecs.contains { abs(dec - $0) < 1e-7 }
                    if !onMeridian && !onParallel { offCurve += 1 }
                }
            }
        }
        report("boundary geometry: \(polygonsSeen) polygons, \(points) points, max step \(String(format: "%.4f", worstStep)) deg, points off their meridian/parallel \(offCurve)")
        #expect(offCurve == 0)
        #expect(worstStep <= 0.5 + 1e-6)
    }

    @Test(.enabled(if: enabled))
    func parallelEdgesAreSmallCirclesNotGreatCircles() throws {
        // Long constant-Dec edges: the polyline keeps their Dec while a great-circle chord would not.
        let b = FocusData.boundaries
        var long: [(SIMD2<Double>, SIMD2<Double>)] = []
        for polygon in b.polygons {
            for i in 0..<(polygon.vertices.count - 1) {
                let p: SIMD2<Double> = polygon.vertices[i], q: SIMD2<Double> = polygon.vertices[i + 1]
                let span: Double = abs(q.x - p.x)
                if p.y == q.y && span > 0.8 && span < 12 { long.append((p, q)) }
            }
        }
        #expect(long.count > 20)
        for (a, c) in long {
            let samples = BoundaryGeometry.ring([a, c], step: 0.25).map { b.toB1875.transpose * $0 }
            let decs = samples.map { b.b1875(icrs: $0).decDegrees }
            #expect(decs.allSatisfy { abs($0 - a.y) < 1e-7 })
            let chord = simd_normalize(SIMD3<Double>.unit(lon: Angle.radians(a.x * 15), lat: Angle.radians(a.y))
                + SIMD3<Double>.unit(lon: Angle.radians(c.x * 15), lat: Angle.radians(c.y)))
            let mid = SIMD3<Double>.unit(lon: Angle.radians((a.x + c.x) / 2 * 15), lat: Angle.radians(a.y))
            if abs(a.y) > 30 && abs(c.x - a.x) > 1 {
                #expect(Angle.degrees(Angle.separation(chord, mid)) > 0.05, "great-circle midpoint would be off the parallel")
            }
        }
    }

    @Test(.enabled(if: enabled))
    func aBorderPointHasNeighbouringRaysInsideItsOwnConstellation() {
        let geometry = BoundaryGeometry(boundaries: FocusData.boundaries)
        let b = FocusData.boundaries
        var g = SplitMixRNG(seed: 21)
        var checked = 0, wrong = 0
        for polygon in b.polygons {
            let ring = geometry.polylines(for: polygon.constellation)[0]
            for _ in 0..<5 {
                let p = ring[Int.random(in: 0..<(ring.count - 1), using: &g)]
                let east = simd_normalize(simd_cross(SIMD3(0, 0, 1), p)), up = simd_cross(p, east)
                let near = [east, -east, up, -up].map { simd_normalize(p + 0.0008 * $0) }
                checked += 1
                if !near.contains(where: { b.constellation(icrs: $0) == polygon.constellation }) { wrong += 1 }
            }
        }
        report("border points: \(checked) sampled, \(wrong) with no neighbouring ray inside their own constellation")
        #expect(wrong == 0)
    }
}
