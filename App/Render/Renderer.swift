import Foundation
import Metal
import QuartzCore
import simd

enum RenderBackground {
    case camera(CameraFrame)
    case sky(lighting: Double)
}

/// Draws the camera image (or a sky gradient) and the overlay batches into one drawable, in one command buffer.
@MainActor
final class Renderer {
    enum SetupError: Error, CustomStringConvertible {
        case missingShaderSource
        case noCommandQueue
        case missingFunction(String)

        var description: String {
            switch self {
            case .missingShaderSource: "Shaders.metal is not in the app bundle"
            case .noCommandQueue: "could not create a Metal command queue"
            case .missingFunction(let name): "shader function \(name) not found"
            }
        }
    }

    private struct FrameUniforms {
        var viewport: SIMD2<Float>
        var redTheme: Float
        var padding: Float = 0
        var sensorFromScreen: simd_float3x3
        var sensorSize: SIMD2<Float>
        var padding2: SIMD2<Float> = .zero
    }

    private struct SkyUniforms {
        var referenceFromScreen: simd_float3x3
        var lighting: Float
        var padding: SIMD3<Float> = .zero
    }

    static let maxFramesInFlight = 3
    private static let batchAlignment = 256

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let cameraPipeline: any MTLRenderPipelineState
    private let skyPipeline: any MTLRenderPipelineState
    private let pointPipeline: any MTLRenderPipelineState
    private let segmentPipeline: any MTLRenderPipelineState
    private let inFlight = DispatchSemaphore(value: Renderer.maxFramesInFlight)
    private var instanceBuffers: [(any MTLBuffer)?] = Array(repeating: nil, count: Renderer.maxFramesInFlight)
    private var bufferIndex = 0

    init(device: any MTLDevice, pixelFormat: MTLPixelFormat) throws {
        guard let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal", subdirectory: "MetalSource") else {
            throw SetupError.missingShaderSource
        }
        let library = try device.makeLibrary(source: try String(contentsOf: url, encoding: .utf8), options: nil)
        guard let queue = device.makeCommandQueue() else { throw SetupError.noCommandQueue }
        self.device = device
        self.queue = queue

        func pipeline(_ vertex: String, _ fragment: String, blended: Bool) throws -> any MTLRenderPipelineState {
            guard let v = library.makeFunction(name: vertex) else { throw SetupError.missingFunction(vertex) }
            guard let f = library.makeFunction(name: fragment) else { throw SetupError.missingFunction(fragment) }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = v
            descriptor.fragmentFunction = f
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = pixelFormat
            if blended {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        cameraPipeline = try pipeline("fullscreenVertex", "cameraFragment", blended: false)
        skyPipeline = try pipeline("fullscreenVertex", "skyFragment", blended: false)
        pointPipeline = try pipeline("pointVertex", "pointFragment", blended: true)
        segmentPipeline = try pipeline("segmentVertex", "segmentFragment", blended: true)
    }

    func draw(to drawable: any CAMetalDrawable, background: RenderBackground, geometry: CameraGeometry,
              deviceFromReference: simd_double3x3, overlay: OverlayFrame, redTheme: Bool) {
        inFlight.wait()
        guard let commandBuffer = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let semaphore = inFlight
        let keepAlive: CameraFrame?
        if case .camera(let frame) = background { keepAlive = frame } else { keepAlive = nil }
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(keepAlive) {}
            semaphore.signal()
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            commandBuffer.commit()
            return
        }

        var uniforms = FrameUniforms(viewport: SIMD2<Float>(geometry.drawableSize), redTheme: redTheme ? 1 : 0,
                                     sensorFromScreen: Self.float(geometry.sensorFromScreen),
                                     sensorSize: SIMD2<Float>(geometry.intrinsics.referenceSize))
        switch background {
        case .camera(let frame):
            uniforms.sensorSize = SIMD2(Float(frame.size.x), Float(frame.size.y))
            encoder.setRenderPipelineState(cameraPipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            encoder.setFragmentTexture(frame.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        case .sky(let lighting):
            var sky = SkyUniforms(referenceFromScreen: Self.float(geometry.referenceFromScreen(deviceFromReference: deviceFromReference)),
                                  lighting: Float(lighting))
            encoder.setRenderPipelineState(skyPipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&sky, length: MemoryLayout<SkyUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encodeOverlay(overlay, encoder: encoder, uniforms: &uniforms)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func encodeOverlay(_ overlay: OverlayFrame, encoder: any MTLRenderCommandEncoder, uniforms: inout FrameUniforms) {
        var layout: [(offset: Int, count: Int, isSegments: Bool, hasUnderlay: Bool)] = []
        var cursor = 0
        for batch in overlay.batches {
            switch batch {
            case .points(let points):
                cursor = Self.align(cursor)
                layout.append((cursor, points.count, false, false))
                cursor += points.count * MemoryLayout<OverlayPoint>.stride
            case .segments(let segments):
                cursor = Self.align(cursor)
                layout.append((cursor, segments.count, true, segments.contains { $0.outlineWidth > 0 || $0.glow > 0 }))
                cursor += segments.count * MemoryLayout<OverlaySegment>.stride
            case .labels:
                continue
            }
        }
        guard cursor > 0, let buffer = instanceBuffer(minimumLength: cursor) else { return }

        var slot = 0
        for batch in overlay.batches {
            switch batch {
            case .points(let points):
                points.withUnsafeBytes { buffer.contents().advanced(by: layout[slot].offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                slot += 1
            case .segments(let segments):
                segments.withUnsafeBytes { buffer.contents().advanced(by: layout[slot].offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                slot += 1
            case .labels:
                continue
            }
        }

        for entry in layout where entry.count > 0 {
            encoder.setRenderPipelineState(entry.isSegments ? segmentPipeline : pointPipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            encoder.setVertexBuffer(buffer, offset: entry.offset, index: 1)
            guard entry.isSegments else {
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: entry.count)
                continue
            }
            encoder.setFragmentBuffer(buffer, offset: entry.offset, index: 1)
            for pass: UInt32 in entry.hasUnderlay ? [0, 1] : [1] {
                var pass = pass
                encoder.setFragmentBytes(&pass, length: MemoryLayout<UInt32>.stride, index: 2)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: entry.count)
            }
        }
    }

    /// One buffer per in-flight frame; the semaphore guarantees the GPU is done with the slot being reused.
    private func instanceBuffer(minimumLength: Int) -> (any MTLBuffer)? {
        bufferIndex = (bufferIndex + 1) % Self.maxFramesInFlight
        if let existing = instanceBuffers[bufferIndex], existing.length >= minimumLength {
            return existing
        }
        let length = max(minimumLength * 2, 256 * 1024)
        let buffer = device.makeBuffer(length: length, options: .storageModeShared)
        instanceBuffers[bufferIndex] = buffer
        return buffer
    }

    private static func align(_ value: Int) -> Int {
        (value + batchAlignment - 1) / batchAlignment * batchAlignment
    }

    private static func float(_ m: simd_double3x3) -> simd_float3x3 {
        simd_float3x3(SIMD3<Float>(m.columns.0), SIMD3<Float>(m.columns.1), SIMD3<Float>(m.columns.2))
    }
}
