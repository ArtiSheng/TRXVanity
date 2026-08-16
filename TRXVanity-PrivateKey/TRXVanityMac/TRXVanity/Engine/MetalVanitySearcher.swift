import Foundation
import Metal

enum VanityEngineError: LocalizedError, Sendable {
    case searchAlreadyRunning
    case metalUnavailable
    case shaderMissing
    case shaderCompilation(String)
    case pipelineCreation(String)
    case bufferAllocation
    case commandQueueUnavailable
    case commandEncodingFailed
    case commandFailed(String)
    case arithmeticOverflow
    case resultVerificationFailed

    var errorDescription: String? {
        switch self {
        case .searchAlreadyRunning:
            return "已有一个搜索任务正在运行。"
        case .metalUnavailable:
            return "当前 Mac 没有可用的 Metal GPU。"
        case .shaderMissing:
            return "App 内缺少 Metal 搜索内核资源。"
        case .shaderCompilation(let details):
            return "Metal 搜索内核编译失败：\(details)"
        case .pipelineCreation(let details):
            return "Metal 计算管线创建失败：\(details)"
        case .bufferAllocation:
            return "无法分配 Metal 搜索缓冲区。"
        case .commandQueueUnavailable:
            return "无法创建 Metal 命令队列。"
        case .commandEncodingFailed:
            return "无法编码 Metal 搜索任务。"
        case .commandFailed(let details):
            return "Metal 搜索任务执行失败：\(details)"
        case .arithmeticOverflow:
            return "搜索索引超出安全范围，已放弃当前随机批次。"
        case .resultVerificationFailed:
            return "GPU 命中结果未通过 CPU 独立校验，已停止且未显示私钥。"
        }
    }
}

private struct MetalWorkProfile {
    let laneCount: Int
    let stepsPerLane: UInt32

    static func profile(for mode: PowerMode) -> MetalWorkProfile {
        switch mode {
        case .eco:
            return MetalWorkProfile(laneCount: 256, stepsPerLane: 1_024)
        case .balanced:
            return MetalWorkProfile(laneCount: 1_024, stepsPerLane: 1_024)
        case .turbo:
            // About eight million candidates per command buffer. This is large
            // enough to amortize submission overhead, but still keeps cancel
            // latency bounded on Apple GPUs.
            return MetalWorkProfile(laneCount: 8_192, stepsPerLane: 1_024)
        }
    }
}

private struct MetalDispatchResult {
    let processed: UInt64
    let threadID: UInt32?
    let offset: UInt32?
    let invalidEpoch: Bool
}

/// All buffers that remain valid for one scalar-walk epoch. Buffers 0 and 1
/// contain public curve points only; no private scalar is copied into Metal.
private final class MetalEpochBuffers {
    let points: MTLBuffer
    let generatorMultiples: MTLBuffer
    let modulus: MTLBuffer
    let remainder: MTLBuffer
    let found: MTLBuffer
    let resultThread: MTLBuffer
    let resultOffset: MTLBuffer
    let steps: MTLBuffer
    let payloadMins: MTLBuffer
    let payloadMaxs: MTLBuffer
    let fullMins: MTLBuffer
    let fullMaxs: MTLBuffer
    let rangeCount: MTLBuffer
    let processed: MTLBuffer
    let invalidEpoch: MTLBuffer
    let suffixProbeTarget: MTLBuffer

    init(
        points: MTLBuffer,
        generatorMultiples: MTLBuffer,
        modulus: MTLBuffer,
        remainder: MTLBuffer,
        found: MTLBuffer,
        resultThread: MTLBuffer,
        resultOffset: MTLBuffer,
        steps: MTLBuffer,
        payloadMins: MTLBuffer,
        payloadMaxs: MTLBuffer,
        fullMins: MTLBuffer,
        fullMaxs: MTLBuffer,
        rangeCount: MTLBuffer,
        processed: MTLBuffer,
        invalidEpoch: MTLBuffer,
        suffixProbeTarget: MTLBuffer
    ) {
        self.points = points
        self.generatorMultiples = generatorMultiples
        self.modulus = modulus
        self.remainder = remainder
        self.found = found
        self.resultThread = resultThread
        self.resultOffset = resultOffset
        self.steps = steps
        self.payloadMins = payloadMins
        self.payloadMaxs = payloadMaxs
        self.fullMins = fullMins
        self.fullMaxs = fullMaxs
        self.rangeCount = rangeCount
        self.processed = processed
        self.invalidEpoch = invalidEpoch
        self.suffixProbeTarget = suffixProbeTarget
    }
}

/// GPU search backend. Secret scalars never enter an MTLBuffer: each epoch owns
/// one CPU-only random `base`, while Metal receives `(base+n)G` and the public
/// fixed table `G, 2G, ... WG`. Lane points advance in-place across dispatches.
actor MetalVanitySearcher: VanitySearching {
    // Must match AFFINE_WINDOW_SIZE in VanitySearch.metal.txt and divide every
    // MetalWorkProfile.stepsPerLane exactly.
    private static let affineWindowSize = 1_024
    private static let threadgroupSize = 32

    private let device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLComputePipelineState?
    private var generatorMultiplesBuffer: MTLBuffer?
    private var activeSearchID: UUID?
    private var currentCommandBuffer: MTLCommandBuffer?

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.device = device
    }

    func search(
        configuration: SearchConfiguration,
        progress: @escaping @Sendable (SearchProgress) -> Void
    ) async throws -> VanitySearchResult {
        guard activeSearchID == nil else { throw VanityEngineError.searchAlreadyRunning }
        guard let device else { throw VanityEngineError.metalUnavailable }

        let matchPlan = try AddressMatchPlan(configuration: configuration)
        let pipeline = try makePipeline(device: device)
        let queue = try makeCommandQueue(device: device)
        let profile = MetalWorkProfile.profile(for: configuration.powerMode)
        let layout = MetalEpochIndexLayout(laneCount: profile.laneCount)
        let searchID = UUID()
        activeSearchID = searchID
        let startedAt = ContinuousClock.now
        var lastProgressAt = startedAt
        var totalAttempts: UInt64 = 0

        defer {
            if activeSearchID == searchID {
                activeSearchID = nil
            }
            currentCommandBuffer = nil
        }

        // A lane span of 2^40 means this outer loop is practically never
        // reached twice, but retaining it makes the index boundary explicit.
        while activeSearchID == searchID {
            try Task.checkCancellation()

            var basePrivateKey = try TronAddress.randomPrivateKey()
            defer {
                secureZero(&basePrivateKey)
            }

            var startPoints = try makeStartPoints(
                base: basePrivateKey,
                layout: layout
            )
            let epochBuffers = try makeEpochBuffers(
                device: device,
                startPoints: &startPoints,
                matchPlan: matchPlan,
                profile: profile
            )
            // Only public points are cleared here; this promptly releases the
            // redundant CPU copy after Metal has made its persistent buffer.
            startPoints.removeAll(keepingCapacity: false)

            var dispatchStart: UInt64 = 0
            var sampleAddress = try makeSampleAddress(
                base: basePrivateKey,
                index: 1
            )

            while layout.canDispatch(from: dispatchStart, count: profile.stepsPerLane),
                  activeSearchID == searchID {
                try Task.checkCancellation()

                let dispatchResult = try await encodeAndWait(
                    queue: queue,
                    pipeline: pipeline,
                    buffers: epochBuffers,
                    profile: profile
                )

                // The actor is re-entrant while awaiting Metal completion, so
                // honour both Task cancellation and an explicit cancel() before
                // publishing a late hit from the completed command buffer.
                try Task.checkCancellation()
                guard activeSearchID == searchID else { throw CancellationError() }

                let attemptsResult = totalAttempts.addingReportingOverflow(dispatchResult.processed)
                guard !attemptsResult.overflow else { throw VanityEngineError.arithmeticOverflow }
                totalAttempts = attemptsResult.partialValue

                let now = ContinuousClock.now
                let elapsed = startedAt.duration(to: now).seconds
                let progressElapsed = lastProgressAt.duration(to: now).seconds
                if progressElapsed >= 0.15 || dispatchResult.threadID != nil {
                    let sampleIndexResult = dispatchStart.addingReportingOverflow(
                        UInt64(max(dispatchResult.offset ?? profile.stepsPerLane, 1))
                    )
                    if !sampleIndexResult.overflow,
                       sampleIndexResult.partialValue > 0,
                       sampleIndexResult.partialValue <= layout.laneSpan {
                        sampleAddress = try makeSampleAddress(
                            base: basePrivateKey,
                            index: sampleIndexResult.partialValue
                        )
                    }
                    progress(SearchProgress(
                        attempts: totalAttempts,
                        speed: Double(totalAttempts) / max(elapsed, 0.001),
                        elapsed: elapsed,
                        sampleAddress: sampleAddress,
                        backendName: device.name
                    ))
                    lastProgressAt = now
                }

                if let threadID = dispatchResult.threadID,
                   let offset = dispatchResult.offset {
                    guard let candidateIndex = layout.candidateIndex(
                        lane: threadID,
                        dispatchStart: dispatchStart,
                        resultOffset: offset
                    ) else {
                        throw VanityEngineError.arithmeticOverflow
                    }

                    var privateKey = try TronAddress.privateKey(
                        atOffset: candidateIndex,
                        from: basePrivateKey
                    )
                    defer { secureZero(&privateKey) }
                    let address = try TronAddress.address(from: privateKey)

                    guard matchPlan.matches(address: address) else {
                        throw VanityEngineError.resultVerificationFailed
                    }

                    return VanitySearchResult(
                        address: address,
                        privateKey: TronAddress.hex(privateKey),
                        attempts: totalAttempts,
                        elapsed: elapsed
                    )
                }

                if dispatchResult.invalidEpoch {
                    // The only affine exceptional case is P.x == Q.x. It is
                    // astronomically unlikely for a random base, but restarting
                    // keeps the batch inverse exact instead of emitting a bad
                    // candidate or silently skipping a scalar.
                    break
                }

                let nextDispatch = dispatchStart.addingReportingOverflow(
                    UInt64(profile.stepsPerLane)
                )
                guard !nextDispatch.overflow else { throw VanityEngineError.arithmeticOverflow }
                dispatchStart = nextDispatch.partialValue
            }
        }

        throw CancellationError()
    }

    func cancel() async {
        activeSearchID = nil
        // Metal command buffers cannot be cancelled after commit. Profile sizes
        // deliberately bound the time until the awaiting search observes this.
    }

    private func makeCommandQueue(device: MTLDevice) throws -> MTLCommandQueue {
        if let commandQueue { return commandQueue }
        guard let queue = device.makeCommandQueue() else {
            throw VanityEngineError.commandQueueUnavailable
        }
        commandQueue = queue
        return queue
    }

    private func makePipeline(device: MTLDevice) throws -> MTLComputePipelineState {
        if let pipeline { return pipeline }
        guard let shaderURL = shaderResourceURL() else {
            throw VanityEngineError.shaderMissing
        }

        let shaderSource: String
        do {
            shaderSource = try String(contentsOf: shaderURL, encoding: .utf8)
        } catch {
            throw VanityEngineError.shaderCompilation(error.localizedDescription)
        }

        let library: MTLLibrary
        do {
            let options = MTLCompileOptions()
            options.fastMathEnabled = false
            library = try device.makeLibrary(source: shaderSource, options: options)
        } catch {
            throw VanityEngineError.shaderCompilation(error.localizedDescription)
        }

        guard let function = library.makeFunction(name: "trx_vanity_search") else {
            throw VanityEngineError.shaderCompilation("找不到 trx_vanity_search 函数。")
        }
        do {
            let result = try device.makeComputePipelineState(function: function)
            pipeline = result
            return result
        } catch {
            throw VanityEngineError.pipelineCreation(error.localizedDescription)
        }
    }

    private func shaderResourceURL() -> URL? {
        let bundle = Bundle.main
        return bundle.url(
            forResource: "VanitySearch.metal",
            withExtension: "txt",
            subdirectory: "Shaders"
        ) ?? bundle.url(forResource: "VanitySearch.metal", withExtension: "txt")
    }

    private func makeStartPoints(
        base: [UInt8],
        layout: MetalEpochIndexLayout
    ) throws -> [GPUAffinePoint] {
        var points = [GPUAffinePoint]()
        points.reserveCapacity(layout.laneCount)

        for lane in 0..<layout.laneCount {
            guard let index = layout.laneStartIndex(for: UInt32(lane)) else {
                throw VanityEngineError.arithmeticOverflow
            }

            let publicKey: [UInt8]
            if index == 0 {
                publicKey = try TronAddress.uncompressedPublicKey(for: base)
            } else {
                var lanePrivateKey = try TronAddress.privateKey(atOffset: index, from: base)
                defer { secureZero(&lanePrivateKey) }
                publicKey = try TronAddress.uncompressedPublicKey(for: lanePrivateKey)
            }
            points.append(GPUAffinePoint(uncompressedPublicKey: publicKey))
        }
        return points
    }

    private func makeSampleAddress(
        base: [UInt8],
        index: UInt64
    ) throws -> String {
        var samplePrivateKey = try TronAddress.privateKey(atOffset: index, from: base)
        defer { secureZero(&samplePrivateKey) }
        return try TronAddress.address(from: samplePrivateKey)
    }

    private func makeGeneratorMultiplesBuffer(device: MTLDevice) throws -> MTLBuffer {
        if let generatorMultiplesBuffer { return generatorMultiplesBuffer }

        // Scalars 1...W are public constants. Derive their points through the
        // same libsecp256k1 truth path used for result verification rather than
        // hard-coding coordinates or doing exceptional point doubling in Metal.
        var scalarOne = [UInt8](repeating: 0, count: 32)
        scalarOne[31] = 1
        var multiples = [GPUAffinePoint]()
        multiples.reserveCapacity(Self.affineWindowSize)
        for multiplier in 1...Self.affineWindowSize {
            var scalar = try TronAddress.privateKey(
                atOffset: UInt64(multiplier - 1),
                from: scalarOne
            )
            defer { secureZero(&scalar) }
            let publicKey = try TronAddress.uncompressedPublicKey(for: scalar)
            multiples.append(GPUAffinePoint(uncompressedPublicKey: publicKey))
        }
        secureZero(&scalarOne)

        guard let buffer = makeBuffer(device: device, array: &multiples) else {
            throw VanityEngineError.bufferAllocation
        }
        generatorMultiplesBuffer = buffer
        return buffer
    }

    private func makeEpochBuffers(
        device: MTLDevice,
        startPoints: inout [GPUAffinePoint],
        matchPlan: AddressMatchPlan,
        profile: MetalWorkProfile
    ) throws -> MetalEpochBuffers {
        let payloadMins = matchPlan.payloadMinimumBytes.isEmpty
            ? [UInt8](repeating: 0, count: 21)
            : matchPlan.payloadMinimumBytes
        let payloadMaxs = matchPlan.payloadMaximumBytes.isEmpty
            ? [UInt8](repeating: 0xff, count: 21)
            : matchPlan.payloadMaximumBytes
        let fullMins = matchPlan.fullMinimumBytes.isEmpty
            ? [UInt8](repeating: 0, count: 25)
            : matchPlan.fullMinimumBytes
        let fullMaxs = matchPlan.fullMaximumBytes.isEmpty
            ? [UInt8](repeating: 0xff, count: 25)
            : matchPlan.fullMaximumBytes
        var processedCounts = [UInt32](repeating: 0, count: profile.laneCount)
        let generatorMultiples = try makeGeneratorMultiplesBuffer(device: device)

        guard let points = makeBuffer(device: device, array: &startPoints),
              let modulus = makeValueBuffer(device: device, value: matchPlan.suffixModulus),
              let remainder = makeValueBuffer(device: device, value: matchPlan.suffixRemainder),
              let found = makeValueBuffer(device: device, value: UInt32(0)),
              let resultThread = makeValueBuffer(device: device, value: UInt32(0)),
              let resultOffset = makeValueBuffer(device: device, value: UInt32(0)),
              let steps = makeValueBuffer(device: device, value: profile.stepsPerLane),
              let payloadMinsBuffer = makeByteBuffer(device: device, bytes: payloadMins),
              let payloadMaxsBuffer = makeByteBuffer(device: device, bytes: payloadMaxs),
              let fullMinsBuffer = makeByteBuffer(device: device, bytes: fullMins),
              let fullMaxsBuffer = makeByteBuffer(device: device, bytes: fullMaxs),
              let rangeCount = makeValueBuffer(
                device: device,
                value: UInt32(matchPlan.prefixRanges.count)
              ),
              let processed = makeBuffer(device: device, array: &processedCounts),
              let invalidEpoch = makeValueBuffer(device: device, value: UInt32(0)),
              let suffixProbeTarget = makeValueBuffer(
                device: device,
                value: matchPlan.suffixProbeTarget
              ) else {
            throw VanityEngineError.bufferAllocation
        }

        return MetalEpochBuffers(
            points: points,
            generatorMultiples: generatorMultiples,
            modulus: modulus,
            remainder: remainder,
            found: found,
            resultThread: resultThread,
            resultOffset: resultOffset,
            steps: steps,
            payloadMins: payloadMinsBuffer,
            payloadMaxs: payloadMaxsBuffer,
            fullMins: fullMinsBuffer,
            fullMaxs: fullMaxsBuffer,
            rangeCount: rangeCount,
            processed: processed,
            invalidEpoch: invalidEpoch,
            suffixProbeTarget: suffixProbeTarget
        )
    }

    private func encodeAndWait(
        queue: MTLCommandQueue,
        pipeline: MTLComputePipelineState,
        buffers: MetalEpochBuffers,
        profile: MetalWorkProfile
    ) async throws -> MetalDispatchResult {
        resetDispatchOutputs(buffers, laneCount: profile.laneCount)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw VanityEngineError.commandEncodingFailed
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffers.points, offset: 0, index: 0)
        encoder.setBuffer(buffers.generatorMultiples, offset: 0, index: 1)
        encoder.setBuffer(buffers.modulus, offset: 0, index: 2)
        encoder.setBuffer(buffers.remainder, offset: 0, index: 3)
        encoder.setBuffer(buffers.found, offset: 0, index: 4)
        encoder.setBuffer(buffers.resultThread, offset: 0, index: 5)
        encoder.setBuffer(buffers.resultOffset, offset: 0, index: 6)
        encoder.setBuffer(buffers.steps, offset: 0, index: 7)
        encoder.setBuffer(buffers.payloadMins, offset: 0, index: 8)
        encoder.setBuffer(buffers.payloadMaxs, offset: 0, index: 9)
        encoder.setBuffer(buffers.fullMins, offset: 0, index: 10)
        encoder.setBuffer(buffers.fullMaxs, offset: 0, index: 11)
        encoder.setBuffer(buffers.rangeCount, offset: 0, index: 12)
        encoder.setBuffer(buffers.processed, offset: 0, index: 13)
        encoder.setBuffer(buffers.invalidEpoch, offset: 0, index: 14)
        encoder.setBuffer(buffers.suffixProbeTarget, offset: 0, index: 15)

        let groupWidth = min(
            pipeline.maxTotalThreadsPerThreadgroup,
            Self.threadgroupSize
        )
        encoder.dispatchThreads(
            MTLSize(width: profile.laneCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: groupWidth, height: 1, depth: 1)
        )
        encoder.endEncoding()

        currentCommandBuffer = commandBuffer
        await commitAndWait(commandBuffer)
        currentCommandBuffer = nil

        guard commandBuffer.status == .completed else {
            throw VanityEngineError.commandFailed(
                commandBuffer.error?.localizedDescription ?? "未知 Metal 错误"
            )
        }

        let found = buffers.found.contents().load(as: UInt32.self)
        let resultThread = buffers.resultThread.contents().load(as: UInt32.self)
        let resultOffset = buffers.resultOffset.contents().load(as: UInt32.self)
        let invalidEpoch = buffers.invalidEpoch.contents().load(as: UInt32.self)
        let processedPointer = buffers.processed.contents().bindMemory(
            to: UInt32.self,
            capacity: profile.laneCount
        )
        let processed = (0..<profile.laneCount).reduce(UInt64(0)) {
            $0 + UInt64(processedPointer[$1])
        }

        return MetalDispatchResult(
            processed: processed,
            threadID: found == 0 ? nil : resultThread,
            offset: found == 0 ? nil : resultOffset,
            invalidEpoch: invalidEpoch != 0
        )
    }

    private func resetDispatchOutputs(_ buffers: MetalEpochBuffers, laneCount: Int) {
        buffers.found.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        buffers.resultThread.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        buffers.resultOffset.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        buffers.invalidEpoch.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        memset(
            buffers.processed.contents(),
            0,
            MemoryLayout<UInt32>.stride * laneCount
        )
    }

    private func commitAndWait(_ commandBuffer: MTLCommandBuffer) async {
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in
                continuation.resume()
            }
            commandBuffer.commit()
        }
    }

    private func makeBuffer<T>(device: MTLDevice, array: inout [T]) -> MTLBuffer? {
        let length = max(MemoryLayout<T>.stride * array.count, 1)
        return array.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return device.makeBuffer(length: length, options: .storageModeShared)
            }
            return device.makeBuffer(bytes: baseAddress, length: length, options: .storageModeShared)
        }
    }

    private func makeValueBuffer<T>(device: MTLDevice, value: T) -> MTLBuffer? {
        var copy = value
        return withUnsafeBytes(of: &copy) { bytes in
            device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            )
        }
    }

    private func makeByteBuffer(device: MTLDevice, bytes: [UInt8]) -> MTLBuffer? {
        bytes.withUnsafeBytes { pointer in
            device.makeBuffer(
                bytes: pointer.baseAddress!,
                length: pointer.count,
                options: .storageModeShared
            )
        }
    }

    private func secureZero(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            trx_secure_zero(buffer.baseAddress, UInt64(buffer.count))
        }
        bytes.removeAll(keepingCapacity: false)
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
