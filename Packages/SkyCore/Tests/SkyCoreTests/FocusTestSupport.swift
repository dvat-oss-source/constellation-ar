import Foundation
import simd
@testable import SkyCore

/// Shared, lazily built data for the Focus* suites.
enum FocusData {
    static let dataDirectory = RepoFiles.url("Data")

    static let allFiles = ["stars.bin", "lines.json", "names.json", "designations.json", "constellations.json", "boundaries.json", "dso.json"]
        .allSatisfy { RepoFiles.exists("Data/\($0)") }

    static let boundaries: ConstellationBoundaries = try! ConstellationBoundaries(url: RepoFiles.url("Data/boundaries.json"))
    static let catalog: StarCatalog = try! StarCatalog(url: RepoFiles.url("Data/stars.bin"))
    static let lines: ConstellationLines = try! ConstellationLines(url: RepoFiles.url("Data/lines.json"))
    static let atlas: ConstellationAtlas = try! ConstellationAtlas(dataDirectory: dataDirectory)
    static let hitTest = ConstellationHitTest(boundaries: boundaries, figures: lines.constellations, catalog: catalog)
    static let vi49: VI49Boundaries = try! VI49Boundaries(url: RepoFiles.url("Data/test/vi49_bounds.json"))
    static let roman: RomanLookup = try! RomanLookup(url: RepoFiles.url("Data/roman1875.json"))

    static let library: PassageLibrary = try! PassageLibrary(url: RepoFiles.url("Data/passages.json"))
    static let bm25 = BM25Index(passages: library.passages)
    static let starFacts: StarFactIndex = StarFactIndex(
        catalog: catalog, names: try! StarNames(url: RepoFiles.url("Data/names.json")),
        designations: try! StarDesignations(url: RepoFiles.url("Data/designations.json")),
        constellations: try! ConstellationList.load(url: RepoFiles.url("Data/constellations.json")))
    static let verifier = AnswerVerifier(library: library, stars: starFacts)

    static func instant(_ iso: String, dut1: Double = 0) -> AstroInstant {
        AstroInstant(date: ISO8601DateFormatter().date(from: iso)!, ut1MinusUTC: dut1)
    }

    static func jd(_ date: Date) -> Double { date.timeIntervalSince1970 / 86_400 + AstroInstant.unixEpochJD }
}

extension ConstellationBoundaries {
    /// ICRS ray for a B1875 (RA hours, Dec degrees) point.
    func icrs(raHours1875 ra: Double, decDegrees1875 dec: Double) -> SIMD3<Double> {
        toB1875.transpose * SIMD3<Double>.unit(lon: Angle.radians(ra * 15), lat: Angle.radians(dec))
    }
}
