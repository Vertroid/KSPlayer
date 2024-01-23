//
//  MetalRender.swift
//  KSPlayer-iOS
//
//  Created by kintan on 2020/1/11.
//
import Accelerate
import CoreVideo
import Foundation
import Metal
import QuartzCore
import simd
import CompositorServices

struct CustomData {
    public var stereoMode: Int = 0
    public var frameCounter: UInt32 = 0
}

struct Uniforms {
    var projectionMatrix: simd_float4x4
    var modelViewMatrix: simd_float4x4
}

struct UniformsArray {
    var uniforms: (Uniforms, Uniforms)
}

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

let alignedUniformsSize = (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100
let maxBuffersInFlight = 3

class MetalRender {
    static var options: KSOptions? = KSOptions()
    static let device = MTLCreateSystemDefaultDevice()!
    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)
    static let library: MTLLibrary = {
        var library: MTLLibrary!
        library = device.makeDefaultLibrary()
        if library == nil {
            library = try? device.makeDefaultLibrary(bundle: .module)
        }
        return library
    }()

    private var customBuffer: CustomData
    private let worldTracking: WorldTrackingProvider
    private let arSession: ARKitSession
    private let renderPassDescriptor = MTLRenderPassDescriptor()
    private let commandQueue = MetalRender.device.makeCommandQueue()
    private lazy var samplerState: MTLSamplerState? = {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        return MetalRender.device.makeSamplerState(descriptor: samplerDescriptor)
    }()

    private lazy var colorConversion601VideoRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_ITU_R_601_4.pointee.videoRange.buffer

    private lazy var colorConversion601FullRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_ITU_R_601_4.pointee.buffer

    private lazy var colorConversion709VideoRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_ITU_R_709_2.pointee.videoRange.buffer

    private lazy var colorConversion709FullRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_ITU_R_709_2.pointee.buffer

    private lazy var colorConversionSMPTE240MVideoRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_SMPTE_240M_1995.videoRange.buffer

    private lazy var colorConversionSMPTE240MFullRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_SMPTE_240M_1995.buffer

    private lazy var colorConversion2020VideoRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_ITU_R_2020.videoRange.buffer

    private lazy var colorConversion2020FullRangeMatrixBuffer: MTLBuffer? = kvImage_YpCbCrToARGBMatrix_ITU_R_2020.buffer

    private lazy var colorOffsetVideoRangeMatrixBuffer: MTLBuffer? = {
        var firstColumn = SIMD3<Float>(-16.0 / 255.0, -128.0 / 255.0, -128.0 / 255.0)
        let buffer = MetalRender.device.makeBuffer(bytes: &firstColumn, length: MemoryLayout<SIMD3<Float>>.size)
        buffer?.label = "colorOffset"
        return buffer
    }()

    private lazy var colorOffsetFullRangeMatrixBuffer: MTLBuffer? = {
        var firstColumn = SIMD3<Float>(0, -128.0 / 255.0, -128.0 / 255.0)
        let buffer = MetalRender.device.makeBuffer(bytes: &firstColumn, length: MemoryLayout<SIMD3<Float>>.size)
        buffer?.label = "colorOffset"
        return buffer
    }()

    private lazy var leftShiftMatrixBuffer: MTLBuffer? = {
        var firstColumn = SIMD3<UInt8>(1, 1, 1)
        let buffer = MetalRender.device.makeBuffer(bytes: &firstColumn, length: MemoryLayout<SIMD3<UInt8>>.size)
        buffer?.label = "leftShit"
        return buffer
    }()

    private lazy var leftShiftSixMatrixBuffer: MTLBuffer? = {
        var firstColumn = SIMD3<UInt8>(64, 64, 64)
        let buffer = MetalRender.device.makeBuffer(bytes: &firstColumn, length: MemoryLayout<SIMD3<UInt8>>.size)
        buffer?.label = "leftShit"
        return buffer
    }()
    
    private lazy var customDataBuffer: MTLBuffer? = {
        let buffer = MetalRender.device.makeBuffer(length: MemoryLayout<CustomData>.size, options: .storageModeShared)
        buffer?.label = "customData"
        return buffer
    }()

    public init() {
        customBuffer = CustomData()
        worldTracking = WorldTrackingProvider()
        arSession = ARKitSession()
        Task {
            do {
                try await arSession.run([worldTracking])
            } catch {
                fatalError("Failed to initialize ARSession")
            }
        }
    }
    
    func clear(drawable: MTLDrawable) {
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        guard let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func drawPlane(pixelBuffer: PixelBufferProtocol, display: DisplayEnum = .plane, drawable: CAMetalDrawable) {
        let inputTextures = pixelBuffer.textures()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        guard !inputTextures.isEmpty, let commandBuffer = commandQueue?.makeCommandBuffer(), let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        encoder.pushDebugGroup("RenderFrame")
        let state = display.pipeline(planeCount: pixelBuffer.planeCount, bitDepth: pixelBuffer.bitDepth)
        encoder.setRenderPipelineState(state)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        for (index, texture) in inputTextures.enumerated() {
            texture.label = "texture\(index)"
            encoder.setFragmentTexture(texture, index: index)
        }
        setFragmentBuffer(pixelBuffer: pixelBuffer, encoder: encoder)
        display.set(encoder: encoder, viewMatrix: simd_float4x4())
        encoder.popDebugGroup()
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    
    func drawImmersive(pixelBuffer: PixelBufferProtocol, display: DisplayEnum = .plane) {
        guard let layerRenderer = MetalRender.options?.layerRenderer else {
            return
        }
        guard let frame = layerRenderer.queryNextFrame() else { return }
        
        frame.startUpdate()
        
        frame.endUpdate()
        
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        
        guard let drawable = frame.queryDrawable() else { return }
        
        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
        
        frame.startSubmission()
        
        let time = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)
        
        drawable.deviceAnchor = deviceAnchor
    
        let inputTextures = pixelBuffer.textures()
        renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        guard !inputTextures.isEmpty, let commandBuffer = commandQueue!.makeCommandBuffer(), let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
        }
        
        encoder.pushDebugGroup("RenderFrame")
        let state = display.pipeline(planeCount: pixelBuffer.planeCount, bitDepth: pixelBuffer.bitDepth)
        encoder.setRenderPipelineState(state)
        
        let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        let viewMatrix = (simdDeviceAnchor * drawable.views[0].transform).inverse
        
        encoder.setFragmentSamplerState(samplerState, index: 0)
        for (index, texture) in inputTextures.enumerated() {
            texture.label = "texture\(index)"
            encoder.setFragmentTexture(texture, index: index)
        }
        setFragmentBuffer(pixelBuffer: pixelBuffer, encoder: encoder)
        display.set(encoder: encoder, viewMatrix: viewMatrix)
        encoder.popDebugGroup()
        encoder.endEncoding()
        drawable.encodePresent(commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        frame.endSubmission()
    }
    
    func updateCustomDataBuffer() {
        customBuffer.stereoMode = (MetalRender.options?.stereo.rawValue)!
        customBuffer.frameCounter &+= 1
        let bufferPointer = customDataBuffer?.contents()
        bufferPointer!.copyMemory(from: &customBuffer, byteCount: MemoryLayout<CustomData>.size)
    }

    private func setFragmentBuffer(pixelBuffer: PixelBufferProtocol, encoder: MTLRenderCommandEncoder) {
        if pixelBuffer.planeCount > 1 {
            let buffer: MTLBuffer?
            let yCbCrMatrix = pixelBuffer.yCbCrMatrix
            let isFullRangeVideo = pixelBuffer.isFullRangeVideo
            if yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 {
                buffer = isFullRangeVideo ? colorConversion709FullRangeMatrixBuffer : colorConversion709VideoRangeMatrixBuffer
            } else if yCbCrMatrix == kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 {
                buffer = isFullRangeVideo ? colorConversionSMPTE240MFullRangeMatrixBuffer : colorConversionSMPTE240MVideoRangeMatrixBuffer
            } else if yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 {
                buffer = isFullRangeVideo ? colorConversion2020FullRangeMatrixBuffer : colorConversion2020VideoRangeMatrixBuffer
            } else {
                buffer = isFullRangeVideo ? colorConversion601FullRangeMatrixBuffer : colorConversion601VideoRangeMatrixBuffer
            }
            encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
            let colorOffset = isFullRangeVideo ? colorOffsetFullRangeMatrixBuffer : colorOffsetVideoRangeMatrixBuffer
            encoder.setFragmentBuffer(colorOffset, offset: 0, index: 1)
            let leftShift = pixelBuffer.leftShift == 0 ? leftShiftMatrixBuffer : leftShiftSixMatrixBuffer
            encoder.setFragmentBuffer(leftShift, offset: 0, index: 2)
            
            // Custom data
            updateCustomDataBuffer()
            encoder.setFragmentBuffer(customDataBuffer, offset: 0, index: 3)
        }
    }

    static func makePipelineState(fragmentFunction: String, isSphere: Bool = false, bitDepth: Int32 = 8) -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.colorAttachments[0].pixelFormat = KSOptions.colorPixelFormat(bitDepth: bitDepth)
        descriptor.vertexFunction = library.makeFunction(name: isSphere ? "mapSphereTexture" : "mapTexture")
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float4
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].bufferIndex = 1
        vertexDescriptor.attributes[1].offset = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<simd_float4>.stride
        vertexDescriptor.layouts[1].stride = MemoryLayout<simd_float2>.stride
        descriptor.vertexDescriptor = vertexDescriptor
        // swiftlint:disable force_try
        return try! library.device.makeRenderPipelineState(descriptor: descriptor)
        // swftlint:enable force_try
    }

    static func texture(pixelBuffer: CVPixelBuffer) -> [MTLTexture] {
        guard let iosurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            return []
        }
        let formats = KSOptions.pixelFormat(planeCount: pixelBuffer.planeCount, bitDepth: pixelBuffer.bitDepth)
        return (0 ..< pixelBuffer.planeCount).compactMap { index in
            let width = pixelBuffer.widthOfPlane(at: index)
            let height = pixelBuffer.heightOfPlane(at: index)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: formats[index], width: width, height: height, mipmapped: false)
            return device.makeTexture(descriptor: descriptor, iosurface: iosurface, plane: index)
        }
    }

    static func textures(formats: [MTLPixelFormat], widths: [Int], heights: [Int], buffers: [MTLBuffer?], lineSizes: [Int]) -> [MTLTexture] {
        (0 ..< formats.count).compactMap { i in
            guard let buffer = buffers[i] else {
                return nil
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: formats[i], width: widths[i], height: heights[i], mipmapped: false)
            descriptor.storageMode = buffer.storageMode
            return buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: lineSizes[i])
        }
    }
}

// swiftlint:disable identifier_name
// private let kvImage_YpCbCrToARGBMatrix_ITU_R_601_4 = vImage_YpCbCrToARGBMatrix(Kr: 0.299, Kb: 0.114)
// private let kvImage_YpCbCrToARGBMatrix_ITU_R_709_2 = vImage_YpCbCrToARGBMatrix(Kr: 0.2126, Kb: 0.0722)
private let kvImage_YpCbCrToARGBMatrix_SMPTE_240M_1995 = vImage_YpCbCrToARGBMatrix(Kr: 0.212, Kb: 0.087)
private let kvImage_YpCbCrToARGBMatrix_ITU_R_2020 = vImage_YpCbCrToARGBMatrix(Kr: 0.2627, Kb: 0.0593)
extension vImage_YpCbCrToARGBMatrix {
    /**
     https://en.wikipedia.org/wiki/YCbCr
     @textblock
            | R |    | 1    0                                                            2-2Kr |   | Y' |
            | G | = | 1   -Kb * (2 - 2 * Kb) / Kg   -Kr * (2 - 2 * Kr) / Kg |  | Cb |
            | B |    | 1   2 - 2 * Kb                                                     0  |  | Cr |
     @/textblock
     */
    init(Kr: Float, Kb: Float) {
        let Kg = 1 - Kr - Kb
        self.init(Yp: 1, Cr_R: 2 - 2 * Kr, Cr_G: -Kr * (2 - 2 * Kr) / Kg, Cb_G: -Kb * (2 - 2 * Kb) / Kg, Cb_B: 2 - 2 * Kb)
    }

    var videoRange: vImage_YpCbCrToARGBMatrix {
        vImage_YpCbCrToARGBMatrix(Yp: 255 / 219 * Yp, Cr_R: 255 / 224 * Cr_R, Cr_G: 255 / 224 * Cr_G, Cb_G: 255 / 224 * Cb_G, Cb_B: 255 / 224 * Cb_B)
    }

    var buffer: MTLBuffer? {
        var matrix = simd_float3x3([Yp, Yp, Yp], [0.0, Cb_G, Cb_B], [Cr_R, Cr_G, 0.0])
        let buffer = MetalRender.device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float3x3>.size)
        buffer?.label = "colorConversionMatrix"
        return buffer
    }
}

// swiftlint:enable identifier_name
