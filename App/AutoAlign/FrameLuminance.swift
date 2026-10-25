import CoreVideo

/// Row-major 8-bit luminance, no row padding.
struct LuminanceImage: Sendable {
    var pixels: [UInt8]
    var width: Int
    var height: Int
}

extension LuminanceImage {
    /// Y ≈ (B + 2G + R) / 4 from BGRA rows `rowBytes` apart.
    init(bgra: UnsafeRawBufferPointer, width: Int, height: Int, rowBytes: Int) {
        let pixels = [UInt8](unsafeUninitializedCapacity: width * height) { out, count in
            for row in 0..<height {
                let src = bgra.baseAddress!.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
                for col in 0..<width {
                    out[row * width + col] = UInt8((UInt16(src[col * 4]) + 2 * UInt16(src[col * 4 + 1]) + UInt16(src[col * 4 + 2])) >> 2)
                }
            }
            count = width * height
        }
        self.init(pixels: pixels, width: width, height: height)
    }
}

extension CameraFrame {
    /// CPU luminance of the frame, read from its pixel buffer.
    nonisolated func luminance() -> LuminanceImage? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        return LuminanceImage(bgra: UnsafeRawBufferPointer(start: base, count: rowBytes * height),
                              width: width, height: height, rowBytes: rowBytes)
    }
}
