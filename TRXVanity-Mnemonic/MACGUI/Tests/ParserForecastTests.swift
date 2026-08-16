import XCTest
@testable import TRXVanityMonitor

final class ParserForecastTests: XCTestCase {
    func testParsesTwoLineSSHLogin() throws {
        let machine = try SSHLoginParser.parse(
            "ssh -p 23254 root@connect.weste.seetacloud.com\nG4HQ3yQSY+zb"
        )
        XCTAssertEqual(machine.port, 23254)
        XCTAssertEqual(machine.user, "root")
        XCTAssertEqual(machine.host, "connect.weste.seetacloud.com")
        XCTAssertEqual(machine.password, "G4HQ3yQSY+zb")
        XCTAssertNil(machine.privateKey)
        XCTAssertEqual(machine.sshCommand, "ssh -p 23254 root@connect.weste.seetacloud.com")
    }

    func testParsesSSHLoginWithOpenSSHPrivateKey() throws {
        let input = """
        ssh -p 62292 root@171.250.6.198 -L 8080:localhost:8080
        -----BEGIN OPENSSH PRIVATE KEY-----
        dGVzdC1wcml2YXRlLWtleQ==
        -----END OPENSSH PRIVATE KEY-----
        """
        let machine = try SSHLoginParser.parse(input)
        XCTAssertEqual(machine.port, 62_292)
        XCTAssertEqual(machine.host, "171.250.6.198")
        XCTAssertNil(machine.password)
        XCTAssertEqual(
            machine.privateKey,
            "-----BEGIN OPENSSH PRIVATE KEY-----\ndGVzdC1wcml2YXRlLWtleQ==\n-----END OPENSSH PRIVATE KEY-----\n"
        )
    }

    func testRejectsIncompletePrivateKey() {
        XCTAssertThrowsError(
            try SSHLoginParser.parse(
                "ssh -p 22 root@example.com\n-----BEGIN OPENSSH PRIVATE KEY-----\ndata"
            )
        )
    }

    func testRejectsMalformedOrEmptyInput() {
        XCTAssertThrowsError(try SSHLoginParser.parse("ssh root@example.com\npassword"))
        XCTAssertThrowsError(try SSHLoginParser.parse("ssh -p 22 root@example.com"))
        XCTAssertThrowsError(try SSHLoginParser.parse("ssh -p 70000 root@example.com\npassword"))
    }

    func testParsesSSHLoginWithLocalForward() throws {
        let machine = try SSHLoginParser.parse(
            "ssh -p 62292 root@171.250.6.198 -L 8080:localhost:8080\nexample-password"
        )
        XCTAssertEqual(machine.port, 62_292)
        XCTAssertEqual(machine.user, "root")
        XCTAssertEqual(machine.host, "171.250.6.198")
        XCTAssertEqual(machine.localForward, "8080:localhost:8080")
        XCTAssertEqual(
            machine.sshCommand,
            "ssh -p 62292 root@171.250.6.198 -L 8080:localhost:8080"
        )
    }

    func testMaskedEndpointHidesIPv4AndOmitsLocalForward() throws {
        let machine = try SSHLoginParser.parse(
            "ssh -p 62292 root@171.250.6.198 -L 8080:localhost:8080\nexample-password"
        )

        XCTAssertEqual(machine.maskedEndpoint, "root@171.•••.•••.198:62••2")
        XCTAssertFalse(machine.maskedEndpoint.contains("-L"))
        XCTAssertFalse(machine.maskedEndpoint.contains("8080"))
    }

    func testMaskedEndpointHidesLongNumericRunsInUsernameAndDomain() throws {
        let machine = try SSHLoginParser.parse(
            "ssh -p 23254 runner123456@node987654.example2026.com\nexample-password"
        )

        XCTAssertEqual(
            machine.maskedEndpoint,
            "runner12•••6@node98•••4.example20•6.com:23••4"
        )
    }

    func testMaskedEndpointDoesNotMutateConnectionFields() throws {
        let machine = try SSHLoginParser.parse(
            "ssh -p 62292 root123456@171.250.6.198 -L 8080:localhost:8080\nexample-password"
        )

        _ = machine.maskedEndpoint
        XCTAssertEqual(machine.user, "root123456")
        XCTAssertEqual(machine.host, "171.250.6.198")
        XCTAssertEqual(machine.port, 62_292)
        XCTAssertEqual(machine.localForward, "8080:localhost:8080")
        XCTAssertEqual(
            machine.sshCommand,
            "ssh -p 62292 root123456@171.250.6.198 -L 8080:localhost:8080"
        )
    }

    func testForecastUsesCombinedAttemptsAndSpeed() {
        let suffix = FormalSearch.defaultSuffix
        let forecast = FleetForecast(
            attempts: FormalSearch.searchSpace(for: suffix),
            speed: 6_000_000,
            suffix: suffix
        )
        XCTAssertEqual(forecast.workProgress, 1, accuracy: 1e-12)
        XCTAssertEqual(forecast.cumulativeProbability, 1 - exp(-1), accuracy: 1e-12)
        XCTAssertEqual(forecast.until100Seconds, 0)
    }

    func testForecastSearchSpaceFollowsCustomSuffixLength() {
        let six = FleetForecast(attempts: 0, speed: 1, suffix: "666666")
        let seven = FleetForecast(attempts: 0, speed: 1, suffix: FormalSearch.defaultSuffix)
        XCTAssertEqual(six.searchSpace, pow(58, 6), accuracy: 1)
        XCTAssertEqual(seven.searchSpace, pow(58, 7), accuracy: 1)
        XCTAssertGreaterThan(seven.searchSpace, six.searchSpace)
    }

    func testFormatsFractionalISO8601TimestampAsBeijingTime() {
        XCTAssertEqual(
            DisplayFormat.beijingDateTime("2026-08-15T01:02:03.123456+00:00"),
            "2026年08月15日 09:02:03"
        )
    }

    func testFormatsZuluISO8601TimestampAsBeijingTime() {
        XCTAssertEqual(
            DisplayFormat.beijingDateTime("2026-12-31T20:21:22Z"),
            "2027年01月01日 04:21:22"
        )
    }

    func testInvalidBeijingDateTimeUsesPlaceholder() {
        XCTAssertEqual(DisplayFormat.beijingDateTime("not-a-timestamp"), "—")
        XCTAssertEqual(DisplayFormat.beijingDateTime(nil), "—")
    }
}

final class RuntimePackageManifestTests: XCTestCase {
    func testValidatesManagedFileAndManifestDigest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-manifest-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("build", isDirectory: true),
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent("build/example.txt")
        try Data("hello".utf8).write(to: fileURL)
        let manifest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  ./build/example.txt\n"
        try Data(manifest.utf8).write(
            to: directory.appendingPathComponent("runtime-manifest.sha256")
        )

        let package = try RuntimePackageManifest.validate(
            at: directory,
            requiredPaths: ["build/example.txt"]
        )

        XCTAssertEqual(package.entries.map(\.relativePath), ["build/example.txt"])
        XCTAssertEqual(package.manifestSHA256.count, 64)
    }

    func testRejectsFileWhoseDigestDoesNotMatchManifest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-manifest-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("changed".utf8).write(to: directory.appendingPathComponent("example.txt"))
        let manifest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  ./example.txt\n"
        try Data(manifest.utf8).write(
            to: directory.appendingPathComponent("runtime-manifest.sha256")
        )

        XCTAssertThrowsError(
            try RuntimePackageManifest.validate(at: directory, requiredPaths: ["example.txt"])
        )
    }

    func testBundledRuntimeContainsAndValidatesAllRequiredFiles() throws {
        let packageURL = try XCTUnwrap(
            Bundle.main.resourceURL?.appendingPathComponent("RuntimePackage", isDirectory: true)
        )
        let package = try RuntimePackageManifest.validate(at: packageURL)

        XCTAssertEqual(Set(package.entries.map(\.relativePath)), RuntimePackageManifest.requiredPaths)
        XCTAssertEqual(package.entries.count, RuntimePackageManifest.requiredPaths.count)
    }
}

final class RuntimeArchivePortabilityTests: XCTestCase {
    func testPortableArchiveOmitsAppleExtendedAttributes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-tar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = root.appendingPathComponent("payload.bin")
        try Data(repeating: 7, count: 64).write(to: payload)
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-w", "com.apple.provenance", "test", payload.path]
        try xattr.run()
        xattr.waitUntilExit()
        XCTAssertEqual(xattr.terminationStatus, 0, "Could not attach a provenance xattr for the test.")

        let archive = root.appendingPathComponent("payload.tar")
        let command = RuntimePackageManifest.portableCreateArguments(
            archivePath: archive.path,
            directoryPath: root.path,
            members: ["payload.bin"]
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let bytes = try Data(contentsOf: archive)
        let haystack = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(
            haystack.contains("LIBARCHIVE.xattr"),
            "Portable archive still contains LIBARCHIVE.xattr headers."
        )
        XCTAssertFalse(
            haystack.contains("com.apple.provenance"),
            "Portable archive still contains com.apple.provenance."
        )
        XCTAssertFalse(haystack.contains("SCHILY.xattr"))
    }

    func testDefaultMacTarStillEmbedsProvenanceHeaders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("default-tar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = root.appendingPathComponent("payload.bin")
        try Data(repeating: 3, count: 64).write(to: payload)
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-w", "com.apple.provenance", "test", payload.path]
        try xattr.run()
        xattr.waitUntilExit()
        XCTAssertEqual(xattr.terminationStatus, 0)

        let archive = root.appendingPathComponent("payload.tar")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "COPYFILE_DISABLE=1",
            "/usr/bin/tar",
            "-cf", archive.path,
            "-C", root.path,
            "payload.bin"
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let haystack = String(decoding: try Data(contentsOf: archive), as: UTF8.self)
        XCTAssertTrue(
            haystack.contains("LIBARCHIVE.xattr"),
            "The regression fixture no longer reproduces the macOS xattr header."
        )
    }
}

final class SSHLoginBatchParserTests: XCTestCase {
    func testParsesSeveralPasswordEntriesSeparatedByBlankLines() {
        let batch = SSHLoginParser.parseBatch(
            """
            ssh -p 24665 root@connect.westd.seetacloud.com
            firstPassword

            ssh -p 23254 root@connect.weste.seetacloud.com
            secondPassword
            """
        )

        XCTAssertTrue(batch.failures.isEmpty)
        XCTAssertEqual(batch.records.count, 2)
        XCTAssertEqual(batch.records[0].port, 24665)
        XCTAssertEqual(batch.records[0].password, "firstPassword")
        XCTAssertEqual(batch.records[1].host, "connect.weste.seetacloud.com")
        XCTAssertEqual(batch.records[1].password, "secondPassword")
    }

    func testParsesEntriesWithNoBlankLineBetweenThem() {
        let batch = SSHLoginParser.parseBatch(
            """
            ssh -p 22 root@a.example.com
            aaa
            ssh -p 23 root@b.example.com
            bbb
            """
        )

        XCTAssertTrue(batch.failures.isEmpty)
        XCTAssertEqual(batch.records.map(\.host), ["a.example.com", "b.example.com"])
        XCTAssertEqual(batch.records.map(\.password), ["aaa", "bbb"])
    }

    func testKeepsMultiLinePrivateKeyWithItsOwnEntry() {
        let key = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACD1s0m5S1cS0Aw2m1p6bZKfCFvzQeUJnMrz2t6dQwNqTQ
        -----END OPENSSH PRIVATE KEY-----
        """
        let batch = SSHLoginParser.parseBatch(
            """
            ssh -p 62292 root@171.250.6.198 -L 8080:localhost:8080
            \(key)

            ssh -p 22 root@plain.example.com
            plainPassword
            """
        )

        XCTAssertTrue(batch.failures.isEmpty)
        XCTAssertEqual(batch.records.count, 2)
        XCTAssertEqual(batch.records[0].privateKey, key + "\n")
        XCTAssertEqual(batch.records[0].localForward, "8080:localhost:8080")
        XCTAssertNil(batch.records[0].password)
        XCTAssertEqual(batch.records[1].password, "plainPassword")
        XCTAssertNil(batch.records[1].privateKey)
    }

    func testReportsTheLineNumberOfEachBadEntryWhileParsingTheRest() {
        let batch = SSHLoginParser.parseBatch(
            """
            ssh -p 22 root@good.example.com
            goodPassword

            ssh -p 70000 root@badport.example.com
            somePassword

            ssh -p 23 root@missing.example.com
            """
        )

        XCTAssertEqual(batch.records.map(\.host), ["good.example.com"])
        XCTAssertEqual(batch.failures.count, 2)
        XCTAssertEqual(batch.failures[0].lineNumber, 4)
        XCTAssertEqual(batch.failures[0].message, SSHLoginParserError.invalidPort.errorDescription)
        XCTAssertEqual(batch.failures[1].lineNumber, 7)
        XCTAssertEqual(
            batch.failures[1].message,
            SSHLoginParserError.missingCredential.errorDescription
        )
    }

    func testLastEntryWinsWhenTheSameEndpointIsPastedTwice() {
        let batch = SSHLoginParser.parseBatch(
            """
            ssh -p 22 root@dup.example.com
            oldPassword

            ssh -p 22 root@dup.example.com
            newPassword
            """
        )

        XCTAssertTrue(batch.failures.isEmpty)
        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(batch.records[0].password, "newPassword")
        XCTAssertEqual(batch.mergedDuplicates, 1)
    }

    func testTextBeforeTheFirstCommandIsReportedInsteadOfSilentlyDropped() {
        let batch = SSHLoginParser.parseBatch(
            """
            这里是随手粘贴的说明
            ssh -p 22 root@good.example.com
            goodPassword
            """
        )

        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(batch.failures.count, 1)
        XCTAssertEqual(batch.failures[0].lineNumber, 1)
    }

    func testEmptyInputProducesNeitherRecordsNorFailures() {
        XCTAssertTrue(SSHLoginParser.parseBatch("").isEmpty)
        XCTAssertTrue(SSHLoginParser.parseBatch("   \n\n  ").isEmpty)
    }
}

@MainActor
final class FleetStoreBatchAddTests: XCTestCase {
    private func makeStore() -> FleetStore {
        FleetStore(records: []) { _ in UnusedSSHSession() }
    }

    func testAddsEveryPastedMachineAndReportsHowManyWereNew() {
        let store = makeStore()
        store.isAddSheetPresented = true
        let batch = SSHLoginParser.parseBatch(
            """
            ssh -p 22 root@a.example.com
            aaa

            ssh -p 22 root@b.example.com
            bbb
            """
        )

        let outcome = store.add(records: batch.records)

        XCTAssertEqual(outcome.added, 2)
        XCTAssertEqual(outcome.updated, 0)
        XCTAssertEqual(store.machines.map(\.record.host), ["a.example.com", "b.example.com"])
        XCTAssertFalse(store.isAddSheetPresented)
    }

    func testRepastingAnExistingEndpointRefreshesItsCredentialInPlace() throws {
        let store = makeStore()
        store.add(records: SSHLoginParser.parseBatch("ssh -p 22 root@a.example.com\naaa").records)
        let originalID = try XCTUnwrap(store.machines.first?.id)

        let outcome = store.add(
            records: SSHLoginParser.parseBatch(
                """
                ssh -p 22 root@a.example.com
                rotated

                ssh -p 22 root@c.example.com
                ccc
                """
            ).records
        )

        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.updated, 1)
        XCTAssertEqual(store.machines.count, 2)
        XCTAssertEqual(store.machines.first?.id, originalID)
        XCTAssertEqual(store.machines.first?.record.password, "rotated")
    }

    func testAddingNothingLeavesTheSheetOpen() {
        let store = makeStore()
        store.isAddSheetPresented = true

        let outcome = store.add(records: [])

        XCTAssertEqual(outcome, FleetAddOutcome())
        XCTAssertTrue(store.isAddSheetPresented)
        XCTAssertTrue(store.machines.isEmpty)
    }

    func testUpdateTargetSuffixFiltersAndKeepsForecastInSync() {
        let store = makeStore()
        store.updateTargetSuffix("80OIl66")
        XCTAssertEqual(store.targetSuffix, "866")
        XCTAssertEqual(store.forecast.suffix, "866")
        XCTAssertEqual(store.forecast.searchSpace, FormalSearch.searchSpace(for: "866"), accuracy: 1)
        XCTAssertEqual(store.suffixSummary, "目标尾号 866")
    }
}

private actor UnusedSSHSession: SSHSession {
    func prepareAndStart() async throws -> ConnectionPreparation { .secretMissing }
    func uploadBundledRuntime(
        progress: @escaping @Sendable (RuntimeUploadProgress) -> Void
    ) async throws {}
    func startTunnel() async throws {}
    func fetchSnapshot() async throws -> MachineSnapshot {
        throw FakeSSHSessionError.unexpectedCall
    }
    func disconnect() async {}
}

final class FormalSearchValidationTests: XCTestCase {
    func testAcceptsOneToTenBase58Characters() throws {
        XCTAssertEqual(try FormalSearch.normalize("8"), "8")
        XCTAssertEqual(try FormalSearch.normalize(" 88 "), "88")
        XCTAssertEqual(try FormalSearch.normalize("aB9"), "aB9")
        XCTAssertEqual(try FormalSearch.normalize(FormalSearch.defaultSuffix), FormalSearch.defaultSuffix)
        XCTAssertEqual(try FormalSearch.normalize("123456789A"), "123456789A")
    }

    func testRejectsInvalidSuffixes() {
        for value in ["", "0", "O", "I", "l", "88888888888", "88 88", "abc!"] {
            XCTAssertFalse(FormalSearch.isValid(value), value)
        }
    }

    func testFilterInputStripsForbiddenCharactersAndCapsLength() {
        XCTAssertEqual(FormalSearch.filterInput("80OIl88"), "888")
        XCTAssertEqual(FormalSearch.filterInput("123456789Axyz"), "123456789A")
    }

    func testPersistedSuffixRoundTripUsesUserDefaults() {
        let previous = UserDefaults.standard.string(forKey: FormalSearch.defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: FormalSearch.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FormalSearch.defaultsKey)
            }
        }

        FormalSearch.persistedSuffix = "666666"
        XCTAssertEqual(FormalSearch.persistedSuffix, "666666")
        UserDefaults.standard.removeObject(forKey: FormalSearch.defaultsKey)
        XCTAssertEqual(FormalSearch.persistedSuffix, FormalSearch.defaultSuffix)
    }
}

final class FormalSearchTargetTests: XCTestCase {
    private func bundledRuntimeFile(_ relativePath: String) throws -> String {
        let packageURL = try XCTUnwrap(
            Bundle.main.resourceURL?.appendingPathComponent("RuntimePackage", isDirectory: true)
        )
        return try String(
            contentsOf: packageURL.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testDefaultSearchSpaceMatchesSevenCharacterSuffix() {
        XCTAssertEqual(FormalSearch.defaultSuffix.count, 7)
        XCTAssertEqual(
            FormalSearch.searchSpace(for: FormalSearch.defaultSuffix),
            2_207_984_167_552,
            accuracy: 1
        )
    }

    func testForecastCoversHalfOfTheSearchSpaceInTheExpectedTime() throws {
        let forecast = FleetForecast(attempts: 0, speed: 6_000_000, suffix: FormalSearch.defaultSuffix)
        let seconds = try XCTUnwrap(forecast.until50Seconds)
        XCTAssertEqual(seconds, 183_998.68, accuracy: 1)
    }

    func testBundledRunFormalScriptReadsDeployedSuffixFile() throws {
        let script = try bundledRuntimeFile("run-formal.sh")
        XCTAssertTrue(
            script.contains("formal-suffix"),
            "run-formal.sh should read the deployed formal-suffix file."
        )
        XCTAssertTrue(
            script.contains("run --suffix"),
            "run-formal.sh does not launch the formal search."
        )
    }

    func testBundledControllerAndCleanupReadFormalSuffixFile() throws {
        let controller = try bundledRuntimeFile("controller.py")
        let cleanup = try bundledRuntimeFile("scripts/secure_cleanup.py")
        XCTAssertTrue(controller.contains("FORMAL_SUFFIX_FILE"), controller)
        XCTAssertTrue(controller.contains("def load_formal_suffix"), controller)
        XCTAssertTrue(cleanup.contains("FORMAL_SUFFIX_FILE_NAME"), cleanup)
        XCTAssertTrue(cleanup.contains("def load_expected_suffix"), cleanup)
    }
}

final class ProcessStreamerTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testStreamsPayloadLargerThanOnePipeBufferAndReportsProgress() async throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appendingPathComponent("payload.bin")
        let destination = directory.appendingPathComponent("received.bin")

        var payload = Data(count: 0)
        payload.reserveCapacity(4 * 1024 * 1024)
        for index in 0..<(4 * 1024 * 1024) {
            payload.append(UInt8(index % 251))
        }
        try payload.write(to: source)

        let observed = ProgressRecorder()
        let result = try await ProcessStreamer.send(
            fileURL: source,
            executable: "/bin/sh",
            arguments: ["-c", "cat > '\(destination.path)'"],
            environment: nil,
            stallTimeout: 30,
            overallTimeout: 120
        ) { bytesSent in
            observed.record(bytesSent)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(observed.last, Int64(payload.count))
        XCTAssertTrue(observed.isMonotonic, "Progress must never go backwards.")
    }

    func testReportsStderrWhenRemoteCommandFails() async throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appendingPathComponent("payload.bin")
        try Data(repeating: 7, count: 4096).write(to: source)

        let result = try await ProcessStreamer.send(
            fileURL: source,
            executable: "/bin/sh",
            arguments: ["-c", "cat > /dev/null; echo 'refused' >&2; exit 3"],
            environment: nil,
            stallTimeout: 30,
            overallTimeout: 60
        ) { _ in }

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.stderr.contains("refused"), "Unexpected stderr: \(result.stderr)")
    }

    func testAbortsWhenTheReceiverStopsAcceptingData() async throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appendingPathComponent("payload.bin")
        try Data(repeating: 3, count: 8 * 1024 * 1024).write(to: source)

        do {
            _ = try await ProcessStreamer.send(
                fileURL: source,
                executable: "/bin/sh",
                arguments: ["-c", "head -c 1024 > /dev/null; sleep 120"],
                environment: nil,
                stallTimeout: 2,
                overallTimeout: 60
            ) { _ in }
            XCTFail("A receiver that stops reading must abort the transfer.")
        } catch let error as SSHServiceError {
            guard case .uploadStalled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int64] = []

    func record(_ value: Int64) {
        lock.lock()
        samples.append(value)
        lock.unlock()
    }

    var last: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return samples.last
    }

    var isMonotonic: Bool {
        lock.lock()
        defer { lock.unlock() }
        return zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }
    }
}

final class RuntimeUploadCoordinatorTests: XCTestCase {
    func testSecondUploadToTheSameTargetIsRejectedUntilTheFirstEnds() async {
        let coordinator = RuntimeUploadCoordinator()
        let target = "root@example.test:22"

        let first = await coordinator.begin(target)
        let second = await coordinator.begin(target)
        let other = await coordinator.begin("root@example.test:2222")
        await coordinator.end(target)
        let third = await coordinator.begin(target)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertTrue(other)
        XCTAssertTrue(third)
    }
}

@MainActor
final class FleetStoreUploadTests: XCTestCase {
    func testUploadContinuesAfterMissingSessionIsReconnected() async {
        let record = MachineRecord(
            id: UUID(),
            user: "root",
            host: "example.test",
            port: 22,
            password: "password",
            privateKey: nil,
            localForward: nil
        )
        let session = FakeSSHSession(
            preparations: [
                .missingFiles(["build/trxvanity-gpu"]),
                .missingFiles(["build/trxvanity-gpu"]),
                .secretMissing
            ]
        )
        let store = FleetStore(records: [record]) { _ in session }

        await store.connect(record.id)
        await store.stopAll()
        await store.uploadRuntime(for: record.id)

        let state = store.machines.first
        XCTAssertEqual(state?.phase, .secretMissing)
        XCTAssertEqual(state?.isUploading, false)
        let counts = await session.callCounts()
        XCTAssertEqual(counts.prepare, 3)
        XCTAssertEqual(counts.upload, 1)
    }

    func testStaleUploadIntentIsCancelledWhenReconnectFindsPackageReady() async {
        let record = MachineRecord(
            id: UUID(),
            user: "root",
            host: "example.test",
            port: 22,
            password: "password",
            privateKey: nil,
            localForward: nil
        )
        let session = FakeSSHSession(
            preparations: [
                .missingFiles(["build/trxvanity-gpu"]),
                .secretMissing
            ]
        )
        let store = FleetStore(records: [record]) { _ in session }

        await store.connect(record.id)
        await store.stopAll()
        await store.uploadRuntime(for: record.id)

        XCTAssertEqual(store.machines.first?.phase, .secretMissing)
        XCTAssertEqual(store.machines.first?.isUploading, false)
        let counts = await session.callCounts()
        XCTAssertEqual(counts.prepare, 2)
        XCTAssertEqual(counts.upload, 0)
    }

    func testUploadFailureStaysOnMissingFilesInsteadOfAutoReconnect() async {
        let record = MachineRecord(
            id: UUID(),
            user: "root",
            host: "example.test",
            port: 22,
            password: "password",
            privateKey: nil,
            localForward: nil
        )
        let session = FakeSSHSession(
            preparations: [.missingFiles(["runtime-manifest.sha256 (版本不匹配)"])],
            uploadError: SSHServiceError.uploadFailed("formal search is active")
        )
        let store = FleetStore(records: [record]) { _ in session }

        await store.connect(record.id)
        await store.uploadRuntime(for: record.id)

        let state = store.machines.first
        XCTAssertEqual(state?.phase, .missingFiles(["runtime-manifest.sha256 (版本不匹配)"]))
        XCTAssertEqual(state?.isUploading, false)
        XCTAssertEqual(state?.uploadError, "上传运行包失败：formal search is active")
        let counts = await session.callCounts()
        XCTAssertEqual(counts.prepare, 1)
        XCTAssertEqual(counts.upload, 1)
    }
}

private actor FakeSSHSession: SSHSession {
    private var preparations: [ConnectionPreparation]
    private var prepareCalls = 0
    private var uploadCalls = 0
    private let uploadError: Error?

    init(preparations: [ConnectionPreparation], uploadError: Error? = nil) {
        self.preparations = preparations
        self.uploadError = uploadError
    }

    func prepareAndStart() async throws -> ConnectionPreparation {
        prepareCalls += 1
        guard !preparations.isEmpty else { return .secretMissing }
        return preparations.removeFirst()
    }

    func uploadBundledRuntime(
        progress: @escaping @Sendable (RuntimeUploadProgress) -> Void
    ) async throws {
        uploadCalls += 1
        if let uploadError { throw uploadError }
        progress(RuntimeUploadProgress(bytesSent: 512, totalBytes: 1_024))
    }

    func startTunnel() async throws {
        XCTFail("The fake session should not start a tunnel in this test.")
    }

    func fetchSnapshot() async throws -> MachineSnapshot {
        XCTFail("The fake session should not fetch a snapshot in this test.")
        throw FakeSSHSessionError.unexpectedCall
    }

    func disconnect() async {}

    func callCounts() -> (prepare: Int, upload: Int) {
        (prepareCalls, uploadCalls)
    }
}

private enum FakeSSHSessionError: Error {
    case unexpectedCall
}
