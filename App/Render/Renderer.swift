import Foundation
import Metal
import MetalKit
import QuartzCore
import SkyCore
import UIKit
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
        var cameraFromDisplay = matrix_identity_float3x3
        var rowRotation = SIMD4<Float>.zero
        var intrinsics = SIMD4<Float>.zero
    }

    private struct SkyUniforms {
        var referenceFromScreen: simd_float3x3
        var lighting: Float
        var padding: SIMD3<Float> = .zero
    }

    /// Mirrors StyleUniforms in Shaders.metal. Colours are display-encoded; params = (lighting, time, reduceMotion, redNight);
    /// sparkle = (ray length, ray width, tint mix, twinkle); lines = (twinkle speed, halo multiple, 0, 0).
    private struct StyleUniforms {
        var skyZenith = SIMD4<Float>.zero
        var skyHorizon = SIMD4<Float>.zero
        var ground = SIMD4<Float>.zero
        var light = SIMD4<Float>.zero
        var core = SIMD4<Float>.zero
        var line = SIMD4<Float>.zero
        var params = SIMD4<Float>.zero
        var sparkle = SIMD4<Float>.zero
        var lines = SIMD4<Float>.zero

        init() {}

        init(lighting: Double, red: Bool, time: Double, reduceMotion: Bool) {
            let palette = StyleTokens.blended(lighting: lighting, red: red)
            func color(_ c: SIMD3<Float>) -> SIMD4<Float> { SIMD4(StyleTokens.encode(c), 1) }
            skyZenith = color(palette.skyZenith)
            skyHorizon = color(palette.skyHorizon)
            ground = color(palette.ground)
            light = color(palette.light)
            core = color(palette.core)
            line = color(palette.line)
            params = SIMD4(Float(lighting), Float(time.truncatingRemainder(dividingBy: 3600)), reduceMotion ? 1 : 0, red ? 1 : 0)
            sparkle = SIMD4(StyleTokens.sparkleRayLength, StyleTokens.sparkleRayWidth, StyleTokens.sparkleTintMix,
                            reduceMotion ? 0 : StyleTokens.twinkleAmount)
            lines = SIMD4(StyleTokens.twinkleSpeed, 3.5, 0, 0)
        }
    }

    private var style = StyleUniforms()

    static let maxFramesInFlight = 3
    private static let batchAlignment = 256

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let cameraPipeline: any MTLRenderPipelineState
    private let skyPipeline: any MTLRenderPipelineState
    private let pointPipeline: any MTLRenderPipelineState
    private let segmentPipeline: any MTLRenderPipelineState
    private let labelPipeline: any MTLRenderPipelineState
    private let meshPipeline: any MTLRenderPipelineState
    private let milkyWayPipeline: any MTLRenderPipelineState
    private let labelAtlas: LabelAtlas?
    private var milkyWayTexture: (any MTLTexture)?
    private var artworkTextures: [String: any MTLTexture] = [:]
    private var missingArtwork: Set<String> = []
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
        labelPipeline = try pipeline("labelVertex", "labelFragment", blended: true)
        meshPipeline = try pipeline("meshVertex", "meshFragment", blended: true)
        milkyWayPipeline = try pipeline("fullscreenVertex", "milkyWayFragment", blended: true)
        labelAtlas = LabelAtlas(device: device)
    }

    /// Equirectangular ICRS level map (row 0 at Dec +90, column 0 at RA 0°), one byte per texel.
    func setMilkyWay(levels: [UInt8], width: Int, height: Int) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard levels.count == width * height, let texture = device.makeTexture(descriptor: descriptor) else { return }
        levels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width)
        }
        milkyWayTexture = texture
    }

    private func artworkTexture(_ file: String) -> (any MTLTexture)? {
        if let texture = artworkTextures[file] { return texture }
        guard !missingArtwork.contains(file), let base = Bundle.main.resourceURL else { return nil }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft, .generateMipmaps: false]
        guard let texture = try? loader.newTexture(URL: base.appendingPathComponent(file), options: options) else {
            missingArtwork.insert(file)
            return nil
        }
        artworkTextures[file] = texture
        return texture
    }

    func draw(to drawable: any CAMetalDrawable, background: RenderBackground, geometry: CameraGeometry,
              deviceFromReference: simd_double3x3, warp: FrameWarp? = nil, overlay: OverlayFrame, redTheme: Bool, contentScale: Double, lighting: Double) {
        style = StyleUniforms(lighting: lighting, red: redTheme, time: CACurrentMediaTime(),
                              reduceMotion: UIAccessibility.isReduceMotionEnabled)
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
            if let warp {
                uniforms.cameraFromDisplay = Self.float(warp.cameraFromDisplay)
                uniforms.rowRotation = SIMD4(Float(warp.rowRotation.x), Float(warp.rowRotation.y), Float(warp.rowRotation.z), 1)
                uniforms.intrinsics = SIMD4(Float(warp.intrinsics.fx), Float(warp.intrinsics.fy), Float(warp.intrinsics.cx), Float(warp.intrinsics.cy))
            }
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
            encoder.setFragmentBytes(&style, length: MemoryLayout<StyleUniforms>.stride, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encodeOverlay(overlay, encoder: encoder, uniforms: &uniforms, contentScale: Float(contentScale))
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private struct LabelInstance {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var uv: SIMD4<Float>
        var color: SIMD4<Float>
    }

    private struct MilkyWayUniforms {
        var icrsFromScreen: simd_float3x3
        var intensity: Float
        var padding: SIMD3<Float> = .zero
    }

    private enum Prepared {
        case points(offset: Int, array: [OverlayPoint])
        case segments(offset: Int, array: [OverlaySegment], hasUnderlay: Bool)
        case labels(offset: Int, array: [LabelInstance])
        case mesh(offset: Int, mesh: OverlayMesh, texture: any MTLTexture)
        case milkyWay(OverlayMilkyWay, texture: any MTLTexture)
    }

    private func encodeOverlay(_ overlay: OverlayFrame, encoder: any MTLRenderCommandEncoder, uniforms: inout FrameUniforms,
                               contentScale: Float) {
        var prepared: [Prepared] = []
        var cursor = 0
        func reserve<T>(_ count: Int, of type: T.Type) -> Int {
            cursor = Self.align(cursor)
            defer { cursor += count * MemoryLayout<T>.stride }
            return cursor
        }
        for batch in overlay.batches {
            switch batch {
            case .points(let points):
                prepared.append(.points(offset: reserve(points.count, of: OverlayPoint.self), array: points))
            case .segments(let segments):
                prepared.append(.segments(offset: reserve(segments.count, of: OverlaySegment.self), array: segments,
                                          hasUnderlay: segments.contains { $0.outlineWidth > 0 || $0.glow > 0 }))
            case .labels(let labels):
                let instances = labelInstances(labels, contentScale: contentScale)
                if !instances.isEmpty { prepared.append(.labels(offset: reserve(instances.count, of: LabelInstance.self), array: instances)) }
            case .mesh(let mesh):
                if let texture = artworkTexture(mesh.textureID) {
                    prepared.append(.mesh(offset: reserve(mesh.vertices.count, of: OverlayMeshVertex.self), mesh: mesh, texture: texture))
                }
            case .milkyWay(let params):
                if let milkyWayTexture { prepared.append(.milkyWay(params, texture: milkyWayTexture)) }
            }
        }
        guard !prepared.isEmpty else { return }
        let buffer = cursor > 0 ? instanceBuffer(minimumLength: cursor) : nil
        if cursor > 0, buffer == nil { return }

        func upload<T>(_ array: [T], at offset: Int) {
            guard let buffer else { return }
            array.withUnsafeBytes { buffer.contents().advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        func bindUniforms(_ pipeline: any MTLRenderPipelineState) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            encoder.setVertexBytes(&style, length: MemoryLayout<StyleUniforms>.stride, index: 3)
            encoder.setFragmentBytes(&style, length: MemoryLayout<StyleUniforms>.stride, index: 3)
        }

        for item in prepared {
            switch item {
            case .points(let offset, let array):
                guard !array.isEmpty else { continue }
                upload(array, at: offset)
                bindUniforms(pointPipeline)
                encoder.setVertexBuffer(buffer, offset: offset, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: array.count)
            case .segments(let offset, let array, let hasUnderlay):
                guard !array.isEmpty else { continue }
                upload(array, at: offset)
                bindUniforms(segmentPipeline)
                encoder.setVertexBuffer(buffer, offset: offset, index: 1)
                encoder.setFragmentBuffer(buffer, offset: offset, index: 1)
                for pass: UInt32 in hasUnderlay ? [0, 1] : [1] {
                    var pass = pass
                    encoder.setFragmentBytes(&pass, length: MemoryLayout<UInt32>.stride, index: 2)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: array.count)
                }
            case .labels(let offset, let array):
                upload(array, at: offset)
                bindUniforms(labelPipeline)
                encoder.setVertexBuffer(buffer, offset: offset, index: 1)
                encoder.setFragmentTexture(labelAtlas?.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: array.count)
            case .mesh(let offset, let mesh, let texture):
                upload(mesh.vertices, at: offset)
                bindUniforms(meshPipeline)
                var alpha = mesh.alpha
                var tint = mesh.tint
                encoder.setVertexBuffer(buffer, offset: offset, index: 1)
                encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 1)
                encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD3<Float>>.stride, index: 2)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertices.count)
            case .milkyWay(let params, let texture):
                bindUniforms(milkyWayPipeline)
                var mw = MilkyWayUniforms(icrsFromScreen: params.icrsFromScreen, intensity: params.intensity)
                encoder.setFragmentBytes(&mw, length: MemoryLayout<MilkyWayUniforms>.stride, index: 1)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }
    }

    private func labelInstances(_ labels: [OverlayLabel], contentScale: Float) -> [LabelInstance] {
        guard let labelAtlas else { return [] }
        var instances: [LabelInstance] = []
        instances.reserveCapacity(labels.count)
        for label in labels where label.color.w > 0.01 {
            let pixelSize = max(6, Int((label.fontSize * contentScale).rounded()))
            guard let entry = labelAtlas.entry(text: label.text, pixelSize: pixelSize, bold: label.bold) else { continue }
            let origin = label.position - entry.size * label.anchor
            instances.append(LabelInstance(origin: origin.rounded(.toNearestOrAwayFromZero), size: entry.size, uv: entry.uv, color: label.color))
        }
        return instances
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
