import XCTest
@testable import Codenotch

/// `kiro-cli chat --no-interactive /usage` is asked of the binary, because
/// the CLI owns the login and this app does not. These pin how that binary
/// is found, and that a wedged spawn cannot hang a refresh. They never
/// spawn the real CLI: that would need a login to be deterministic.
final class KiroCLITests: XCTestCase {

    func testItHonorsKIRO_CLI_PATH() throws {
        let fake = try makeExecutable("kiro-cli")

        XCTAssertEqual(
            KiroCLI.locateBinary(environment: ["KIRO_CLI_PATH": fake.path])?.path,
            fake.path
        )
    }

    /// Nil is the signal that Kiro is not installed, so a machine without
    /// the CLI keeps working instead of failing a spawn.
    func testAMissingBinaryReturnsNil() throws {
        let missing = try makeTemp().appendingPathComponent("no-such-kiro-cli")

        XCTAssertNil(KiroCLI.locateBinary(environment: ["KIRO_CLI_PATH": missing.path]))
    }

    func testItFindsKiroWhereTheInstallerPutsIt() throws {
        let home = try makeTemp()
        let binary = home.appendingPathComponent(".local/bin/kiro-cli")
        try makeExecutable(at: binary)

        XCTAssertEqual(
            KiroCLI.locateBinary(environment: ["HOME": home.path, "PATH": ""])?.path,
            binary.path
        )
    }

    func testItAsksInNonInteractiveChat() {
        XCTAssertEqual(KiroCLI.arguments, ["chat", "--no-interactive", "/usage"])
        XCTAssertEqual(KiroCLI.timeout, 20)
    }

    /// `isExecutableFile` is true for directories; treating one as kiro-cli
    /// would spawn a path that cannot run.
    func testADirectoryIsNotABinary() throws {
        let dir = try makeTemp()
        XCTAssertNil(KiroCLI.locateBinary(environment: ["KIRO_CLI_PATH": dir.path]))
    }

    /// Relative overrides resolve against cwd. That is PATH injection.
    func testARelativeKIRO_CLI_PATHIsIgnored() {
        XCTAssertNil(KiroCLI.locateBinary(environment: ["KIRO_CLI_PATH": "kiro-cli"]))
        XCTAssertNil(KiroCLI.locateBinary(environment: ["KIRO_CLI_PATH": "./kiro-cli"]))
        XCTAssertNil(KiroCLI.locateBinary(environment: ["KIRO_CLI_PATH": "../kiro-cli"]))
    }

    func testItWalksAnAbsolutePATHEntry() throws {
        let home = try makeTemp()
        let binDir = try makeTemp()
        let binary = binDir.appendingPathComponent("kiro-cli")
        try makeExecutable(at: binary)

        let found = KiroCLI.locateBinary(environment: [
            "HOME": home.path,
            "PATH": binDir.path,
            "KIRO_CLI_PATH": ""
        ])
        if found?.path == "/opt/homebrew/bin/kiro-cli"
            || found?.path == "/usr/local/bin/kiro-cli" {
            throw XCTSkip("machine already has kiro-cli in a well-known location")
        }
        XCTAssertEqual(found?.path, binary.path)
    }

    func testRelativePATHEntriesAreIgnored() throws {
        let home = try makeTemp()
        let found = KiroCLI.locateBinary(environment: [
            "HOME": home.path,
            "PATH": ".:bin"
        ])
        XCTAssertNotEqual(found?.path, "kiro-cli")
        XCTAssertFalse(found?.path.hasPrefix("./") == true)
    }

    func testAWedgedProcessTimesOut() throws {
        let url = try makeTemp().appendingPathComponent("kiro-cli")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let started = Date()
        XCTAssertThrowsError(try KiroCLI.run(binary: url, timeout: 0.4)) { error in
            guard case UsageProviderError.timedOut = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testAQuietProcessReturnsItsStdout() throws {
        let url = try makeTemp().appendingPathComponent("kiro-cli")
        try "#!/bin/sh\necho usage-ok\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let text = try KiroCLI.run(binary: url, timeout: 2)
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "usage-ok")
    }

    // MARK: - Fixtures

    private func makeTemp() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KiroCLITests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeExecutable(_ name: String) throws -> URL {
        let url = try makeTemp().appendingPathComponent(name)
        try makeExecutable(at: url)
        return url
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o755])
    }
}
