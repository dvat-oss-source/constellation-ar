import Foundation
import simd

/// A crop of the camera frame's luminance. `origin` is the crop's upper-left corner in buffer pixels.
public struct LuminanceWindow: Sendable {
    public var width: Int
    public var height: Int
    public var origin: SIMD2<Double>
    public var pixels: [UInt8]

    public init(width: Int, height: Int, origin: SIMD2<Double>, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.origin = origin
        self.pixels = pixels
    }
}

/// Moves a tap onto the image of the star or Moon under it. Positions are buffer pixels, corner-origin like `CameraIntrinsics`.
public enum TapSnap {
    /// Brightest star centroid within `radius` of `tap`.
    public static func star(in window: LuminanceWindow, near tap: SIMD2<Double>, radius: Double) -> SIMD2<Double>? {
        let found = StarDetector.detect(luminance: window.pixels, width: window.width, height: window.height,
                                        rowBytes: window.width, maxStars: 12)
        let local = tap - window.origin
        return found.filter { simd_distance($0.position, local) <= radius }
            .max { $0.flux < $1.flux }
            .map { $0.position + window.origin }
    }

    /// Centre of the Moon's disc, whose lit part may be a crescent: the bright region's outline is matched with a circle
    /// of the known radius (Hough vote), so the dark side does not pull the centre toward the lit limb.
    public static func moon(in window: LuminanceWindow, near tap: SIMD2<Double>, radius: Double) -> SIMD2<Double>? {
        let w = window.width, h = window.height
        guard w >= 8, h >= 8, radius >= 1.5, window.pixels.count >= w * h else { return nil }
        let image = window.pixels.map(Float.init)
        let sorted = image.sorted()
        let background = sorted[sorted.count / 2]
        var peak: Float = 0, peakIndex = 0
        let local = tap - window.origin
        for y in 1..<h - 1 {
            for x in 1..<w - 1 where simd_distance(SIMD2(Double(x), Double(y)), local) <= radius * 3 {
                var sum: Float = 0
                for dy in -1...1 { for dx in -1...1 { sum += image[(y + dy) * w + x + dx] } }
                if sum / 9 > peak { peak = sum / 9; peakIndex = y * w + x }
            }
        }
        guard peak - background > 25 else { return nil }
        let threshold = background + 0.5 * (peak - background)

        var inside = [Bool](repeating: false, count: w * h)
        var stack = [peakIndex], region: [Int] = []
        inside[peakIndex] = true
        while let i = stack.popLast() {
            region.append(i)
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                let j = ny * w + nx
                if !inside[j], image[j] >= threshold { inside[j] = true; stack.append(j) }
            }
        }
        guard region.count >= 6 else { return nil }
        var centroid = SIMD2<Double>.zero
        var boundary: [SIMD2<Double>] = []
        for i in region {
            let x = i % w, y = i / w
            centroid += SIMD2(Double(x) + 0.5, Double(y) + 0.5)
            let edge = x == 0 || y == 0 || x == w - 1 || y == h - 1
                || !inside[i - 1] || !inside[i + 1] || !inside[i - w] || !inside[i + w]
            if edge { boundary.append(SIMD2(Double(x) + 0.5, Double(y) + 0.5)) }
        }
        centroid /= Double(region.count)
        let area = Double(region.count)
        // A (nearly) full disc is its own centroid; a crescent or gibbous Moon needs the limb fit.
        if area >= 0.85 * .pi * radius * radius || boundary.count < 8 { return centroid + window.origin }

        let step = max(radius / 24, 0.1)
        var best = (score: -1.0, centre: centroid)
        var dx = -radius
        while dx <= radius {
            var dy = -radius
            while dy <= radius {
                let c = centroid + SIMD2(dx, dy)
                var score = 0.0
                for p in boundary {
                    let e = (simd_distance(p, c) - (radius - 0.5)) / 0.8
                    score += exp(-e * e)
                }
                if score > best.score { best = (score, c) }
                dy += step
            }
            dx += step
        }
        return best.centre + window.origin
    }
}
