import Foundation
import XCTest
@testable import ChatGPTSwiftWeb

final class BrowserDataBoundaryIntegrationTests: XCTestCase {
    func testCookieTransferKeepsOnlyOpenAIEcosystemDomains() throws {
        let allowed = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".chatgpt.com",
            .name: "session",
            .path: "/",
            .value: "redacted-test-value",
            .secure: "TRUE",
        ]))
        let unrelated = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".example.com",
            .name: "tracking",
            .path: "/",
            .value: "must-not-transfer",
        ]))

        let transferable = BrowserDataBoundary.transferableCookies([allowed, unrelated])

        XCTAssertEqual(transferable.map(\.domain), [".chatgpt.com"])
        XCTAssertEqual(transferable.map(\.name), ["session"])
    }

    func testSensitiveFileWriterUsesPrivateModeAndAtomicBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTSwiftWeb-DataBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("export.json")
        let payload = Data("{\"safe\":true}".utf8)
        let fileManager = SensitiveCreationFileManager()
        try BrowserDataBoundary.writeSensitiveData(payload, to: destination, fileManager: fileManager)
        XCTAssertTrue(fileManager.checkedCreation)

        XCTAssertEqual(try Data(contentsOf: destination), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    func testSensitiveFileWriterReplacesPublicFileWithPrivateBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.json")
        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        try BrowserDataBoundary.writeSensitiveData(Data("new".utf8), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["export.json"])
    }
}

private final class SensitiveCreationFileManager: FileManager, @unchecked Sendable {
    var checkedCreation = false

    override func createFile(atPath path: String, contents data: Data?,
                             attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        XCTAssertNil(data)
        XCTAssertEqual(attr?[.posixPermissions] as? Int, 0o600)
        let created = super.createFile(atPath: path, contents: data, attributes: attr)
        if created {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data())
            XCTAssertEqual(try attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber, 0o600)
            checkedCreation = true
        }
        return created
    }
}
