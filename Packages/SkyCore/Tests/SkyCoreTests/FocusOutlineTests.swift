import Foundation
import Testing
import simd
@testable import SkyCore

@Suite struct FocusOutlineTests {
    static let enabled = RepoFiles.exists("Data/artwork_outlines.json") && RepoFiles.exists("Data/artwork.json") && RepoFiles.exists("Data/stars.bin")

    @Test(.enabled(if: enabled))
    func everyArtworkHasAnOutlineExceptPupVelSer() throws {
        let outlines = try ArtworkOutlines(url: RepoFiles.url("Data/artwork_outlines.json"))
        let infos = try ArtworkInfo.load(url: RepoFiles.url("Data/artwork.json"))
        #expect(infos.count == 85 && outlines.outlines.count == 85)
        for info in infos {
            let o = try #require(outlines.outline(for: info.id), "\(info.id) outline")
            #expect(o.size == SIMD2(info.size[0], info.size[1]))
            #expect(!o.paths.isEmpty)
            for path in o.paths {
                #expect(path.first == path.last && path.count >= 4)
                #expect(path.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x <= o.size.x && $0.y <= o.size.y })
            }
        }
        for id in ["Pup", "Vel", "Ser"] {
            #expect(!outlines.hasOutline(for: id) && ArtworkOutlines.idsWithoutOwnArtwork.contains(id))
            #expect(!infos.contains { $0.id == id })
        }
        #expect(Set(infos.map(\.id)).union(ArtworkOutlines.idsWithoutOwnArtwork).count == 88)
    }

    @Test(.enabled(if: enabled))
    func outlinesMapToTheSkyNearTheirAnchors() throws {
        let outlines = try ArtworkOutlines(url: RepoFiles.url("Data/artwork_outlines.json"))
        let infos = try ArtworkInfo.load(url: RepoFiles.url("Data/artwork.json"))
        let catalog = FocusData.catalog
        var worstAnchor = 0.0, maxPoints = 0
        for info in infos {
            let placement = try ArtworkPlacement(info: info, catalog: catalog)
            for a in info.anchors {
                let star = try #require(catalog.star(hip: a.hip))
                worstAnchor = max(worstAnchor, Angle.separation(placement.direction(pixel: SIMD2(a.pos[0], a.pos[1])), star.directionDouble))
            }
            let sky = try #require(try outlines.skyOutline(for: info.id, artwork: infos, catalog: catalog))
            #expect(sky.paths.count == outlines.outlines[info.id]!.paths.count)
            var total = 0.0
            for path in sky.paths {
                maxPoints = max(maxPoints, path.points.count)
                #expect(path.cumulativeLength.first == 0 && path.cumulativeLength.count == path.points.count)
                #expect(zip(path.cumulativeLength, path.cumulativeLength.dropFirst()).allSatisfy { $0 <= $1 })
                #expect(path.points.allSatisfy { abs(simd_length($0) - 1) < 1e-12 })
                // The sky polyline's arc length equals the sum of the separations of the mapped pixels.
                let outline = outlines.outlines[info.id]!
                let pixels = outline.paths[sky.paths.firstIndex(of: path)!]
                let direct = zip(pixels, pixels.dropFirst()).reduce(0.0) { $0 + Angle.separation(placement.direction(pixel: $1.0), placement.direction(pixel: $1.1)) }
                #expect(abs(direct - path.length) < 1e-9)
                total += path.length
            }
            #expect(abs(total - sky.totalLength) < 1e-9)
            // Outline of the whole picture spans at most the picture itself plus a margin: the arc lengths are finite and positive.
            #expect(sky.totalLength > 0 && sky.totalLength < 40)
        }
        report("artwork outlines on the sky: 85 outlines, anchors land on their stars to \(String(format: "%.2e", arcsec(worstAnchor))) arcsec, longest path \(maxPoints) points")
        #expect(arcsec(worstAnchor) < 1)
    }

    @Test(.enabled(if: enabled))
    func partialPathsTraceInByArcLength() throws {
        let outlines = try ArtworkOutlines(url: RepoFiles.url("Data/artwork_outlines.json"))
        let infos = try ArtworkInfo.load(url: RepoFiles.url("Data/artwork.json"))
        let sky = try #require(try outlines.skyOutline(for: "Ori", artwork: infos, catalog: FocusData.catalog))
        #expect(sky.partialPaths(progress: 0).isEmpty)
        #expect(sky.partialPaths(progress: 1) == sky.paths.map(\.points))
        func length(_ path: [SIMD3<Double>]) -> Double { zip(path, path.dropFirst()).reduce(0) { $0 + Angle.separation($1.0, $1.1) } }
        for progress in [0.1, 0.5, 0.9] {
            let partial = sky.partialPaths(progress: progress)
            for (p, full) in zip(partial, sky.paths.filter { $0.length * progress > 0 }) {
                #expect(abs(length(p) - full.length * progress) < 1e-9, "progress \(progress)")
                #expect(p.first == full.points.first)
            }
        }
        #expect(try ArtworkOutlines(url: RepoFiles.url("Data/artwork_outlines.json")).skyOutline(for: "Pup", artwork: infos, catalog: FocusData.catalog) == nil)
    }
}
