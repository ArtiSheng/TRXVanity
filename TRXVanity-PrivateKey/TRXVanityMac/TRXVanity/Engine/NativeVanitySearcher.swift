import Foundation

/// Selects Metal first and only falls back to native CPU workers when the GPU
/// or runtime Metal compiler is genuinely unavailable.
actor NativeVanitySearcher: VanitySearching {
    private let metal: MetalVanitySearcher
    private let cpu: CPUVanitySearcher

    init() {
        metal = MetalVanitySearcher()
        cpu = CPUVanitySearcher()
    }

    func search(
        configuration: SearchConfiguration,
        progress: @escaping @Sendable (SearchProgress) -> Void
    ) async throws -> VanitySearchResult {
        do {
            return try await metal.search(configuration: configuration, progress: progress)
        } catch let error as VanityEngineError {
            switch error {
            case .metalUnavailable, .shaderMissing, .shaderCompilation, .pipelineCreation,
                 .commandQueueUnavailable:
                return try await cpu.search(configuration: configuration, progress: progress)
            default:
                throw error
            }
        }
    }

    func cancel() async {
        await metal.cancel()
        await cpu.cancel()
    }
}

private actor CPUAttemptCounter {
    private(set) var attempts: UInt64 = 0
    private let startedAt = ContinuousClock.now

    func add(_ amount: UInt64) -> (attempts: UInt64, elapsed: TimeInterval) {
        attempts &+= amount
        return (attempts, startedAt.duration(to: .now).timeInterval)
    }
}

/// Correctness-oriented fallback. It uses multiple native tasks and the same
/// libsecp256k1/Keccak/Base58 CPU truth path used to verify Metal hits.
actor CPUVanitySearcher: VanitySearching {
    private var activeSearchID: UUID?

    func search(
        configuration: SearchConfiguration,
        progress: @escaping @Sendable (SearchProgress) -> Void
    ) async throws -> VanitySearchResult {
        guard activeSearchID == nil else { throw VanityEngineError.searchAlreadyRunning }
        let matchPlan = try AddressMatchPlan(configuration: configuration)
        let searchID = UUID()
        activeSearchID = searchID
        let counter = CPUAttemptCounter()
        let workerCount = Self.workerCount(for: configuration.powerMode)

        defer {
            if activeSearchID == searchID { activeSearchID = nil }
        }

        return try await withThrowingTaskGroup(of: VanitySearchResult.self) { group in
            for _ in 0..<workerCount {
                group.addTask { [weak self] in
                    var basePrivateKey = try TronAddress.randomPrivateKey()
                    defer { Self.secureZero(&basePrivateKey) }
                    var offset: UInt64 = 0
                    var unreported: UInt64 = 0

                    while true {
                        try Task.checkCancellation()
                        guard let self, await self.isActive(searchID) else {
                            throw CancellationError()
                        }

                        var privateKey = try TronAddress.privateKey(
                            atOffset: offset,
                            from: basePrivateKey
                        )
                        let address = try TronAddress.address(from: privateKey)
                        unreported += 1

                        if matchPlan.matches(address: address) {
                            let snapshot = await counter.add(unreported)
                            let result = VanitySearchResult(
                                address: address,
                                privateKey: TronAddress.hex(privateKey),
                                attempts: snapshot.attempts,
                                elapsed: snapshot.elapsed
                            )
                            Self.secureZero(&privateKey)
                            return result
                        }
                        Self.secureZero(&privateKey)

                        offset = offset.addingReportingOverflow(1).partialValue
                        if offset == 0 { throw VanityEngineError.arithmeticOverflow }

                        if unreported >= 128 {
                            let snapshot = await counter.add(unreported)
                            unreported = 0
                            progress(SearchProgress(
                                attempts: snapshot.attempts,
                                speed: Double(snapshot.attempts) / max(snapshot.elapsed, 0.001),
                                elapsed: snapshot.elapsed,
                                sampleAddress: address,
                                backendName: "CPU 并发后备（\(workerCount) 核）"
                            ))
                        }
                    }
                }
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            activeSearchID = nil
            return result
        }
    }

    func cancel() async {
        activeSearchID = nil
    }

    private func isActive(_ searchID: UUID) -> Bool {
        activeSearchID == searchID
    }

    private static func workerCount(for mode: PowerMode) -> Int {
        let available = max(1, ProcessInfo.processInfo.activeProcessorCount)
        switch mode {
        case .eco:
            return max(1, min(2, available))
        case .balanced:
            return max(1, available - 2)
        case .turbo:
            return available
        }
    }

    private static func secureZero(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            trx_secure_zero(buffer.baseAddress, UInt64(buffer.count))
        }
        bytes.removeAll(keepingCapacity: false)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
