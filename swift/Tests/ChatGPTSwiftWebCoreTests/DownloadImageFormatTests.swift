import Foundation
import XCTest
@testable import ChatGPTSwiftWebCore

final class DownloadImageFormatTests: XCTestCase {
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
    )!

    private func identify(_ data: Data) -> String? {
        DownloadImageFormat.mimeType(header: Data(data.prefix(DownloadImageFormat.maximumHeaderBytes)),
                                     trailer: Data(data.suffix(12)), byteCount: UInt64(data.count))
    }

    func testRecognizesContainerHeadersWithoutDecodingPixels() {
        XCTAssertEqual(identify(png), "image/png")
        XCTAssertEqual(identify(Data([255, 216, 255, 224, 0, 0, 255, 217])), "image/jpeg")
        let gif = Data("GIF89a".utf8) + Data([1, 0, 1, 0, 0, 0, 0]) + Data(repeating: 0, count: 21) + Data([59])
        XCTAssertEqual(identify(gif), "image/gif")
        let webp = Data("RIFF".utf8) + Data([18, 0, 0, 0]) + Data("WEBPVP8L".utf8)
            + Data([5, 0, 0, 0, 47, 0, 0, 0, 0, 0])
        XCTAssertEqual(identify(webp), "image/webp")
        XCTAssertEqual(identify(ftyp(major: "avif", compatible: "mif1")), "image/avif")
        XCTAssertEqual(identify(ftyp(major: "mif1", compatible: "heic")), "image/heic")
    }

    func testRejectsExecutablesArchivesSVGAndGenericVideoContainers() {
        for data in [Data("MZ executable".utf8), Data("PK\u{3}\u{4}archive".utf8),
                     Data("<svg></svg>".utf8), ftyp(major: "isom", compatible: "mp42"),
                     ftyp(major: "avif", compatible: "heic")] {
            XCTAssertNil(identify(data))
        }
    }

    func testRejectsTruncatedOrAppendedPNGAndJPEGWithoutTrustingSignaturesAlone() {
        for length in 0..<png.count {
            XCTAssertNil(identify(Data(png.prefix(length))))
        }
        XCTAssertNil(identify(png + Data("PK archive".utf8)))
        XCTAssertNil(identify(Data([255, 216, 255, 224, 0, 0])))
    }

    func testRejectsInvalidContainerLengthsAndBoundsBrandInspection() {
        var webp = Data("RIFF".utf8) + Data([255, 255, 255, 255]) + Data("WEBPVP8L".utf8)
            + Data([5, 0, 0, 0, 47, 0, 0, 0, 0, 0])
        XCTAssertNil(identify(webp))
        webp[4] = 18
        webp[5] = 0
        webp[6] = 0
        webp[7] = 0
        webp[16] = 255
        XCTAssertNil(identify(webp))
        for size: [UInt8] in [[0, 0, 0, 0], [0, 0, 0, 1], [0, 0, 0, 15],
                             [0, 0, 0, 21], [255, 255, 255, 255]] {
            var file = ftyp(major: "avif", compatible: "mif1")
            file.replaceSubrange(0..<4, with: size)
            XCTAssertNil(identify(file))
        }
        let hugeBox = Data([0, 0, 32, 0]) + Data("ftypavif".utf8) + Data(repeating: 0, count: 8192)
        XCTAssertNil(identify(hugeBox))
    }

    func testDoesNotAllocateFromDeclaredImageDimensions() {
        var image = png
        image.replaceSubrange(16..<24, with: Data(repeating: 255, count: 8))
        // Container recognition deliberately does not validate CRCs or decode pixel data.
        XCTAssertEqual(identify(image), "image/png")
    }

    private func ftyp(major: String, compatible: String) -> Data {
        Data([0, 0, 0, 20]) + Data("ftyp".utf8) + Data(major.utf8)
            + Data([0, 0, 0, 0]) + Data(compatible.utf8) + Data([0, 0, 0, 8]) + Data("mdat".utf8)
    }
}
