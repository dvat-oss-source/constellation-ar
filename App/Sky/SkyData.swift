import Foundation
import SkyCore
import simd

/// One constellation figure resolved against the catalog: segments as catalog indices.
struct FigureRender: Sendable {
    let id: String
    let name: String
    let pairs: [(Int, Int)]
    let starIndices: [Int]
    /// ICRS mean direction of the figure's stars (label anchor).
    let centroid: SIMD3<Double>?
}

struct StarStyle: Sendable {
    var tint: SIMD3<Float>
    var vmag: Float
}

/// Everything loaded once from the bundle (stars, figures, names, deep-sky, Milky Way, artwork, Roman lookup, narration).
struct SkyData: Sendable {
    static let milkyWaySize = (width: 1024, height: 512)

    let catalog: StarCatalog
    let styles: [StarStyle]
    let hipIndex: [Int: Int]
    let directions: [SIMD3<Double>]
    let figures: [FigureRender]
    let figureByID: [String: ConstellationFigure]
    /// Catalog indices of every star in any figure, and of the stars brighter than magnitude 2 (tap-to-align).
    let figureStarIndices: [Int]
    let brightStarIndices: [Int]
    let constellationNames: [String: String]
    let names: StarNames
    let namesByHip: [Int: String]
    let starLabels: [StarLabel]
    let asterisms: [(asterism: Asterism, polylines: [[SIMD3<Double>]])]
    let deepSky: DeepSkyCatalog
    let milkyWayLevels: [UInt8]
    let artwork: [String: ArtworkInfo]
    let placements: [String: ArtworkPlacement]
    let roman: RomanLookup
    let membership: ConstellationMembership
    let scorer: ConstellationScorer
    let schedules: [String: DrawInSchedule]
    let narration: NarrationFile?

    enum LoadError: Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self { case .missing(let name): "\(name) is not in the app bundle" }
        }
    }

    static func load(bundle: Bundle = .main) throws -> SkyData {
        func url(_ name: String, _ ext: String) throws -> URL {
            guard let url = bundle.url(forResource: name, withExtension: ext) else { throw LoadError.missing("\(name).\(ext)") }
            return url
        }
        let catalog = try StarCatalog(url: url("stars", "bin"))
        let lines = try ConstellationLines(url: url("lines", "json"))
        let names = try StarNames(url: url("names", "json"))
        let list = try ConstellationList.load(url: url("constellations", "json"))
        let constellationNames = Dictionary(list.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let roman = try RomanLookup(url: url("roman1875", "json"))
        let milkyWay = try MilkyWay(url: url("milkyway", "json"))
        let deepSky = try DeepSkyCatalog(url: url("dso", "json"))
        let asterisms = try AsterismCatalog(url: url("asterisms", "json"))
        let artworkInfos = try ArtworkInfo.load(url: url("artwork", "json"))

        var hipIndex: [Int: Int] = [:]
        hipIndex.reserveCapacity(catalog.stars.count)
        for (i, star) in catalog.stars.enumerated() where hipIndex[star.hip] == nil { hipIndex[star.hip] = i }
        let styles = catalog.stars.map { StarStyle(tint: StarAppearance.tint(bv: $0.bv, saturation: 0.7), vmag: $0.vmag) }
        let directions = catalog.stars.map(\.directionDouble)

        let figures = lines.constellations.map { figure -> FigureRender in
            let pairs = figure.pairs.compactMap { pair -> (Int, Int)? in
                guard let a = hipIndex[pair.0], let b = hipIndex[pair.1] else { return nil }
                return (a, b)
            }
            return FigureRender(id: figure.id, name: constellationNames[figure.id] ?? figure.name, pairs: pairs,
                                starIndices: Array(Set(pairs.flatMap { [$0.0, $0.1] })),
                                centroid: SkyLabels.figureCentroid(figure, catalog: catalog))
        }

        var placements: [String: ArtworkPlacement] = [:]
        for info in artworkInfos {
            if let placement = try? ArtworkPlacement(info: info, catalog: catalog) { placements[info.id] = placement }
        }

        return SkyData(
            catalog: catalog, styles: styles, hipIndex: hipIndex, directions: directions, figures: figures,
            figureByID: Dictionary(lines.constellations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            figureStarIndices: Array(Set(figures.flatMap(\.starIndices))).sorted(),
            brightStarIndices: catalog.stars.indices.filter { catalog.stars[$0].vmag < 2 },
            constellationNames: constellationNames, names: names, namesByHip: names.byHip.mapValues(\.name),
            starLabels: SkyLabels.starLabels(names: names, catalog: catalog, limit: 50),
            asterisms: asterisms.asterisms.map { ($0, $0.polylines) },
            deepSky: deepSky,
            milkyWayLevels: blurredMilkyWay(milkyWay),
            artwork: Dictionary(artworkInfos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            placements: placements, roman: roman,
            membership: ConstellationMembership(catalog: catalog, roman: roman),
            scorer: ConstellationScorer(lines: lines, catalog: catalog),
            schedules: DrawInSchedule.all(lines: lines, catalog: catalog),
            narration: NarrationFile.load(bundle: bundle))
    }

    /// Level map scaled to 0…255 over the highest level, softened so the texture's bilinear edges are smooth.
    private static func blurredMilkyWay(_ milkyWay: MilkyWay) -> [UInt8] {
        let (w, h) = (milkyWaySize.width, milkyWaySize.height)
        let top = Float(max(milkyWay.levels.map(\.level).max() ?? 1, 1))
        var values = milkyWay.rasterize(width: w, height: h).map { Float($0) / top }
        var scratch = values
        let radius = 4, window = Float(2 * radius + 1)
        for _ in 0..<2 {
            // Horizontal (wraps in RA) then vertical (clamped at the poles) box blur with running sums.
            for y in 0..<h {
                let row = y * w
                var sum: Float = 0
                for dx in -radius...radius { sum += values[row + (dx + w) % w] }
                for x in 0..<w {
                    scratch[row + x] = sum / window
                    sum += values[row + (x + radius + 1) % w] - values[row + (x - radius + w) % w]
                }
            }
            for x in 0..<w {
                var sum: Float = 0
                for dy in -radius...radius { sum += scratch[min(max(dy, 0), h - 1) * w + x] }
                for y in 0..<h {
                    values[y * w + x] = sum / window
                    sum += scratch[min(y + radius + 1, h - 1) * w + x] - scratch[max(y - radius, 0) * w + x]
                }
            }
        }
        return values.map { UInt8(min(max($0, 0), 1) * 255) }
    }

    func displayName(hip: Int) -> String? { namesByHip[hip] }

    func name(ofConstellation id: String) -> String { constellationNames[id] ?? id }

    /// Distance in light years from the catalog parallax, nil if unknown.
    func distanceLightYears(starIndex i: Int) -> Double? {
        let parallax = Double(catalog.stars[i].parallaxMas)
        return parallax.isFinite && parallax > 0.5 ? 3261.56 / parallax : nil
    }
}
