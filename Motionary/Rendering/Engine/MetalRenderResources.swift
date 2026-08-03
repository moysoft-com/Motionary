import CoreImage
import CoreVideo
import Foundation
import Metal
import os

private struct ScratchTextureKey: Hashable {
    let width: Int
    let height: Int
    let pixelFormat: MTLPixelFormat
}

private final class ScratchTexturePool {
    private let device: MTLDevice
    private let lock = NSLock()
    private var available: [ScratchTextureKey: [MTLTexture]] = [:]
    private let maximumTexturesPerBucket = 6
    private let maximumPooledTextures = 36
    private let maximumPooledBytes: Int
    private var pooledTextureCount = 0
    private var pooledBytes = 0
    private let signpostLog = OSLog(
        subsystem: "com.moysoft.motionary",
        category: .pointsOfInterest
    )

    init(device: MTLDevice, maximumPooledBytes: Int) {
        self.device = device
        self.maximumPooledBytes = maximumPooledBytes
    }

    func acquire(width: Int, height: Int, pixelFormat: MTLPixelFormat) throws -> MTLTexture {
        let width = max(width, 1)
        let height = max(height, 1)
        let key = ScratchTextureKey(width: width, height: height, pixelFormat: pixelFormat)
        lock.lock()
        if var bucket = available[key], let texture = bucket.popLast() {
            available[key] = bucket
            pooledTextureCount -= 1
            pooledBytes -= estimatedBytes(of: texture)
            lock.unlock()
            os_signpost(
                .event,
                log: signpostLog,
                name: "Scratch Pool Hit",
                "%d x %d; pooled=%d",
                width,
                height,
                pooledTextureCount
            )
            return texture
        }
        lock.unlock()
        os_signpost(
            .event,
            log: signpostLog,
            name: "Scratch Pool Miss",
            "%d x %d",
            width,
            height
        )

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.hazardTrackingMode = .tracked
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRenderingError.textureAllocationFailed(width: width, height: height)
        }
        texture.label = "Motionary scratch \(width)x\(height) \(pixelFormat.rawValue)"
        return texture
    }

    func recycle(_ textures: [MTLTexture]) {
        lock.lock()
        defer { lock.unlock() }
        for texture in textures {
            let key = ScratchTextureKey(
                width: texture.width,
                height: texture.height,
                pixelFormat: texture.pixelFormat
            )
            var bucket = available[key, default: []]
            let byteCount = estimatedBytes(of: texture)
            if bucket.count < maximumTexturesPerBucket,
                pooledTextureCount < maximumPooledTextures,
                pooledBytes + byteCount <= maximumPooledBytes
            {
                bucket.append(texture)
                available[key] = bucket
                pooledTextureCount += 1
                pooledBytes += byteCount
            }
        }
        os_signpost(
            .event,
            log: signpostLog,
            name: "Scratch Pool Bestand",
            "textures=%d bytes=%d",
            pooledTextureCount,
            pooledBytes
        )
    }

    func removeAll() {
        lock.lock()
        available.removeAll(keepingCapacity: false)
        pooledTextureCount = 0
        pooledBytes = 0
        lock.unlock()
    }

    private func estimatedBytes(of texture: MTLTexture) -> Int {
        let bytesPerPixel: Int
        switch texture.pixelFormat {
        case .rgba16Float: bytesPerPixel = 8
        case .bgra8Unorm, .bgra8Unorm_srgb, .rgba8Unorm, .rgba8Unorm_srgb: bytesPerPixel = 4
        case .rg8Unorm: bytesPerPixel = 2
        default: bytesPerPixel = 1
        }
        return texture.width * texture.height * max(texture.arrayLength, 1) * bytesPerPixel
    }
}

private final class UniformBufferRing {
    struct Slot {
        let index: Int
        let buffer: MTLBuffer
    }

    private let lock = NSLock()
    private var availableIndices: [Int]
    private let buffers: [MTLBuffer]

    init(device: MTLDevice, inFlightCount: Int, bytesPerFrame: Int) throws {
        var buffers: [MTLBuffer] = []
        for index in 0..<inFlightCount {
            guard let buffer = device.makeBuffer(
                length: bytesPerFrame,
                options: .storageModeShared
            ) else {
                throw MetalRenderingError.textureAllocationFailed(width: bytesPerFrame, height: 1)
            }
            buffer.label = "Motionary uniform ring \(index)"
            buffers.append(buffer)
        }
        self.buffers = buffers
        self.availableIndices = Array(buffers.indices.reversed())
    }

    func acquire() -> Slot? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = availableIndices.popLast() else { return nil }
        return Slot(index: index, buffer: buffers[index])
    }

    func release(_ slot: Slot) {
        lock.lock()
        if !availableIndices.contains(slot.index) {
            availableIndices.append(slot.index)
        }
        lock.unlock()
    }
}

final class MetalRenderResources: @unchecked Sendable {
    static let maximumInFlightFrames = 3
    // One aligned slot is 256 bytes. A generous fixed ring is still tiny
    // compared with a single FP16 render target and avoids rejecting valid
    // multilayer projects with long effect stacks.
    private static let uniformBytesPerFrame = 256 * 1_024

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let ciContext: CIContext
    let workingColorSpace: CGColorSpace
    let outputColorSpace: CGColorSpace
    let generatedColorSpace: CGColorSpace

    private let textureCache: CVMetalTextureCache
    private let texturePool: ScratchTexturePool
    private let uniformRing: UniformBufferRing
    private let inFlightSemaphore = DispatchSemaphore(value: maximumInFlightFrames)
    private let pipelines: [String: MTLComputePipelineState]

    private static let sharedResult: Result<MetalRenderResources, Error> = Result {
        try MetalRenderResources()
    }

    static func shared() throws -> MetalRenderResources {
        try sharedResult.get()
    }

    static func validateAvailability() throws {
        _ = try sharedResult.get()
    }

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw MetalRenderingError.metalUnavailable }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRenderingError.commandQueueUnavailable
        }
        commandQueue.label = "Motionary Rendering Engine v2"

        guard let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
            let outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709),
            let generatedColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            throw MetalRenderingError.invalidRenderTarget
        }

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw MetalRenderingError.pixelBufferTextureCreationFailed(cacheStatus)
        }

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            guard let fallback = device.makeDefaultLibrary() else {
                throw MetalRenderingError.shaderLibraryUnavailable
            }
            library = fallback
        }

        let functionNames = [
            "motionaryYUVToRGBA",
            "motionaryShapeKernel",
            "motionaryEffectKernel",
            "motionaryHighlightKernel",
            "motionarySeparableBlurKernel",
            "motionaryGlowCompositeKernel",
            "motionaryBlendKernel"
        ]
        var pipelines: [String: MTLComputePipelineState] = [:]
        for functionName in functionNames {
            guard let function = library.makeFunction(name: functionName) else {
                throw MetalRenderingError.shaderFunctionUnavailable(functionName)
            }
            do {
                let pipeline = try device.makeComputePipelineState(function: function)
                pipelines[functionName] = pipeline
            } catch {
                throw MetalRenderingError.pipelineCreationFailed(functionName, error)
            }
        }

        self.device = device
        self.commandQueue = commandQueue
        self.workingColorSpace = workingColorSpace
        self.outputColorSpace = outputColorSpace
        self.generatedColorSpace = generatedColorSpace
        self.textureCache = cache
        self.texturePool = ScratchTexturePool(
            device: device,
            maximumPooledBytes: Self.scratchTexturePoolBudgetBytes()
        )
        self.uniformRing = try UniformBufferRing(
            device: device,
            inFlightCount: Self.maximumInFlightFrames,
            bytesPerFrame: Self.uniformBytesPerFrame
        )
        self.pipelines = pipelines
        self.ciContext = CIContext(
            mtlCommandQueue: commandQueue,
            options: [
                .name: "Motionary shared Metal CIContext",
                .workingColorSpace: workingColorSpace,
                .outputColorSpace: outputColorSpace,
                .cacheIntermediates: false,
                .allowLowPower: false
            ]
        )
    }

    func beginFrame() throws -> MetalFrameResources {
        inFlightSemaphore.wait()
        return try makeFrameAfterAcquiringPermit()
    }

    func beginFrame(isCancelled: () -> Bool) throws -> MetalFrameResources {
        let deadline = CFAbsoluteTimeGetCurrent() + 0.25
        while true {
            guard !isCancelled() else { throw MetalRenderingError.cancelled }
            if inFlightSemaphore.wait(timeout: .now() + .milliseconds(2)) == .success {
                return try makeFrameAfterAcquiringPermit()
            }
            guard CFAbsoluteTimeGetCurrent() < deadline else {
                throw MetalRenderingError.cancelled
            }
        }
    }

    private func makeFrameAfterAcquiringPermit() throws -> MetalFrameResources {
        guard let slot = uniformRing.acquire() else {
            inFlightSemaphore.signal()
            throw MetalRenderingError.commandBufferUnavailable
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            uniformRing.release(slot)
            inFlightSemaphore.signal()
            throw MetalRenderingError.commandBufferUnavailable
        }
        commandBuffer.label = "Motionary frame"
        return MetalFrameResources(
            owner: self,
            commandBuffer: commandBuffer,
            uniformSlot: slot
        )
    }

    func pipeline(named name: String) throws -> MTLComputePipelineState {
        guard let pipeline = pipelines[name] else {
            throw MetalRenderingError.shaderFunctionUnavailable(name)
        }
        return pipeline
    }

    fileprivate func acquireTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLTexture {
        try texturePool.acquire(width: width, height: height, pixelFormat: pixelFormat)
    }

    fileprivate func finishFrame(
        slot: UniformBufferRing.Slot,
        textures: [MTLTexture]
    ) {
        texturePool.recycle(textures)
        uniformRing.release(slot)
        inFlightSemaphore.signal()
    }

    func purgeCaches() {
        purgeTransientResources()
        ciContext.clearCaches()
    }

    func purgeTransientResources() {
        texturePool.removeAll()
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    fileprivate func makePixelBufferTexture(
        _ pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        planeIndex: Int
    ) throws -> CVMetalTexture {
        var textureReference: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &textureReference
        )
        guard status == kCVReturnSuccess, let textureReference else {
            throw MetalRenderingError.pixelBufferTextureCreationFailed(status)
        }
        return textureReference
    }

    fileprivate func sourceColorSpace(for pixelBuffer: CVPixelBuffer) -> CGColorSpace {
        let primaries = attachment(
            kCVImageBufferColorPrimariesKey,
            in: pixelBuffer
        )
        let transfer = attachment(
            kCVImageBufferTransferFunctionKey,
            in: pixelBuffer
        )
        if primaries == kCVImageBufferColorPrimaries_P3_D65 as String,
            let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
        {
            return colorSpace
        }
        if primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String,
            let colorSpace = CGColorSpace(name: CGColorSpace.itur_2020)
        {
            return colorSpace
        }
        if transfer == kCVImageBufferTransferFunction_sRGB as String,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        {
            return colorSpace
        }
        if primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
            let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)
        {
            return colorSpace
        }
        // SD Rec.601 and untagged RGB buffers are closest to sRGB among the
        // calibrated system spaces. Crucially, they are not mislabeled Rec.709.
        return generatedColorSpace
    }

    fileprivate func yuvMatrixCode(for pixelBuffer: CVPixelBuffer) -> UInt32 {
        let matrix = attachment(kCVImageBufferYCbCrMatrixKey, in: pixelBuffer)
        if matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String { return 0 }
        if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String { return 2 }
        if matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String { return 1 }
        return CVPixelBufferGetWidth(pixelBuffer) >= 1_280 ? 1 : 0
    }

    private func attachment(_ key: CFString, in pixelBuffer: CVPixelBuffer) -> String? {
        CVBufferCopyAttachment(pixelBuffer, key, nil) as? String
    }

    private static func scratchTexturePoolBudgetBytes() -> Int {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let lowerBound = 96 * 1_024 * 1_024
        let upperBound = 384 * 1_024 * 1_024
        let proportionalBudget = Int(min(physicalMemory / 32, UInt64(Int.max)))
        return min(max(proportionalBudget, lowerBound), upperBound)
    }
}

final class MetalFrameResources {
    typealias CompletionHandler = (MTLCommandBuffer) -> Void

    let commandBuffer: MTLCommandBuffer
    unowned let owner: MetalRenderResources

    private let uniformSlot: UniformBufferRing.Slot
    private var uniformOffset = 0
    private var scratchTextures: [MTLTexture] = []
    private var scratchTextureIDs = Set<ObjectIdentifier>()
    private var reusableScratchTextures: [ScratchTextureKey: [MTLTexture]] = [:]
    private var reusableScratchTextureIDs = Set<ObjectIdentifier>()
    private var retainedCVTextures: [CVMetalTexture] = []
    private var completionHandlers: [CompletionHandler] = []
    private var didFinish = false

    fileprivate init(
        owner: MetalRenderResources,
        commandBuffer: MTLCommandBuffer,
        uniformSlot: UniformBufferRing.Slot
    ) {
        self.owner = owner
        self.commandBuffer = commandBuffer
        self.uniformSlot = uniformSlot
    }

    deinit {
        if !didFinish {
            owner.finishFrame(slot: uniformSlot, textures: scratchTextures)
        }
    }

    func makeScratchTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .rgba16Float
    ) throws -> MTLTexture {
        let key = ScratchTextureKey(
            width: max(width, 1),
            height: max(height, 1),
            pixelFormat: pixelFormat
        )
        if var reusable = reusableScratchTextures[key], let texture = reusable.popLast() {
            reusableScratchTextures[key] = reusable
            reusableScratchTextureIDs.remove(ObjectIdentifier(texture))
            return texture
        }
        let texture = try owner.acquireTexture(
            width: key.width,
            height: key.height,
            pixelFormat: pixelFormat
        )
        scratchTextures.append(texture)
        scratchTextureIDs.insert(ObjectIdentifier(texture))
        return texture
    }

    /// Makes a scratch surface available to later command encoders in this
    /// frame. Metal command-buffer ordering guarantees that prior reads have
    /// completed before a subsequent encoder overwrites the surface.
    func releaseScratchTexture(_ texture: MTLTexture) {
        let identifier = ObjectIdentifier(texture)
        guard scratchTextureIDs.contains(identifier),
            reusableScratchTextureIDs.insert(identifier).inserted
        else { return }
        let key = ScratchTextureKey(
            width: texture.width,
            height: texture.height,
            pixelFormat: texture.pixelFormat
        )
        reusableScratchTextures[key, default: []].append(texture)
    }

    /// Runs after this frame's command buffer has reached a terminal state.
    /// Abandoned, uncommitted frames discard these handlers, so callers cannot
    /// accidentally publish GPU resources whose upload never executed.
    func addCompletionHandler(_ handler: @escaping CompletionHandler) {
        guard !didFinish else { return }
        completionHandlers.append(handler)
    }

    func writeUniforms<T>(_ value: T) throws -> (buffer: MTLBuffer, offset: Int) {
        let alignment = 256
        let size = MemoryLayout<T>.stride
        let alignedOffset = (uniformOffset + alignment - 1) & ~(alignment - 1)
        guard alignedOffset + size <= uniformSlot.buffer.length else {
            throw MetalRenderingError.textureAllocationFailed(
                width: uniformSlot.buffer.length,
                height: 1
            )
        }
        var value = value
        withUnsafeBytes(of: &value) { bytes in
            uniformSlot.buffer.contents()
                .advanced(by: alignedOffset)
                .copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        uniformOffset = alignedOffset + size
        return (uniformSlot.buffer, alignedOffset)
    }

    func makeDestinationTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let reference = try owner.makePixelBufferTexture(
            pixelBuffer,
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            planeIndex: 0
        )
        retainedCVTextures.append(reference)
        guard let texture = CVMetalTextureGetTexture(reference) else {
            throw MetalRenderingError.invalidRenderTarget
        }
        return texture
    }

    func makeSourceImage(from pixelBuffer: CVPixelBuffer) throws -> CIImage {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if format == kCVPixelFormatType_32BGRA {
            let reference = try owner.makePixelBufferTexture(
                pixelBuffer,
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                planeIndex: 0
            )
            retainedCVTextures.append(reference)
            guard let texture = CVMetalTextureGetTexture(reference),
                let image = CIImage(
                    mtlTexture: texture,
                    options: [.colorSpace: owner.sourceColorSpace(for: pixelBuffer)]
                )
            else { throw MetalRenderingError.invalidRenderTarget }
            return image
        }

        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        else {
            throw MetalRenderingError.unsupportedPixelFormat(format)
        }

        let lumaReference = try owner.makePixelBufferTexture(
            pixelBuffer,
            pixelFormat: .r8Unorm,
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            planeIndex: 0
        )
        let chromaReference = try owner.makePixelBufferTexture(
            pixelBuffer,
            pixelFormat: .rg8Unorm,
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
            height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
            planeIndex: 1
        )
        retainedCVTextures.append(contentsOf: [lumaReference, chromaReference])
        guard let lumaTexture = CVMetalTextureGetTexture(lumaReference),
            let chromaTexture = CVMetalTextureGetTexture(chromaReference)
        else { throw MetalRenderingError.invalidRenderTarget }

        let outputTexture = try makeScratchTexture(width: width, height: height)
        let pipeline = try owner.pipeline(named: "motionaryYUVToRGBA")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalRenderingError.commandBufferUnavailable
        }
        encoder.label = "Rec.709 YUV normalization"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(lumaTexture, index: 0)
        encoder.setTexture(chromaTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        let uniform = try writeUniforms(MotionaryYUVUniforms(
            size: SIMD2(UInt32(width), UInt32(height)),
            fullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0,
            matrix: owner.yuvMatrixCode(for: pixelBuffer)
        ))
        encoder.setBuffer(uniform.buffer, offset: uniform.offset, index: 0)
        dispatch(encoder: encoder, pipeline: pipeline, width: width, height: height)
        encoder.endEncoding()

        guard let image = CIImage(
            mtlTexture: outputTexture,
            options: [.colorSpace: owner.sourceColorSpace(for: pixelBuffer)]
        ) else { throw MetalRenderingError.invalidRenderTarget }
        return image
    }

    func dispatch(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
    }

    func commitAndWait() throws {
        guard !didFinish else { return }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        didFinish = true
        runCompletionHandlers()
        owner.finishFrame(slot: uniformSlot, textures: scratchTextures)
        scratchTextures.removeAll(keepingCapacity: false)
        scratchTextureIDs.removeAll(keepingCapacity: false)
        reusableScratchTextures.removeAll(keepingCapacity: false)
        reusableScratchTextureIDs.removeAll(keepingCapacity: false)
        retainedCVTextures.removeAll(keepingCapacity: false)
        guard commandBuffer.status == .completed else {
            throw MetalRenderingError.commandBufferFailed(commandBuffer.error)
        }
    }

    func commit(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !didFinish else {
            completion(.success(()))
            return
        }
        didFinish = true
        let owner = owner
        let slot = uniformSlot
        let textures = scratchTextures
        let retainedTextureReferences = retainedCVTextures
        let completionHandlers = completionHandlers
        commandBuffer.addCompletedHandler { commandBuffer in
            completionHandlers.forEach { $0(commandBuffer) }
            owner.finishFrame(slot: slot, textures: textures)
            _ = retainedTextureReferences.count
            guard commandBuffer.status == .completed else {
                completion(.failure(MetalRenderingError.commandBufferFailed(commandBuffer.error)))
                return
            }
            completion(.success(()))
        }
        commandBuffer.commit()
        scratchTextures.removeAll(keepingCapacity: false)
        scratchTextureIDs.removeAll(keepingCapacity: false)
        reusableScratchTextures.removeAll(keepingCapacity: false)
        reusableScratchTextureIDs.removeAll(keepingCapacity: false)
        retainedCVTextures.removeAll(keepingCapacity: false)
        self.completionHandlers.removeAll(keepingCapacity: false)
    }

    func abandon() {
        guard !didFinish else { return }
        didFinish = true
        owner.finishFrame(slot: uniformSlot, textures: scratchTextures)
        scratchTextures.removeAll(keepingCapacity: false)
        scratchTextureIDs.removeAll(keepingCapacity: false)
        reusableScratchTextures.removeAll(keepingCapacity: false)
        reusableScratchTextureIDs.removeAll(keepingCapacity: false)
        retainedCVTextures.removeAll(keepingCapacity: false)
        completionHandlers.removeAll(keepingCapacity: false)
    }

    private func runCompletionHandlers() {
        let handlers = completionHandlers
        completionHandlers.removeAll(keepingCapacity: false)
        handlers.forEach { $0(commandBuffer) }
    }
}
