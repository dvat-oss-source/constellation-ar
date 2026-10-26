import Foundation
import OSLog
import SkyCore

private let focusResourcesLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ConstellationAR", category: "FocusResources")
private nonisolated(unsafe) var didLogPassageBundleLoad = false

/// Bundled focus data (boundaries, atlas, passages) loaded alongside sky catalogs.
@MainActor
final class FocusResources {
    private(set) var hitTest: ConstellationHitTest?
    private(set) var boundaryGeometry: BoundaryGeometry?
    private(set) var atlas: ConstellationAtlas?
    private(set) var bm25: BM25Index?
    private(set) var verifier: AnswerVerifier?
    private(set) var artworkOutlines: ArtworkOutlines?
    private(set) var loadError: String?
    private var skyOutlineCache: [String: SkyOutline] = [:]

    func load(from bundle: Bundle = .main) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try Self.loadSync(bundle: bundle) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let loaded):
                    self.hitTest = loaded.hitTest
                    self.boundaryGeometry = loaded.boundaryGeometry
                    self.atlas = loaded.atlas
                    self.bm25 = loaded.bm25
                    self.verifier = loaded.verifier
                    self.artworkOutlines = loaded.artworkOutlines
                    self.skyOutlineCache = [:]
                case .failure(let error):
                    self.loadError = "Focus data: \(error.localizedDescription)"
                }
            }
        }
    }

    private struct Loaded: Sendable {
        var hitTest: ConstellationHitTest
        var boundaryGeometry: BoundaryGeometry
        var atlas: ConstellationAtlas
        var bm25: BM25Index?
        var verifier: AnswerVerifier?
        var artworkOutlines: ArtworkOutlines?
    }

    func skyOutline(for id: String, artwork: [String: ArtworkInfo], catalog: StarCatalog) -> SkyOutline? {
        if let cached = skyOutlineCache[id] { return cached }
        guard let artworkOutlines, artworkOutlines.hasOutline(for: id), let info = artwork[id] else { return nil }
        guard let sky = try? artworkOutlines.skyOutline(for: id, artwork: [info], catalog: catalog) else { return nil }
        skyOutlineCache[id] = sky
        return sky
    }

    nonisolated private static func loadSync(bundle: Bundle) throws -> Loaded {
        func url(_ name: String, _ ext: String) throws -> URL {
            guard let url = bundle.url(forResource: name, withExtension: ext) else {
                throw FocusLoadError.missing("\(name).\(ext)")
            }
            return url
        }
        let lines = try ConstellationLines(url: url("lines", "json"))
        let catalog = try StarCatalog(url: url("stars", "bin"))
        let boundaries = try ConstellationBoundaries(url: url("boundaries", "json"))
        let hitTest = ConstellationHitTest(boundaries: boundaries, figures: lines.constellations, catalog: catalog)
        let geometry = BoundaryGeometry(boundaries: boundaries)
        let atlas = try ConstellationAtlas(dataDirectory: bundle.resourceURL ?? bundle.bundleURL)
        var bm25: BM25Index?
        var verifier: AnswerVerifier?
        if let passagesURL = bundle.url(forResource: "passages", withExtension: "json") {
            let library = try PassageLibrary(url: passagesURL)
            if !didLogPassageBundleLoad {
                didLogPassageBundleLoad = true
                focusResourcesLog.info("passages.json loaded from bundle (\(library.passages.count) passages)")
                assert(!library.passages.isEmpty, "passages.json must not be empty")
            }
            bm25 = BM25Index(passages: library.passages)
            let list = try ConstellationList.load(url: url("constellations", "json"))
            let names = try StarNames(url: url("names", "json"))
            let designations = try StarDesignations(url: url("designations", "json"))
            verifier = AnswerVerifier(library: library, stars: StarFactIndex(catalog: catalog, names: names,
                                                                             designations: designations, constellations: list))
        }
        let artworkOutlines = try ArtworkOutlines(url: url("artwork_outlines", "json"))
        return Loaded(hitTest: hitTest, boundaryGeometry: geometry, atlas: atlas, bm25: bm25, verifier: verifier,
                      artworkOutlines: artworkOutlines)
    }
}

enum FocusLoadError: Error, CustomStringConvertible {
    case missing(String)
    var description: String {
        switch self { case .missing(let name): "\(name) is not in the app bundle" }
    }
}
