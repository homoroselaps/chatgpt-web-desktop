import XCTest
@testable import ChatGPTSwiftWebCore

final class DiagnosticRedactorTests: XCTestCase {
    func testRedactsConversationIdentifiersAndQueryValues() throws {
        let url = try XCTUnwrap(URL(string: "https://chatgpt.com/c/private-conversation-id?messageId=secret#turn"))

        XCTAssertEqual(
            DiagnosticRedactor.url(url),
            "https://chatgpt.com/c/<redacted>?<redacted>#<redacted>"
        )
    }

    func testPreservesKnownIndexRouteAndRedactsUnknownPaths() throws {
        let projects = try XCTUnwrap(URL(string: "https://chatgpt.com/projects"))
        let external = try XCTUnwrap(URL(string: "https://example.com/customer/private-ticket"))

        XCTAssertEqual(DiagnosticRedactor.url(projects), "https://chatgpt.com/projects")
        XCTAssertEqual(DiagnosticRedactor.url(external), "https://example.com/<redacted>")
    }

    func testRedactsURLsEmailsAndHomeDirectoryNamesInText() {
        let input = "account@example.com /Users/alice/report https://chatgpt.com/share/private-id?key=secret"
        let redacted = DiagnosticRedactor.text(input)

        XCTAssertEqual(
            redacted,
            "<redacted-email> /Users/<redacted>/report https://chatgpt.com/share/<redacted>?<redacted>"
        )
    }

    func testRedactsURLsContainingParenthesesAndQuerySecrets() {
        let redacted = DiagnosticRedactor.text("failed https://chatgpt.com/c/private(foo)?token=secret")
        XCTAssertEqual(redacted, "failed https://chatgpt.com/c/<redacted>?<redacted>")
    }

    func testProfileAndPageTitleLabelsDoNotExposeCustomValues() {
        XCTAssertEqual(DiagnosticRedactor.profileLabel(isDefault: true), "Default")
        XCTAssertEqual(DiagnosticRedactor.profileLabel(isDefault: false), "Custom Profile (Name Redacted)")
        XCTAssertEqual(DiagnosticRedactor.profileLabel(isDefault: false, persistent: false), "Private")
        XCTAssertEqual(DiagnosticRedactor.pageTitle("ChatGPT"), "ChatGPT")
        XCTAssertEqual(DiagnosticRedactor.pageTitle("Private conversation title"), "<redacted>")
    }
}
