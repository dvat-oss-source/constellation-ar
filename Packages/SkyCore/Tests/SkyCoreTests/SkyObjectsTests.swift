import Foundation
import Testing
import simd
@testable import SkyCore

@Suite struct CatalogTests {
    @Test(.enabled(if: RepoFiles.exists("Data/stars.bin")))
    func starsBinLoads() throws {
        let cat = try StarCatalog(url: RepoFiles.url("Data/stars.bin"))
        #expect(cat.stars.count > 8000)
        #expect(zip(cat.stars, cat.stars.dropFirst()).allSatisfy { $0.vmag <= $1.vmag })
        #expect(cat.stars.allSatisfy { abs(simd_length($0.direction) - 1) < 1e-5 })
        let sirius = try #require(cat.star(hip: 32349))
        #expect(sirius.vmag < -1.4)
        report("stars.bin: \(cat.stars.count) stars, pmEpoch \(cat.pmEpoch)")
    }

    @Test(.enabled(if: RepoFiles.exists("Data/lines.json") && RepoFiles.exists("Data/stars.bin")))
    func linesReferenceCatalogStars() throws {
        let cat = try StarCatalog(url: RepoFiles.url("Data/stars.bin"))
        let lines = try ConstellationLines(url: RepoFiles.url("Data/lines.json"))
        #expect(lines.constellations.count == 88)
        let missing = lines.constellations.flatMap { $0.starHips }.filter { cat.star(hip: $0) == nil }
        #expect(missing.isEmpty, "missing HIPs \(missing.prefix(10))")
        let infos = try ConstellationList.load(url: RepoFiles.url("Data/constellations.json"))
        #expect(infos.count == 88)
    }

    @Test(.enabled(if: RepoFiles.exists("Data/names.json") && RepoFiles.exists("Data/stars.bin")))
    func labelsAreFiftyBrightNamedStars() throws {
        let cat = try StarCatalog(url: RepoFiles.url("Data/stars.bin"))
        let labels = SkyLabels.starLabels(names: try StarNames(url: RepoFiles.url("Data/names.json")), catalog: cat)
        #expect(labels.count >= 45 && labels.count <= 50)
        #expect(labels.first?.name == "Sirius")
    }

    @Test func rejectsBadHeader() {
        #expect(throws: CatalogError.badMagic) { try StarCatalog(data: Data(repeating: 0, count: 24)) }
    }

    @Test func starAppearance() {
        #expect(StarAppearance.radius(vmag: 0.5, k: 1.5) == 9)
        #expect(StarAppearance.radius(vmag: 7, k: 1.5) == 0)
        let blue = StarAppearance.tint(bv: -0.3), red = StarAppearance.tint(bv: 1.8), sun = StarAppearance.tint(bv: 0.65)
        #expect(blue.z >= blue.x && red.x >= red.z)
        #expect(sun.x > 0.9 && sun.y > 0.75)
        #expect(StarAppearance.tint(bv: .nan) == SIMD3(1, 1, 1))
        #expect(abs(StarAppearance.temperature(bv: 0.65) - 5800) < 150)
    }
}

@Suite struct DeepSkyTests {
    @Test(.enabled(if: RepoFiles.exists("Data/dso.json")))
    func zoomDependentSelection() throws {
        let catalog = try DeepSkyCatalog(url: RepoFiles.url("Data/dso.json"))
        let m42 = try #require(catalog.objects.first { $0.messier == 42 })
        #expect(m42.kind == .nebula || m42.kind == .clusterWithNebula)
        #expect(m42.displayName.hasPrefix("M42"))
        let date = ISO8601DateFormatter().date(from: "2027-01-15T04:00:00Z")!
        let session = SkySession(date: date, location: GeoLocation(latitude: 40, longitude: -105))
        let m = session.icrsToENU(at: session.epoch)
        let selection = DeepSkySelection()
        var counts: [Int] = []
        for fov in [70.0, 35, 15, 5] {
            let intr = CameraIntrinsics.fieldOfView(horizontalDegrees: fov, bufferWidth: 1920, bufferHeight: 1080)
            let mapping = ScreenMapping.portraitAspectFill(bufferWidth: 1920, bufferHeight: 1080, viewWidth: 390, viewHeight: 844)
            let projector = Projector(pose: .looking(at: m * m42.direction), intrinsics: intr, mapping: mapping)
            let visible = selection.select(catalog.objects, projector: projector, icrsToENU: m, horizontalFOVDegrees: fov)
            #expect(visible.count <= selection.countLimit(horizontalFOVDegrees: fov))
            #expect(visible.allSatisfy { projector.isOnScreen($0.screenPoint) })
            #expect(visible.contains { $0.object.messier == 42 })
            counts.append(visible.count)
        }
        report("DSO selection around M42 (FOV 70/35/15/5 deg): \(counts) objects; limits \( [70.0, 35, 15, 5].map { selection.countLimit(horizontalFOVDegrees: $0) }) mag \( [70.0, 35, 15, 5].map { String(format: "%.1f", selection.magnitudeLimit(horizontalFOVDegrees: $0)) })")
        #expect(selection.magnitudeLimit(horizontalFOVDegrees: 10) > selection.magnitudeLimit(horizontalFOVDegrees: 60))
        #expect(selection.countLimit(horizontalFOVDegrees: 10) > selection.countLimit(horizontalFOVDegrees: 60))
    }
}

@Suite struct ArtworkTests {
    @Test func syntheticAnchorsLandOnStars() throws {
        var g = SplitMixRNG(seed: 21)
        var worst = 0.0
        for _ in 0..<1000 {
            let c = randomUnitVector(&g)
            let stars = (0..<3).map { _ in simd_normalize(c + 0.25 * randomUnitVector(&g)) }
            let pixels = (0..<3).map { _ in SIMD2(Double.random(in: 0...512, using: &g), Double.random(in: 0...512, using: &g)) }
            guard let placement = try? ArtworkPlacement(id: "T", imageSize: SIMD2(512, 512), anchorPixels: pixels,
                                                        anchorDirections: stars) else { continue }
            for k in 0..<3 { worst = max(worst, Angle.separation(placement.direction(pixel: pixels[k]), stars[k])) }
        }
        report(String(format: "artwork synthetic anchors: max %.2e rad", worst))
        #expect(worst < 1e-12)
    }

    @Test(.enabled(if: RepoFiles.exists("Data/artwork.json") && RepoFiles.exists("Data/stars.bin")))
    func realArtworkAnchorsLandOnTheirStars() throws {
        let cat = try StarCatalog(url: RepoFiles.url("Data/stars.bin"))
        let infos = try ArtworkInfo.load(url: RepoFiles.url("Data/artwork.json"))
        let date = ISO8601DateFormatter().date(from: "2027-01-15T04:00:00Z")!
        let session = SkySession(date: date, location: GeoLocation(latitude: 0, longitude: 0))
        let m = session.icrsToENU(at: session.epoch)
        let intr = CameraIntrinsics.fieldOfView(horizontalDegrees: 60, bufferWidth: 1920, bufferHeight: 1080)
        let mapping = ScreenMapping.portraitAspectFill(bufferWidth: 1920, bufferHeight: 1080, viewWidth: 390, viewHeight: 844)
        var worstAngle = 0.0, worstPoints = 0.0, maxCornerAngle = 0.0
        var failures: [String] = []
        for info in infos {
            let placement: ArtworkPlacement
            do { placement = try ArtworkPlacement(info: info, catalog: cat) } catch {
                failures.append("\(info.id): \(error)"); continue
            }
            let centre = placement.direction(pixel: placement.imageSize / 2)
            let projector = Projector(pose: .looking(at: m * centre), intrinsics: intr, mapping: mapping)
            for a in info.anchors {
                let star = try #require(cat.star(hip: a.hip)).directionDouble
                let mapped = placement.direction(pixel: SIMD2(a.pos[0], a.pos[1]))
                worstAngle = max(worstAngle, Angle.separation(mapped, star))
                if let s1 = projector.screenPoint(enu: m * mapped), let s2 = projector.screenPoint(enu: m * star) {
                    worstPoints = max(worstPoints, simd_distance(s1, s2))
                }
            }
            for corner in [SIMD2<Double>(0, 0), SIMD2(placement.imageSize.x, 0), SIMD2(0, placement.imageSize.y), placement.imageSize] {
                maxCornerAngle = max(maxCornerAngle, Angle.separation(placement.direction(pixel: corner), centre))
            }
            #expect(placement.mesh().allSatisfy { $0.direction.x.isFinite })
        }
        report(String(format: "artwork (%d images): anchors land on stars within %.2e rad / %.2e pt; widest image corner %.1f deg from centre; failures %@",
                      infos.count, worstAngle, worstPoints, Angle.degrees(maxCornerAngle), failures.description))
        #expect(failures.isEmpty)
        #expect(worstAngle < 1e-9)
        #expect(worstPoints < 1e-6)
        #expect(maxCornerAngle < Angle.radians(80))
    }
}

@Suite struct MilkyWayTests {
    @Test(.enabled(if: RepoFiles.exists("Data/milkyway.json")))
    func membershipAndRaster() throws {
        let mw = try MilkyWay(url: RepoFiles.url("Data/milkyway.json"))
        let galacticCentre = SIMD3<Double>.unit(lon: Angle.radians(266.405), lat: Angle.radians(-28.936))
        let northGalacticPole = SIMD3<Double>.unit(lon: Angle.radians(192.859), lat: Angle.radians(27.128))
        let cygnus = SIMD3<Double>.unit(lon: Angle.radians(305), lat: Angle.radians(40))
        #expect(mw.level(at: galacticCentre) >= 3)
        #expect(mw.level(at: northGalacticPole) == 0)
        #expect(mw.level(at: cygnus) >= 1)
        let w = 360, h = 180
        let raster = mw.rasterize(width: w, height: h)
        var g = SplitMixRNG(seed: 5)
        var mismatches = 0
        for _ in 0..<300 {
            let col = Int.random(in: 0..<w, using: &g), row = Int.random(in: 0..<h, using: &g)
            let level = mw.level(raDegrees: (Double(col) + 0.5) * 360 / Double(w), decDegrees: 90 - (Double(row) + 0.5) * 180 / Double(h))
            if Int(raster[row * w + col]) != level { mismatches += 1 }
        }
        let coverage = Double(raster.filter { $0 > 0 }.count) / Double(raster.count)
        report(String(format: "Milky Way raster: %.0f%% of equirect pixels inside level>=1; raster vs ray-test mismatches %d/300", coverage * 100, mismatches))
        #expect(mismatches == 0)
        #expect(coverage > 0.1 && coverage < 0.5)
    }
}

@Suite struct DeepDiveTests {
    @Test(.enabled(if: RepoFiles.exists("Data/stars.bin") && RepoFiles.exists("Data/roman1875.json")
                   && RepoFiles.exists("Data/lines.json") && RepoFiles.exists("Data/names.json") && RepoFiles.exists("Data/dso.json")))
    func orionFacts() throws {
        let cat = try StarCatalog(url: RepoFiles.url("Data/stars.bin"))
        let roman = try RomanLookup(url: RepoFiles.url("Data/roman1875.json"))
        let lines = try ConstellationLines(url: RepoFiles.url("Data/lines.json"))
        let names = try StarNames(url: RepoFiles.url("Data/names.json"))
        let dso = try DeepSkyCatalog(url: RepoFiles.url("Data/dso.json"))
        let membership = ConstellationMembership(catalog: cat, roman: roman)
        let date = ISO8601DateFormatter().date(from: "2026-10-25T11:00:00Z")!
        let boulder = GeoLocation(latitude: 40, longitude: -105, height: 1600)
        let session = SkySession(date: date, location: boulder)
        let snapshot = try SolarSystem.snapshot(at: session.epoch, session: session)
        let inOrion = dso.objects.filter { roman.constellation(icrs: $0.direction) == "Ori" }
        var pass: DeepDiveFacts.PassFact?
        if RepoFiles.exists("Data/fixtures/omm_snapshot.json") {
            let satellites = try OMMParser.satellites(from: Data(contentsOf: RepoFiles.url("Data/fixtures/omm_snapshot.json")))
            let summary = try #require(try SatellitePassPredictor().nextISSPassSummary(satellites: satellites, location: boulder, now: date))
            pass = DeepDiveFacts.PassFact(summary)
            #expect(pass!.start >= date.addingTimeInterval(-1800) && pass!.visible)
        }
        let facts = DeepDiveFactsBuilder.build(constellationID: "Ori", constellationName: "Orion", figure: lines.figure("Ori"),
                                               catalog: cat, membership: membership, names: names, session: session,
                                               instant: session.epoch, solarSystem: snapshot, roman: roman, inView: inOrion,
                                               nextISSPass: pass, timeZone: TimeZone(identifier: "America/Denver")!)
        #expect(facts.brightestVisibleStars.map(\.hip) == [24436, 27989, 25336])
        #expect(facts.brightestVisibleStars.first?.name == "Rigel")
        #expect(facts.constellationAltitudeDegrees > 20)
        #expect(facts.daylight == .night)
        #expect(facts.deepSkyObjectsInView.contains { $0.name.hasPrefix("M42") })
        #expect(membership.idByStarIndex.allSatisfy { $0 != nil })
        let roundTrip = try JSONDecoder().decode(DeepDiveFacts.self, from: JSONEncoder().encode(facts))
        #expect(roundTrip == facts)
        report("deep-dive prompt facts:\n" + facts.promptText)
    }
}
