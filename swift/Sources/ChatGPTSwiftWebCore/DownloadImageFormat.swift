import Foundation

/// Identifies supported containers without invoking an image decoder or following payload offsets.
public enum DownloadImageFormat {
    public static let maximumHeaderBytes = 4096

    public static func mimeType(header: Data, trailer: Data, byteCount: UInt64) -> String? {
        let bytes = Array(header.prefix(maximumHeaderBytes))
        let tail = Array(trailer.suffix(12))
        guard byteCount >= UInt64(bytes.count) else { return nil }

        func matches(_ offset: Int, _ signature: [UInt8]) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<(offset + signature.count)]) == signature
        }
        func uint32(_ offset: Int, littleEndian: Bool = false) -> UInt64 {
            let field = bytes[offset..<(offset + 4)]
            return (littleEndian ? Array(field.reversed()) : Array(field))
                .reduce(0) { ($0 << 8) | UInt64($1) }
        }

        if bytes.count >= 33, byteCount >= 57,
           matches(0, [137, 80, 78, 71, 13, 10, 26, 10]),
           uint32(8) == 13, matches(12, Array("IHDR".utf8)),
           uint32(16) > 0, uint32(20) > 0,
           tail == [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130] {
            return "image/png"
        }
        if bytes.count >= 4, byteCount >= 6, matches(0, [255, 216, 255]),
           bytes[3] != 0, bytes[3] != 255, tail.suffix(2) == [255, 217] {
            return "image/jpeg"
        }
        if bytes.count >= 13, byteCount >= 35,
           matches(0, Array("GIF87a".utf8)) || matches(0, Array("GIF89a".utf8)),
           bytes[6] != 0 || bytes[7] != 0, bytes[8] != 0 || bytes[9] != 0,
           tail.last == 59 {
            return "image/gif"
        }
        if bytes.count >= 20, byteCount >= 26,
           matches(0, Array("RIFF".utf8)), matches(8, Array("WEBP".utf8)),
           uint32(4, littleEndian: true) == byteCount - 8,
           uint32(16, littleEndian: true) > 0,
           uint32(16, littleEndian: true) <= byteCount - 20 {
            let chunkSize = uint32(16, littleEndian: true)
            if bytes.count >= 30, matches(12, Array("VP8 ".utf8)), chunkSize >= 10,
               matches(23, [157, 1, 42]) {
                return "image/webp"
            }
            if bytes.count >= 25, matches(12, Array("VP8L".utf8)), chunkSize >= 5, bytes[20] == 47 {
                return "image/webp"
            }
            if bytes.count >= 30, matches(12, Array("VP8X".utf8)), chunkSize == 10, byteCount >= 42 {
                return "image/webp"
            }
        }
        guard bytes.count >= 16, matches(4, Array("ftyp".utf8)) else { return nil }
        let boxSize = uint32(0)
        // shortcut: only inspect a leading ftyp box up to 4096 bytes; revisit if real images need larger boxes.
        guard boxSize >= 16, boxSize <= UInt64(bytes.count), boxSize + 8 <= byteCount,
              (boxSize - 16) % 4 == 0 else { return nil }
        let brandOffsets = [8] + Array(stride(from: 16, to: Int(boxSize), by: 4))
        let brands = Set(brandOffsets.map { String(bytes: bytes[$0..<($0 + 4)], encoding: .ascii) ?? "" })
        let isAVIF = !brands.isDisjoint(with: ["avif", "avis"])
        let isHEIC = !brands.isDisjoint(with: ["heic", "heix", "hevc", "hevx"])
        guard isAVIF != isHEIC else { return nil }
        return isAVIF ? "image/avif" : "image/heic"
    }
}
