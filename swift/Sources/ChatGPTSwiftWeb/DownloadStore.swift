import ChatGPTSwiftWebCore
import CoreServices
import Darwin
import Foundation

enum DownloadStore {
    static func downloadsDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
    }

    static func destinationURL(
        suggestedFilename: String,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let targetDirectory = directory ?? downloadsDirectory(fileManager: fileManager)
        return DownloadFilename.uniqueDownloadURL(
            suggestedFilename: suggestedFilename,
            in: targetDirectory,
            fileExists: { fileManager.fileExists(atPath: $0) }
        )
    }

    @discardableResult
    static func saveImage(
        _ data: Data,
        suggestedFilename: String,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let targetDirectory = directory ?? downloadsDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let temporaryURL = targetDirectory.appendingPathComponent(".image-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try quarantine(temporaryURL)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        return try moveTemporaryImage(temporaryURL, suggestedFilename: suggestedFilename,
                                      directory: targetDirectory, fileManager: fileManager)
    }

    @discardableResult
    static func moveTemporaryImage(
        _ temporaryFileURL: URL,
        suggestedFilename: String,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let targetDirectory = directory ?? downloadsDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let handle = try FileHandle(forReadingFrom: temporaryFileURL)
        defer { try? handle.close() }
        let byteCount = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: DownloadImageFormat.maximumHeaderBytes) ?? Data()
        try handle.seek(toOffset: byteCount > 12 ? byteCount - 12 : 0)
        let trailer = try handle.read(upToCount: 12) ?? Data()
        guard let mimeType = DownloadImageFormat.mimeType(header: header, trailer: trailer, byteCount: byteCount) else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "Unrecognized or incomplete image container"])
        }
        try quarantine(temporaryFileURL)
        let filename = DownloadFilename.imageFilename(suggestedFilename: suggestedFilename,
                                                      fallback: "chatgpt-image", mimeType: mimeType)
        let destination = destinationURL(
            suggestedFilename: filename,
            directory: targetDirectory,
            fileManager: fileManager
        )
        try fileManager.moveItem(at: temporaryFileURL, to: destination)
        return destination
    }

    static func quarantine(_ url: URL) throws {
        var fileURL = url
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
        try fileURL.setResourceValues(values)
        guard getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Could not quarantine the download"])
        }
    }
}
