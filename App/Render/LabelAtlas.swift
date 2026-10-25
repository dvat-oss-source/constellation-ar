import CoreGraphics
import CoreText
import Metal
import UIKit

/// Text for the Metal overlay: each (string, pixel size, weight) is rasterised once with CoreText into a shared
/// RGBA texture (premultiplied white fill with a dark outline) and then drawn as a textured quad.
@MainActor
final class LabelAtlas {
    struct Entry {
        /// u0, v0, u1, v1 over the whole atlas.
        var uv: SIMD4<Float>
        /// Pixels, outline padding included.
        var size: SIMD2<Float>
    }

    static let side = 2048
    private static let padding = 3

    let texture: any MTLTexture
    private var entries: [String: Entry] = [:]
    private var cursor = SIMD2<Int>(0, 0)
    private var rowHeight = 0

    init?(device: any MTLDevice) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Self.side, height: Self.side, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
    }

    var cachedCount: Int { entries.count }

    /// Nil only when the atlas is full.
    func entry(text: String, pixelSize: Int, bold: Bool) -> Entry? {
        let key = "\(bold ? "b" : "r")\(pixelSize)|\(text)"
        if let cached = entries[key] { return cached }
        guard let entry = rasterize(text: text, pixelSize: pixelSize, bold: bold) else { return nil }
        entries[key] = entry
        return entry
    }

    private func rasterize(text: String, pixelSize: Int, bold: Bool) -> Entry? {
        let font = UIFont.systemFont(ofSize: CGFloat(pixelSize), weight: bold ? .semibold : .medium)
        func line(fill: Bool) -> CTLine {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if fill {
                attributes[.foregroundColor] = UIColor.white
            } else {
                attributes[.foregroundColor] = UIColor.black
                attributes[.strokeColor] = UIColor.black.withAlphaComponent(0.85)
                attributes[.strokeWidth] = 22
            }
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        let fill = line(fill: true), outline = line(fill: false)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CTLineGetTypographicBounds(fill, &ascent, &descent, &leading)
        let pad = Self.padding
        let width = Int(ceil(textWidth)) + 2 * pad
        let height = Int(ceil(ascent + descent)) + 2 * pad
        guard width > 2 * pad, width <= Self.side, height <= Self.side else { return nil }

        if cursor.x + width > Self.side {
            cursor = SIMD2(0, cursor.y + rowHeight)
            rowHeight = 0
        }
        guard cursor.y + height <= Self.side else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.textPosition = CGPoint(x: CGFloat(pad), y: CGFloat(pad) + descent)
            CTLineDraw(outline, context)
            context.textPosition = CGPoint(x: CGFloat(pad), y: CGFloat(pad) + descent)
            CTLineDraw(fill, context)
            return true
        }
        guard drawn else { return nil }
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(cursor.x, cursor.y, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        let side = Float(Self.side)
        let entry = Entry(uv: SIMD4(Float(cursor.x) / side, Float(cursor.y) / side,
                                    Float(cursor.x + width) / side, Float(cursor.y + height) / side),
                          size: SIMD2(Float(width), Float(height)))
        cursor.x += width
        rowHeight = max(rowHeight, height)
        return entry
    }
}
