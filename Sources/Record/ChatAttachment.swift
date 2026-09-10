import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
@preconcurrency import Vision

/// One document (or image) attached to the current Kiro conversation.
/// Text is extracted eagerly at attach time so sending the prompt is cheap.
struct ChatAttachment: Identifiable, Equatable {
    enum Payload: Equatable {
        case text(String)
        case image(Data)      // JPEG data
    }

    let id = UUID()
    let filename: String
    let byteSize: Int
    let payload: Payload

    var isImage: Bool {
        if case .image = payload { return true }
        return false
    }

    var displayDetail: String {
        switch payload {
        case .text(let text):
            let words = text.split(whereSeparator: \.isWhitespace).count
            return "\(words.formatted()) words · \(byteSize.formatted(.byteCount(style: .file)))"
        case .image:
            return "image · \(byteSize.formatted(.byteCount(style: .file)))"
        }
    }
}

enum AttachmentImporter {
    enum ImportError: LocalizedError {
        case tooLarge(URL)
        case unreadable(URL)
        case unsupported(URL)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let url): "\(url.lastPathComponent) is larger than 20 MB and won't be attached."
            case .unreadable(let url): "Couldn't read \(url.lastPathComponent)."
            case .unsupported(let url): "Record doesn't know how to read \(url.lastPathComponent)."
            }
        }
    }

    private static let maxBytes = 20 * 1_024 * 1_024

    static func makeAttachment(from url: URL) throws -> ChatAttachment {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes[.size] as? Int ?? 0
        guard size <= maxBytes else { throw ImportError.tooLarge(url) }
        let ext = url.pathExtension.lowercased()

        if imageExtensions.contains(ext) {
            let data = try Data(contentsOf: url)
            let jpeg = compressToJPEG(data) ?? data
            return ChatAttachment(filename: url.lastPathComponent, byteSize: jpeg.count, payload: .image(jpeg))
        }

        if ext == "pdf" {
            return try importPDF(url, size: size)
        }
        if ext == "rtf" || ext == "rtfd" {
            return try importRTF(url, size: size)
        }
        if ext == "docx" {
            return try importDocx(url, size: size)
        }

        // Plain-text fall-through covers txt, md, code, csv, json, yaml, log, etc.
        if let text = tryReadText(url) {
            return ChatAttachment(filename: url.lastPathComponent, byteSize: size, payload: .text(text))
        }

        throw ImportError.unsupported(url)
    }

    // MARK: - Type helpers

    static let acceptedContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .utf8PlainText, .rtf, .pdf, .png, .jpeg, .tiff, .gif, .webP, .bmp]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let json = UTType.json as UTType? { types.append(json) }
        if let csv = UTType.commaSeparatedText as UTType? { types.append(csv) }
        // Add source-code and log variants where they exist.
        for ext in ["swift","py","js","ts","tsx","java","kt","c","cpp","h","rb","go","rs","yaml","yml","toml","html","xml","log"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    private static let imageExtensions: Set<String> = [
        "png","jpg","jpeg","gif","bmp","webp","tif","tiff","heic","heif"
    ]

    // MARK: - Extractors

    private static func tryReadText(_ url: URL) -> String? {
        for encoding in [String.Encoding.utf8, .utf16, .isoLatin1] {
            if let text = try? String(contentsOf: url, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    private static func importPDF(_ url: URL, size: Int) throws -> ChatAttachment {
        guard let doc = PDFDocument(url: url) else { throw ImportError.unreadable(url) }
        var text = ""
        for index in 0..<doc.pageCount {
            if let page = doc.page(at: index), let s = page.string, !s.isEmpty {
                text += s
                text += "\n\n"
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.unreadable(url) }
        return ChatAttachment(filename: url.lastPathComponent, byteSize: size, payload: .text(trimmed))
    }

    private static func importRTF(_ url: URL, size: Int) throws -> ChatAttachment {
        let attributed = try NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportError.unreadable(url) }
        return ChatAttachment(filename: url.lastPathComponent, byteSize: size, payload: .text(text))
    }

    private static func importDocx(_ url: URL, size: Int) throws -> ChatAttachment {
        // 1. List the archive so we can find whichever XML file actually
        //    holds the body — Word for Mac / Google Docs exports don't
        //    always use `word/document.xml`.
        let entries = try listZipEntries(at: url)
        let bodyCandidates = [
            "word/document.xml",       // stock OOXML
            "word/document2.xml",      // some Word 365 exports
            "word/main.xml",           // rare
            "content.xml"              // ODT lookalikes that renamed themselves
        ]
        let bodyPath = bodyCandidates.first(where: { entries.contains($0) })
            ?? entries.first(where: { $0.hasPrefix("word/document") && $0.hasSuffix(".xml") })
            ?? entries.first(where: { $0.hasPrefix("word/") && $0.hasSuffix(".xml") })

        guard let bodyPath else { throw ImportError.unreadable(url) }

        // 2. Extract the body. Give unzip an empty stdin so it can never
        //    block waiting on password input.
        let xmlData = try readZipEntry(at: url, entry: bodyPath, timeout: 30)
        guard let xml = String(data: xmlData, encoding: .utf8), !xml.isEmpty else {
            throw ImportError.unreadable(url)
        }
        let text = stripDocxXML(xml).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportError.unreadable(url) }
        return ChatAttachment(filename: url.lastPathComponent, byteSize: size, payload: .text(text))
    }

    private static func listZipEntries(at url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", url.path] // -Z1 = simple name list
        let out = Pipe(), err = Pipe()
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = out
        process.standardError = err

        let collector = DataCollector()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            else { collector.append(chunk) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        try process.run()
        let deadline = Date.now.addingTimeInterval(10)
        while process.isRunning && Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            throw ImportError.unreadable(url)
        }
        Thread.sleep(forTimeInterval: 0.05)
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0 else { throw ImportError.unreadable(url) }
        guard let text = String(data: collector.data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func readZipEntry(at url: URL, entry: String, timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -p pipes to stdout; -P "" provides an empty password so encrypted
        // archives fail fast instead of blocking; passing /dev/null on stdin
        // guarantees unzip can never wait on stdin input.
        process.arguments = ["-p", "-P", "", url.path, entry]
        let out = Pipe(), err = Pipe()
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = out
        process.standardError = err

        // Drain stdout concurrently so unzip can't deadlock filling the pipe
        // buffer (~64 KB on macOS); larger documents easily exceed that.
        let collector = DataCollector()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.append(chunk)
            }
        }
        // Also drain stderr so unzip can't wedge on a chatty error path.
        err.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        try process.run()
        let deadline = Date.now.addingTimeInterval(timeout)
        while process.isRunning && Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            throw ImportError.unreadable(url)
        }

        // Give the readability handler a moment to drain any final bytes.
        Thread.sleep(forTimeInterval: 0.05)
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else { throw ImportError.unreadable(url) }
        return collector.data
    }

    /// Cheap-and-cheerful docx text extraction: replace paragraph and line
    /// breaks with newlines, strip everything else that looks like XML.
    private static func stripDocxXML(_ xml: String) -> String {
        var text = xml
        text = text.replacingOccurrences(of: "</w:p>", with: "\n\n")
        text = text.replacingOccurrences(of: "<w:br/>", with: "\n")
        text = text.replacingOccurrences(of: "<w:tab/>", with: "\t")
        // Strip every remaining tag.
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode a few common entities.
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        return text
    }

    private static func compressToJPEG(_ data: Data) -> Data? {
        guard let image = NSBitmapImageRep(data: data) else { return nil }
        return image.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }
}

extension ChatAttachment {
    /// Renders the attachment as a text block that Kiro can read inline.
    /// Images become a placeholder + are attached separately via ACP image blocks.
    var promptRepresentation: String {
        switch payload {
        case .text(let text):
            return "--- \(filename) ---\n\(text)\n--- end \(filename) ---"
        case .image:
            return "[Image attached: \(filename)]"
        }
    }

    var jpegPayload: Data? {
        if case .image(let data) = payload { return data }
        return nil
    }
}


/// Lock-guarded byte accumulator used to drain a Pipe from a Foundation
/// readabilityHandler thread while the parent actor waits for the child
/// process to exit. Prevents pipe-buffer deadlocks when unzip's output
/// exceeds the ~64 KB macOS pipe buffer.
final class DataCollector: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
