import Foundation
import Testing
import simd
@testable import SkyCore

@Suite struct FocusFactsTests {
    static let eventsFixture = "Data/fixtures/constellation_events.json"
    static let enabled = FocusData.allFiles

    struct EventsFixture: Decodable {
        struct Case: Decodable {
            let constellation: String
            let observer: Int
            let time: Int
            let ref: [Double]
            let status: String
            let rise: Double?
            let transit: Double?
            let set: Double?
        }
        let horizon_deg: Double
        let observers: [FixtureObserver]
        let times: [FixtureTime]
        let cases: [Case]
    }

    @Test(.enabled(if: enabled && RepoFiles.exists(eventsFixture)))
    func riseTransitSetMatchSkyfieldWithinOneMinute() throws {
        let fixture = try RepoFiles.decode(EventsFixture.self, Self.eventsFixture)
        #expect(fixture.horizon_deg == ConstellationAtlas.horizonAltitudeDegrees)
        let atlas = FocusData.atlas
        var worst = 0.0, compared = 0, refWorst = 0.0
        var statusMismatch = 0, byObserver = [Int: Double]()
        for c in fixture.cases {
            let obs = fixture.observers[c.observer]
            let t = fixture.times[c.time]
            let ref = try #require(atlas.referencePoint(of: c.constellation))
            refWorst = max(refWorst, simd_length(ref - SIMD3(c.ref)))
            let facts = try atlas.facts(for: c.constellation, location: obs.location, at: t.instant(useDUT1: true), brightestCount: 0, deepSkyLimit: 0)
            if facts.visibility.rawValue != c.status { statusMismatch += 1; continue }
            #expect(facts.transitAltitudeDegrees.isFinite)
            func compare(_ got: Date?, _ expected: Double?, _ label: String) {
                switch (got, expected) {
                case (nil, nil): break
                case let (g?, e?):
                    let dt = abs(FocusData.jd(g) - e) * 86_400
                    worst = max(worst, dt)
                    byObserver[c.observer] = max(byObserver[c.observer] ?? 0, dt)
                    compared += 1
                    #expect(dt < 60, "\(c.constellation) \(obs.name) t\(c.time) \(label): \(dt) s from Skyfield")
                default: Issue.record("\(c.constellation) \(obs.name) t\(c.time) \(label): presence differs from Skyfield")
                }
            }
            compare(facts.rise, c.rise, "rise")
            compare(facts.transit, c.transit, "transit")
            compare(facts.set, c.set, "set")
        }
        report(String(format: "constellation rise/transit/set vs Skyfield: %d cases, %d events compared, max |dt| %.2f s (per observer %@), reference point max diff %.1e, status mismatches %d",
                      fixture.cases.count, compared, worst, byObserver.sorted { $0.key < $1.key }.map { String(format: "%.2f", $0.value) }.joined(separator: "/"), refWorst, statusMismatch))
        #expect(statusMismatch == 0)
        #expect(refWorst < 1e-6)
        #expect(fixture.cases.count >= 60)
    }

    @Test(.enabled(if: enabled))
    func altitudeAtEventTimesIsConsistentWithTheHorizonConvention() throws {
        let atlas = FocusData.atlas
        let location = GeoLocation(latitude: 40.015, longitude: -105.27, height: 1655)
        let start = FocusData.instant("2026-11-15T12:30:00Z")
        for id in ["Ori", "Sco", "UMa", "Cru", "Cas"] {
            let facts = try atlas.facts(for: id, location: location, at: start, brightestCount: 0, deepSkyLimit: 0)
            let session = SkySession(epoch: start, location: location)
            let ref = try #require(atlas.referencePoint(of: id))
            func altitude(_ date: Date) -> Double {
                let t = AstroInstant(date: date)
                return Angle.degrees(HorizontalCoordinates(enu: session.enu(icrs: ref, at: t)).altitude)
            }
            #expect(abs(altitude(facts.transit) - facts.transitAltitudeDegrees) < 0.01, "\(id) transit altitude")
            if facts.visibility == .risesAndSets, let rise = facts.rise, let set = facts.set {
                #expect(abs(altitude(rise) - ConstellationAtlas.horizonAltitudeDegrees) < 0.005, "\(id) rise altitude")
                #expect(abs(altitude(set) - ConstellationAtlas.horizonAltitudeDegrees) < 0.005, "\(id) set altitude")
                #expect(rise >= start.date && set >= start.date && rise < start.date.addingTimeInterval(86_400))
            } else {
                #expect(facts.rise == nil && facts.set == nil)
            }
        }
    }

    @Test(.enabled(if: enabled))
    func circumpolarAndNeverRisesAreReported() throws {
        let atlas = FocusData.atlas
        let t = FocusData.instant("2027-03-01T05:00:00Z")
        let boulder = GeoLocation(latitude: 40.015, longitude: -105.27)
        let ursaMinor = try atlas.facts(for: "UMi", location: boulder, at: t)
        #expect(ursaMinor.visibility == .circumpolar && ursaMinor.rise == nil && ursaMinor.set == nil && ursaMinor.isAboveHorizon)
        let octans = try atlas.facts(for: "Oct", location: boulder, at: t)
        #expect(octans.visibility == .neverRises && octans.rise == nil && octans.set == nil && !octans.isAboveHorizon && !octans.isVisibleNow)
        let crux = try atlas.facts(for: "Cru", location: GeoLocation(latitude: 60, longitude: 10), at: t)
        #expect(crux.visibility == .neverRises)
        let orion = try atlas.facts(for: "Ori", location: boulder, at: t)
        #expect(orion.visibility == .risesAndSets && orion.rise != nil && orion.set != nil)
    }

    @Test(.enabled(if: enabled))
    func visibleNowNeedsHorizonAndDarkSky() throws {
        let atlas = FocusData.atlas
        let boulder = GeoLocation(latitude: 40.015, longitude: -105.27, height: 1655)
        // 2027-01-15 04:00 UTC = 21:00 MST: Orion high in the south-east, Scorpius below the horizon.
        let night = FocusData.instant("2027-01-15T04:00:00Z")
        let orion = try atlas.facts(for: "Ori", location: boulder, at: night)
        #expect(orion.isVisibleNow && orion.altitudeDegrees > 20 && orion.sunAltitudeDegrees < -6)
        let scorpius = try atlas.facts(for: "Sco", location: boulder, at: night)
        #expect(!scorpius.isVisibleNow && !scorpius.isAboveHorizon && scorpius.altitudeDegrees < 0)
        // 19:00 UTC = noon: Orion is below the horizon anyway; Sagittarius-adjacent Sun makes any figure invisible.
        let noon = FocusData.instant("2027-01-15T19:00:00Z")
        let sun = try SolarSystem.sunAltitudeDegrees(at: noon, session: SkySession(epoch: noon, location: boulder))
        #expect(sun > 20)
        for c in atlas.constellations {
            let f = try atlas.facts(for: c.id, location: boulder, at: noon, brightestCount: 0, deepSkyLimit: 0)
            #expect(!f.isVisibleNow, "\(c.id) cannot be visible at noon")
        }
    }

    @Test(.enabled(if: enabled))
    func everyConstellationHasAReferencePointInsideTheSkyAndFacts() throws {
        let atlas = FocusData.atlas
        #expect(atlas.constellations.count == 88)
        let location = GeoLocation(latitude: -33.87, longitude: 151.21)
        let t = FocusData.instant("2027-06-20T10:00:00Z")
        for c in atlas.constellations {
            let ref = try #require(atlas.referencePoint(of: c.id), "\(c.id) has no figure")
            #expect(abs(simd_length(ref) - 1) < 1e-12)
            let f = try atlas.facts(for: c.id, location: location, at: t)
            #expect(f.altitudeDegrees >= -90 && f.altitudeDegrees <= 90 && f.azimuthDegrees >= 0 && f.azimuthDegrees < 360)
            #expect(!f.brightestStars.isEmpty, "\(c.id) has stars")
        }
    }

    // MARK: Brightest stars vs the Yale BSC

    struct BSCFile: Decodable {
        let records: [String: [BSCValue]]
    }

    enum BSCValue: Decodable {
        case number(Double), text(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .number(d) } else { self = .text(try c.decode(String.self)) }
        }
        var number: Double? { if case let .number(d) = self { d } else { nil } }
        var text: String? { if case let .text(s) = self { s } else { nil } }
    }

    static let greek: [String: String] = [
        "Alp": "α", "Bet": "β", "Gam": "γ", "Del": "δ", "Eps": "ε", "Zet": "ζ", "Eta": "η", "The": "θ", "Iot": "ι", "Kap": "κ",
        "Lam": "λ", "Mu": "μ", "Nu": "ν", "Xi": "ξ", "Omi": "ο", "Pi": "π", "Rho": "ρ", "Sig": "σ", "Tau": "τ", "Ups": "υ",
        "Phi": "φ", "Chi": "χ", "Psi": "ψ", "Ome": "ω",
    ]
    static let superscripts: [Character: String] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]

    /// Reads the raw BSC "Name" field (bytes 5-14) on its own, without the Python code's help.
    static func designation(rawName: String, hr: Int, constellations: Set<String>) -> String {
        let c = Array(rawName.padding(toLength: 10, withPad: " ", startingAt: 0))
        let flamsteed = String(c[0..<3]).trimmingCharacters(in: .whitespaces)
        let bayer = String(c[3..<6]).trimmingCharacters(in: .whitespaces)
        let sup = String(c[6]).trimmingCharacters(in: .whitespaces)
        let con = String(c[7..<10]).trimmingCharacters(in: .whitespaces)
        guard constellations.contains(con), flamsteed.isEmpty || Int(flamsteed) != nil else { return "HR \(hr)" }
        if let g = greek[bayer] { return g + (sup.first.flatMap { superscripts[$0] } ?? "") + " " + con }
        if bayer.isEmpty, !flamsteed.isEmpty { return "\(flamsteed) \(con)" }
        return "HR \(hr)"
    }

    @Test(.enabled(if: enabled && RepoFiles.exists("Data/test/bsc_records.json")))
    func brightestStarsMatchTheYaleBrightStarCatalogue() throws {
        let bsc = try RepoFiles.decode(BSCFile.self, "Data/test/bsc_records.json")
        let atlas = FocusData.atlas
        let ids = Set(atlas.constellations.map(\.id))
        let location = GeoLocation(latitude: 0, longitude: 0)
        let t = FocusData.instant("2027-01-01T00:00:00Z")
        var listed = 0, withRecord = 0, designationMismatches: [String] = [], worstMag = 0.0, worstStar = "", withoutRecord: [String] = []
        var byKind = [String: Int](), magnitudeOutliers: [String] = []
        for c in atlas.constellations {
            let facts = try atlas.facts(for: c.id, location: location, at: t, brightestCount: 5, deepSkyLimit: 0)
            #expect(facts.brightestStars.count == 5)
            #expect(zip(facts.brightestStars, facts.brightestStars.dropFirst()).allSatisfy { $0.vmag <= $1.vmag })
            for star in facts.brightestStars {
                listed += 1
                guard let record = bsc.records[String(star.hip)], record.count == 3,
                      let hr = record[0].number, let raw = record[1].text, let v = record[2].number else {
                    withoutRecord.append("\(c.id) HIP \(star.hip) \(star.displayName)")
                    #expect(star.designation == nil, "no BSC record, so no designation")
                    continue
                }
                withRecord += 1
                let expected = Self.designation(rawName: raw, hr: Int(hr), constellations: ids)
                byKind[expected.hasPrefix("HR") ? "HR" : (expected.first!.isNumber ? "Flamsteed" : "Bayer"), default: 0] += 1
                if star.designation != expected { designationMismatches.append("\(c.id) HIP \(star.hip): \(star.designation ?? "nil") vs BSC \(expected)") }
                #expect(star.displayName == (star.iauName ?? expected))
                let dm = abs(star.vmag - v)
                if dm > worstMag { worstMag = dm; worstStar = "\(c.id) \(star.displayName) catalog \(star.vmag) BSC \(v)" }
                if dm > 0.15 { magnitudeOutliers.append("\(c.id) \(star.displayName) \(star.vmag)/\(v)") }
            }
        }
        report("brightest stars vs Yale BSC: \(listed) listed, \(withRecord) with a BSC record (\(byKind)), designation mismatches \(designationMismatches.count), max |dV| \(String(format: "%.2f", worstMag)) (\(worstStar)); without record \(withoutRecord)")
        report("brightest stars with |dV| > 0.15 (variables, double components, Hp vs V): \(magnitudeOutliers.count): \(magnitudeOutliers)")
        #expect(designationMismatches.isEmpty, "\(designationMismatches)")
        #expect(Double(magnitudeOutliers.count) <= 0.05 * Double(withRecord))
        #expect(withRecord >= listed - 8)
    }

    @Test(.enabled(if: enabled))
    func namedBrightStarsUseIAUNameThenDesignation() throws {
        let atlas = FocusData.atlas
        let facts = try atlas.facts(for: "Ori", location: GeoLocation(latitude: 40, longitude: -105), at: FocusData.instant("2027-01-15T04:00:00Z"))
        let names = facts.brightestStars.map(\.displayName)
        #expect(names.first == "Rigel" && names.contains("Betelgeuse"))
        let betelgeuse = try #require(facts.brightestStars.first { $0.iauName == "Betelgeuse" })
        #expect(betelgeuse.designation == "α Ori" && betelgeuse.designationGenitive == "α Orionis")
        #expect(abs(betelgeuse.vmag - 0.45) < 0.02 && (betelgeuse.distanceLightYears ?? 0) > 400)
        // A star without an IAU name shows its designation.
        let unnamed = atlas.brightestStars(in: "Ant", count: 3)
        #expect(unnamed.first?.designation == "α Ant" && unnamed.first?.designationGenitive == "α Antliae" && unnamed.first?.displayName == "α Ant")
    }

    @Test(.enabled(if: enabled))
    func deepSkyObjectsAndBodiesAreInsideTheBorder() throws {
        let atlas = FocusData.atlas
        let location = GeoLocation(latitude: 40.015, longitude: -105.27)
        let t = FocusData.instant("2027-01-15T04:00:00Z")
        let orion = try atlas.facts(for: "Ori", location: location, at: t, deepSkyLimit: 50)
        #expect(orion.deepSkyObjects.contains { $0.messier == 42 } && orion.deepSkyObjects.contains { $0.messier == 78 })
        #expect(orion.deepSkyTotal >= orion.deepSkyObjects.count)
        let mags = orion.deepSkyObjects.compactMap(\.mag)
        #expect(zip(mags, mags.dropFirst()).allSatisfy { $0 <= $1 })
        let andromeda = try atlas.facts(for: "And", location: location, at: t)
        #expect(andromeda.deepSkyObjects.contains { $0.messier == 31 })
        for o in orion.deepSkyObjects { #expect(FocusData.roman.constellation(icrs: o.direction) == "Ori", "\(o.id)") }

        // Every body is in exactly one constellation and agrees with the independent VI/42 table.
        let session = SkySession(epoch: t, location: location)
        let snapshot = try SolarSystem.snapshot(at: t, session: session)
        var seen: [SolarSystemBody: [String]] = [:]
        for c in atlas.constellations {
            for p in try atlas.facts(for: c.id, location: location, at: t, brightestCount: 0, deepSkyLimit: 0).bodies { seen[p.body, default: []].append(c.id) }
        }
        for p in snapshot.bodies {
            let expected = FocusData.roman.constellation(icrs: session.icrs(fromApparentOfDate: p.ofDate))
            #expect(seen[p.body] == [expected ?? "?"], "\(p.body): \(String(describing: seen[p.body])) vs \(expected ?? "nil")")
        }
        #expect(snapshot.bodies.count == 9 && seen.count == 9)
        // Mid-January the Sun is in Sagittarius.
        #expect(seen[.sun] == ["Sgr"])
    }
}
