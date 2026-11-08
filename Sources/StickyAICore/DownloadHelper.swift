import Foundation
import UniformTypeIdentifiers

public enum DownloadHelper {
    private static let explicitMimeExtensions: [String: String] = [
        "image/jpeg": "jpg",
        "image/jpg": "jpg",
        "image/png": "png",
        "image/webp": "webp",
        "image/gif": "gif",
        "image/svg+xml": "svg",
        "image/heic": "heic",
        "image/heif": "heif",
        "image/avif": "avif",
        "image/bmp": "bmp",
        "image/tiff": "tiff",
        "application/pdf": "pdf",
        "text/plain": "txt",
        "text/markdown": "md",
        "text/csv": "csv",
        "text/html": "html",
        "application/json": "json",
        "application/zip": "zip",
        "video/mp4": "mp4",
        "video/quicktime": "mov",
        "video/webm": "webm",
        "audio/mpeg": "mp3",
        "audio/mp4": "m4a",
        "audio/wav": "wav"
    ]

    /// Resolves the target Downloads folder, defaulting to the user's `~/Downloads` directory.
    public static func defaultDownloadsDirectory(override: URL? = nil) -> URL {
        if let override {
            return override
        }
        if let envPath = ProcessInfo.processInfo.environment["STICKY_AI_DOWNLOADS_DIR"],
           !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (envPath as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let systemDownloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return systemDownloads
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Returns true when an HTTP `Content-Disposition` header indicates an `attachment` download.
    public static func isAttachmentContentDisposition(_ headerValue: String?) -> Bool {
        guard let raw = headerValue else { return false }
        let dispositionType = raw
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return dispositionType == "attachment"
    }

    /// Determines whether a navigation response should be converted into a file download.
    public static func shouldDownloadResponse(_ response: URLResponse, canShowMIMEType: Bool) -> Bool {
        if !canShowMIMEType {
            return true
        }
        if let httpResponse = response as? HTTPURLResponse {
            let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition")
            if isAttachmentContentDisposition(disposition) {
                return true
            }
        }
        return false
    }

    /// Infers a file extension (without leading dot) from a MIME type if known.
    public static func inferredFileExtension(forMIMEType mimeType: String?) -> String? {
        guard let raw = mimeType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty,
              raw != "application/octet-stream" else {
            return nil
        }

        if let mapped = explicitMimeExtensions[raw] {
            return mapped
        }
        if let utType = UTType(mimeType: raw),
           let ext = utType.preferredFilenameExtension,
           !ext.isEmpty {
            return ext
        }
        return nil
    }

    /// Sanitizes a suggested download filename for safe storage in `~/Downloads` and appends
    /// an inferred extension when none is present.
    public static func sanitizeFilename(_ suggestedFilename: String?, response: URLResponse? = nil) -> String {
        let candidates = [suggestedFilename, response?.suggestedFilename]
        var chosen = ""
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.lowercased() != "unknown" {
                chosen = trimmed
                break
            }
        }

        let components = chosen.components(separatedBy: CharacterSet(charactersIn: "/\\"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }

        var cleaned = components.last ?? ""

        cleaned = String(cleaned.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == ":" {
                return "_"
            }
            return Character(scalar)
        })

        if cleaned.hasPrefix(".") {
            let withoutLeadingDots = String(cleaned.drop(while: { $0 == "." }))
            if !withoutLeadingDots.isEmpty && !withoutLeadingDots.contains(".") && withoutLeadingDots.count <= 6 {
                cleaned = "download.\(withoutLeadingDots)"
            } else {
                cleaned = withoutLeadingDots
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty {
            cleaned = "download"
        }

        let currentExt = (cleaned as NSString).pathExtension
        if currentExt.isEmpty, let inferredExt = inferredFileExtension(forMIMEType: response?.mimeType) {
            cleaned = "\(cleaned).\(inferredExt)"
        }

        return cleaned
    }

    /// Resolves a unique, non-existent file URL inside `directoryURL`, appending ` (1)`, ` (2)`, etc.
    /// when an existing file or active download already uses the same name.
    public static func resolveUniqueDestinationURL(
        in directoryURL: URL,
        suggestedFilename: String?,
        response: URLResponse? = nil,
        reservedURLs: Set<URL> = []
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let baseDir = directoryURL.standardizedFileURL

        let cleanName = sanitizeFilename(suggestedFilename, response: response)
        let nsName = cleanName as NSString
        let ext = nsName.pathExtension
        let rawStem = ext.isEmpty ? cleanName : nsName.deletingPathExtension
        let stem = rawStem.isEmpty ? "download" : rawStem

        let normalizedReserved = Set(reservedURLs.map(\.standardizedFileURL))

        func isTaken(_ url: URL) -> Bool {
            let std = url.standardizedFileURL
            if normalizedReserved.contains(std) {
                return true
            }
            if fileManager.fileExists(atPath: std.path) {
                return true
            }
            if (try? fileManager.attributesOfItem(atPath: std.path)) != nil {
                return true
            }
            return false
        }

        let firstCandidate = baseDir.appendingPathComponent(cleanName, isDirectory: false).standardizedFileURL
        if !isTaken(firstCandidate) {
            return firstCandidate
        }

        var index = 1
        while true {
            let numberedName = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let candidate = baseDir.appendingPathComponent(numberedName, isDirectory: false).standardizedFileURL
            if !isTaken(candidate) {
                return candidate
            }
            index += 1
        }
    }
}

