import Foundation
import SkyCore

/// Bundled focus data (boundaries, atlas, passages) loaded alongside sky catalogs.
@MainActor
final class FocusResources {
    private(set) var hitTest: ConstellationHitTest?
    private(set) var boundaryGeometry: BoundaryGeometry?
    private(set) var atlas: ConstellationAtlas?
    private(set) var bm25: BM25Index?
    private(set) var verifier: AnswerVerifier?
    private(set) var loadError: String?

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
            bm25 = BM25Index(passages: library.passages)
            let list = try ConstellationList.load(url: url("constellations", "json"))
            let names = try StarNames(url: url("names", "json"))
            let designations = try StarDesignations(url: url("designations", "json"))
            verifier = AnswerVerifier(library: library, stars: StarFactIndex(catalog: catalog, names: names,
                                                                             designations: designations, constellations: list))
        }
        return Loaded(hitTest: hitTest, boundaryGeometry: geometry, atlas: atlas, bm25: bm25, verifier: verifier)
    }
}

enum FocusLoadError: Error, CustomStringConvertible {
    case missing(String)
    var description: String {
        switch self { case .missing(let name): "\(name) is not in the app bundle" }
    }
}
