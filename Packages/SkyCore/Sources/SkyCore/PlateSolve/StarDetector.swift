import Foundation
import simd

/// Rectangle in sensor pixels (origin at the buffer's upper-left corner, +y down).
public struct PixelRegion: Sendable, Hashable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    public static func around(_ center: SIMD2<Double>, radius: Double) -> PixelRegion {
        PixelRegion(minX: center.x - radius, minY: center.y - radius, maxX: center.x + radius, maxY: center.y + radius)
    }
}

public struct DetectedStar: Sendable, Hashable {
    /// Sub-pixel centroid in the corner-origin convention of `CameraIntrinsics` (the centre of pixel (0, 0) is (0.5, 0.5)).
    public var x: Double
    public var y: Double
    /// Background-subtracted counts inside a 3.5 px radius.
    public var flux: Double
    /// Brightest background-subtracted pixel near the centroid.
    public var peak: Double
    /// Smoothed peak excess over the local noise level.
    public var snr: Double

    public var position: SIMD2<Double> { SIMD2(x, y) }
}

public struct StarDetectorOptions: Sendable {
    /// Detection threshold in units of the local noise of the smoothed image.
    public var sigma = 5.5
    /// Smallest smoothed peak excess, in gray levels, that can count as a star in a noiseless image.
    public var minimumExcess = 2.5
    public var cellSize = 32
    public var border = 3.0
    public init() {}
}

/// Point-source detector: hot-pixel suppression, Gaussian smoothing, per-cell background and noise from robust
/// quantiles, local maxima above threshold, iterated Gaussian-weighted sub-pixel centroids.
public enum StarDetector {
    private static let kernel: [Float] = [0.054, 0.244, 0.403, 0.244, 0.054]
    private static let pad = 6

    public static func detect(luminance: [UInt8], width: Int, height: Int, rowBytes: Int, maxStars: Int = 60,
                              region: PixelRegion? = nil, options: StarDetectorOptions = .init()) -> [DetectedStar] {
        luminance.withUnsafeBufferPointer {
            detect(luminance: $0, width: width, height: height, rowBytes: rowBytes, maxStars: maxStars,
                   region: region, options: options)
        }
    }

    /// Stars sorted brightest first (by flux). Hot pixels, single-pixel spikes and extended blobs are rejected.
    @_optimize(speed)
    public static func detect(luminance: UnsafeBufferPointer<UInt8>, width: Int, height: Int, rowBytes: Int,
                              maxStars: Int = 60, region: PixelRegion? = nil,
                              options: StarDetectorOptions = .init()) -> [DetectedStar] {
        guard width > 16, height > 16, rowBytes >= width, maxStars > 0,
              luminance.count >= rowBytes * (height - 1) + width else { return [] }
        var x0 = 0, y0 = 0, x1 = width, y1 = height
        if let r = region {
            x0 = max(0, Int(r.minX.rounded(.down)) - pad); y0 = max(0, Int(r.minY.rounded(.down)) - pad)
            x1 = min(width, Int(r.maxX.rounded(.up)) + pad); y1 = min(height, Int(r.maxY.rounded(.up)) + pad)
        }
        let w = x1 - x0, h = y1 - y0
        guard w > 16, h > 16 else { return [] }

        var image = [Float](repeating: 0, count: w * h)
        image.withUnsafeMutableBufferPointer { dst in
            for row in 0..<h {
                let src = luminance.baseAddress! + (y0 + row) * rowBytes + x0, out = dst.baseAddress! + row * w
                for col in 0..<w { out[col] = Float(src[col]) }
            }
        }
        removeHotPixels(&image, w: w, h: h)
        let smooth = smoothed(image, w: w, h: h)
        let grid = BackgroundGrid(smooth, w: w, h: h, cell: options.cellSize)
        let candidates = peaks(smooth, w: w, h: h, grid: grid, options: options)

        var stars: [DetectedStar] = []
        for c in candidates {
            guard let star = centroid(image, w: w, h: h, peakX: c.x, peakY: c.y, grid: grid, excess: c.excess,
                                      noise: c.noise) else { continue }
            let full = DetectedStar(x: star.x + Double(x0), y: star.y + Double(y0), flux: star.flux, peak: star.peak, snr: star.snr)
            guard full.x >= options.border, full.y >= options.border,
                  full.x <= Double(width) - options.border, full.y <= Double(height) - options.border else { continue }
            if let r = region, full.x < r.minX || full.x > r.maxX || full.y < r.minY || full.y > r.maxY { continue }
            stars.append(full)
        }
        stars.sort { $0.flux > $1.flux }
        var kept: [DetectedStar] = []
        for s in stars where !kept.contains(where: { simd_distance_squared($0.position, s.position) < 9 }) {
            kept.append(s)
            if kept.count == maxStars { break }
        }
        return kept
    }

    // MARK: Stages

    /// Replaces isolated spikes (bright pixel whose neighbours are all near the local level) by the neighbour median.
    @_optimize(speed)
    private static func removeHotPixels(_ image: inout [Float], w: Int, h: Int) {
        var sample: [Float] = []
        sample.reserveCapacity(w * h / 9 + 1)
        image.withUnsafeBufferPointer { p in
            for row in stride(from: 0, to: h, by: 3) {
                for col in stride(from: 0, to: w, by: 3) { sample.append(p[row * w + col]) }
            }
        }
        sample.sort()
        let median = sample[sample.count / 2]
        let sigma = max((sample[sample.count * 3 / 4] - sample[sample.count / 4]) / 1.349, 0.5)
        let cut = median + 6 * sigma
        var spikes: [Int] = []
        image.withUnsafeBufferPointer { p in
            for row in 1..<(h - 1) {
                let r = p.baseAddress! + row * w
                for col in 1..<(w - 1) where r[col] > cut { spikes.append(row * w + col) }
            }
        }
        for i in spikes {
            let v = image[i]
            let sorted = [image[i - w - 1], image[i - w], image[i - w + 1], image[i - 1],
                          image[i + 1], image[i + w - 1], image[i + w], image[i + w + 1]].sorted()
            let local = (sorted[3] + sorted[4]) / 2
            if v - local > 6 * sigma, sorted[7] - local < 0.2 * (v - local) { image[i] = local }
        }
    }

    @_optimize(speed)
    private static func smoothed(_ image: [Float], w: Int, h: Int) -> [Float] {
        let k0 = kernel[0], k1 = kernel[1], k2 = kernel[2]
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        image.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { dst in
                for row in 0..<h {
                    let s = src.baseAddress! + row * w, d = dst.baseAddress! + row * w
                    for col in 0..<w {
                        let l1 = s[max(col - 1, 0)], l2 = s[max(col - 2, 0)], r1 = s[min(col + 1, w - 1)], r2 = s[min(col + 2, w - 1)]
                        d[col] = k0 * (l2 + r2) + k1 * (l1 + r1) + k2 * s[col]
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<h {
                    let a = src.baseAddress! + max(row - 2, 0) * w, b = src.baseAddress! + max(row - 1, 0) * w
                    let c = src.baseAddress! + row * w
                    let d = src.baseAddress! + min(row + 1, h - 1) * w, e = src.baseAddress! + min(row + 2, h - 1) * w
                    let o = dst.baseAddress! + row * w
                    for col in 0..<w { o[col] = k0 * (a[col] + e[col]) + k1 * (b[col] + d[col]) + k2 * c[col] }
                }
            }
        }
        return out
    }

    /// Per-cell median and IQR-based sigma of the smoothed image, interpolated bilinearly between cell centres.
    private struct BackgroundGrid {
        let cell: Int, nx: Int, ny: Int
        var background: [Float], sigma: [Float]

        @_optimize(speed)
        init(_ smooth: [Float], w: Int, h: Int, cell: Int) {
            self.cell = cell
            nx = (w + cell - 1) / cell
            ny = (h + cell - 1) / cell
            background = [Float](repeating: 0, count: nx * ny)
            sigma = [Float](repeating: 0, count: nx * ny)
            var values: [Float] = []
            for cy in 0..<ny {
                for cx in 0..<nx {
                    values.removeAll(keepingCapacity: true)
                    smooth.withUnsafeBufferPointer { p in
                        for row in stride(from: cy * cell, to: min(h, (cy + 1) * cell), by: 2) {
                            for col in stride(from: cx * cell, to: min(w, (cx + 1) * cell), by: 2) { values.append(p[row * w + col]) }
                        }
                    }
                    values.sort()
                    let n = values.count
                    background[cy * nx + cx] = values[n / 2]
                    sigma[cy * nx + cx] = max((values[n * 3 / 4] - values[n / 4]) / 1.349, 0.08)
                }
            }
        }

        func sample(_ field: [Float], x: Double, y: Double) -> Float {
            let gx = min(max(x / Double(cell) - 0.5, 0), Double(nx - 1)), gy = min(max(y / Double(cell) - 0.5, 0), Double(ny - 1))
            let ix = min(Int(gx), max(nx - 2, 0)), iy = min(Int(gy), max(ny - 2, 0))
            let fx = Float(gx - Double(ix)), fy = Float(gy - Double(iy))
            let ix1 = min(ix + 1, nx - 1), iy1 = min(iy + 1, ny - 1)
            let top = field[iy * nx + ix] * (1 - fx) + field[iy * nx + ix1] * fx
            let bottom = field[iy1 * nx + ix] * (1 - fx) + field[iy1 * nx + ix1] * fx
            return top * (1 - fy) + bottom * fy
        }

        func background(x: Double, y: Double) -> Float { sample(background, x: x, y: y) }
        func noise(x: Double, y: Double) -> Float { sample(sigma, x: x, y: y) }
    }

    private struct Candidate { var x: Int, y: Int, excess: Float, noise: Float }

    @_optimize(speed)
    private static func peaks(_ s: [Float], w: Int, h: Int, grid: BackgroundGrid, options: StarDetectorOptions) -> [Candidate] {
        // A pixel can only be a detection if it beats the lowest threshold of its cell and the neighbouring cells,
        // since the threshold is interpolated between cell centres.
        let cell = grid.cell
        var cellFloor = [Float](repeating: 0, count: grid.nx * grid.ny)
        for cy in 0..<grid.ny {
            for cx in 0..<grid.nx {
                var low = Float.infinity
                for ny in max(cy - 1, 0)...min(cy + 1, grid.ny - 1) {
                    for nx in max(cx - 1, 0)...min(cx + 1, grid.nx - 1) {
                        let i = ny * grid.nx + nx
                        low = min(low, grid.background[i] + max(Float(options.sigma) * grid.sigma[i], Float(options.minimumExcess)))
                    }
                }
                cellFloor[cy * grid.nx + cx] = low
            }
        }
        var above: [Int] = []
        s.withUnsafeBufferPointer { p in
            for row in 5..<(h - 5) {
                let r = p.baseAddress! + row * w
                for cx in 0..<grid.nx {
                    let threshold = cellFloor[(row / cell) * grid.nx + cx]
                    let lo = max(cx * cell, 5), hi = min((cx + 1) * cell, w - 5)
                    guard lo < hi else { continue }
                    for col in lo..<hi where r[col] > threshold { above.append(row * w + col) }
                }
            }
        }
        var found: [Candidate] = []
        let ringOffsets: [(Int, Int)] = [(4, 0), (-4, 0), (0, 4), (0, -4), (3, 3), (-3, 3), (3, -3), (-3, -3)]
        for i in above {
            let row = i / w, col = i % w
            let v = s[i]
            guard v > s[i - 1], v > s[i - w], v > s[i - w - 1], v > s[i - w + 1],
                  v >= s[i + 1], v >= s[i + w], v >= s[i + w - 1], v >= s[i + w + 1] else { continue }
            let bg = grid.background(x: Double(col), y: Double(row))
            let noise = grid.noise(x: Double(col), y: Double(row))
            let excess = v - bg
            guard excess >= max(Float(options.sigma) * noise, Float(options.minimumExcess)) else { continue }
            var ring: Float = 0
            for (dx, dy) in ringOffsets { ring += s[i + dy * w + dx] - bg }
            if ring / 8 > 0.35 * excess { continue }
            found.append(Candidate(x: col, y: row, excess: excess, noise: noise))
        }
        if found.count > 1500 {
            found.sort { $0.excess / $0.noise > $1.excess / $1.noise }
            found.removeLast(found.count - 1500)
        }
        return found
    }

    @_optimize(speed)
    private static func centroid(_ image: [Float], w: Int, h: Int, peakX: Int, peakY: Int, grid: BackgroundGrid,
                                 excess: Float, noise: Float) -> DetectedStar? {
        let bg = Double(grid.background(x: Double(peakX), y: Double(peakY)))
        let half = 4
        let sigmaWeight = 1.5
        var cx = Double(peakX) + 0.5, cy = Double(peakY) + 0.5
        for _ in 0..<6 {
            var sum = 0.0, sx = 0.0, sy = 0.0
            let ix = Int(cx), iy = Int(cy)
            for row in max(iy - half, 0)...min(iy + half, h - 1) {
                for col in max(ix - half, 0)...min(ix + half, w - 1) {
                    let dx = Double(col) + 0.5 - cx, dy = Double(row) + 0.5 - cy
                    let weight = exp(-(dx * dx + dy * dy) / (2 * sigmaWeight * sigmaWeight))
                    let value = weight * (Double(image[row * w + col]) - bg)
                    sum += value; sx += value * (Double(col) + 0.5); sy += value * (Double(row) + 0.5)
                }
            }
            guard sum > 0 else { return nil }
            let nx = sx / sum, ny = sy / sum
            let moved = hypot(nx - cx, ny - cy)
            cx = nx; cy = ny
            if moved < 0.005 { break }
        }
        guard hypot(cx - Double(peakX) - 0.5, cy - Double(peakY) - 0.5) < 2.5 else { return nil }
        var flux = 0.0, peak = -Double.infinity
        let ix = Int(cx), iy = Int(cy)
        for row in max(iy - 4, 0)...min(iy + 4, h - 1) {
            for col in max(ix - 4, 0)...min(ix + 4, w - 1) {
                let dx = Double(col) + 0.5 - cx, dy = Double(row) + 0.5 - cy
                let d2 = dx * dx + dy * dy
                let value = Double(image[row * w + col]) - bg
                if d2 <= 12.25 { flux += value }
                if d2 <= 2.25 { peak = max(peak, value) }
            }
        }
        guard flux > 0, peak > 0 else { return nil }
        return DetectedStar(x: cx, y: cy, flux: flux, peak: peak, snr: Double(excess / noise))
    }
}
