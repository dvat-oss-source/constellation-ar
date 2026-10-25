import Foundation
import simd
@testable import SkyCore

func plateGaussian<G: RandomNumberGenerator>(_ g: inout G) -> Double {
    let u = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &g), v = Double.random(in: 0..<1, using: &g)
    return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
}

func plateRandomRotation<G: RandomNumberGenerator>(_ g: inout G) -> simd_double3x3 {
    let q = simd_quatd(ix: plateGaussian(&g), iy: plateGaussian(&g), iz: plateGaussian(&g), r: plateGaussian(&g)).normalized
    return simd_double3x3(q)
}

struct SyntheticStar {
    var pixel: SIMD2<Double>
    var magnitude: Double
}

/// 8-bit luminance frame rendered from star pixels: Gaussian PSF, sky pedestal with a vignette-like gradient, read noise,
/// optional hot pixels and uncatalogued blobs.
struct SyntheticFrame {
    var width: Int
    var height: Int
    var psfSigma = 1.3
    var noiseSigma = 3.0
    var pedestal = 8.0
    var hotPixels = 0
    var falseBlobs = 0
    /// Flux of a magnitude-0 star in counts; a mag 4.5 star then peaks near 30 counts.
    var zeroMagnitudeFlux = 20_000.0

    func render(_ stars: [SyntheticStar], seed: UInt64) -> [UInt8] {
        var g = SplitMixRNG(seed: seed)
        var field = [Float](repeating: 0, count: width * height)
        func add(_ p: SIMD2<Double>, flux: Double) {
            let amp = flux / (2 * .pi * psfSigma * psfSigma)
            let r = Int((psfSigma * 4.5).rounded(.up))
            let cx = Int(p.x), cy = Int(p.y)
            for y in max(cy - r, 0)...min(cy + r, height - 1) {
                for x in max(cx - r, 0)...min(cx + r, width - 1) {
                    let dx = Double(x) + 0.5 - p.x, dy = Double(y) + 0.5 - p.y
                    field[y * width + x] += Float(amp * exp(-(dx * dx + dy * dy) / (2 * psfSigma * psfSigma)))
                }
            }
        }
        for s in stars where s.pixel.x >= 0 && s.pixel.y >= 0 && s.pixel.x < Double(width) && s.pixel.y < Double(height) {
            add(s.pixel, flux: zeroMagnitudeFlux * pow(10, -0.4 * s.magnitude))
        }
        for _ in 0..<falseBlobs {
            add(SIMD2(Double.random(in: 10..<Double(width - 10), using: &g), Double.random(in: 10..<Double(height - 10), using: &g)),
                flux: Double.random(in: 150...600, using: &g))
        }
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = (Double(x) / Double(width) - 0.5), dy = (Double(y) / Double(height) - 0.5)
                let sky = pedestal + 6 * (dx * dx + dy * dy)
                let v = sky + Double(field[y * width + x]) + noiseSigma * plateGaussian(&g)
                out[y * width + x] = UInt8(min(max(v.rounded(), 0), 255))
            }
        }
        for _ in 0..<hotPixels {
            out[Int.random(in: 0..<out.count, using: &g)] = UInt8.random(in: 120...255, using: &g)
        }
        return out
    }
}

enum SolverFixtures {
    static let database: SolverDatabase = {
        do { return try SolverDatabase(url: RepoFiles.url("Data/solver_db.bin")) } catch { fatalError("solver_db.bin: \(error)") }
    }()

    static let catalog: StarCatalog = {
        do { return try StarCatalog(url: RepoFiles.url("Data/stars.bin")) } catch { fatalError("stars.bin: \(error)") }
    }()

    static func intrinsics(horizontalDegrees: Double, width: Int, height: Int) -> CameraIntrinsics {
        .fieldOfView(horizontalDegrees: horizontalDegrees, bufferWidth: Double(width), bufferHeight: Double(height))
    }

    /// Catalogue stars (to `magnitudeLimit`) projected through `enuToCamera` applied to `direction(star)`.
    static func project(_ projector: Projector, magnitudeLimit: Double, direction: (CatalogStar) -> SIMD3<Double>) -> [SyntheticStar] {
        var out: [SyntheticStar] = []
        for s in catalog.stars where Double(s.vmag) <= magnitudeLimit {
            if let p = projector.pixel(enu: direction(s)) {
                out.append(SyntheticStar(pixel: p, magnitude: Double(s.vmag)))
            }
        }
        return out
    }
}
