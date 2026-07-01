import Foundation
import PDFKit

// MARK: - Document read / scrub-write for txt, docx, pdf
//
// Text is extracted, handed to ScrubEngine, and written back:
//   - plain text  : read/write UTF-8 directly.
//   - .docx       : a ZIP of XML. We unzip (via `Process`/unzip), read the text
//                   in `word/document.xml`, and on write apply the substitution
//                   map back into each paragraph's <w:t> runs, then re-zip —
//                   preserving styles, tables, images, headers/footers.
//   - .pdf        : PDFKit extracts text; PDFs place glyphs absolutely with no
//                   reflow, so re-injection isn't feasible — output is .txt and
//                   the UI states that layout is not preserved.
//
// The docx SPLIT-RUN problem: Word splits one word across several <w:t> nodes.
// We handle it per paragraph — concatenate a paragraph's runs, scrub the whole
// string, put the result in the paragraph's first <w:t>, and blank the rest.
// This preserves paragraph/structure but not intra-paragraph formatting spans.

public enum DocKind: String, Sendable {
    case plainText, docx, pdf
}

public struct DocText: Sendable {
    public let kind: DocKind
    public let text: String        // full extracted text (what gets scrubbed)
    public let sourceURL: URL
    public let ext: String         // original extension (lowercased)
    public let docxWorkDir: URL?   // temp unzip dir for .docx, else nil
}

public enum DocumentIOError: Error, CustomStringConvertible {
    case unsupported(String)
    case unzipFailed(String)
    case zipFailed(String)
    case pdfUnreadable
    case readFailed(String)

    public var description: String {
        switch self {
        case .unsupported(let e): return "Unsupported file type: .\(e)"
        case .unzipFailed(let m): return "Could not read .docx: \(m)"
        case .zipFailed(let m): return "Could not write .docx: \(m)"
        case .pdfUnreadable: return "Could not extract text from the PDF."
        case .readFailed(let m): return "Could not read the file: \(m)"
        }
    }
}

public enum DocumentIO {

    /// Extensions treated as plain UTF-8 text.
    public static let plainTextExts: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "log", "text", "rtf",
        "swift", "py", "js", "ts", "go", "sh", "yaml", "yml", "xml", "html", "c", "cpp", "h",
    ]

    // MARK: Read

    public static func readText(from url: URL) throws -> DocText {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "docx":
            return try readDocx(url)
        case "pdf":
            return try readPDF(url)
        default:
            // Treat known text extensions — and unknown/no extension — as text.
            guard plainTextExts.contains(ext) || ext.isEmpty || !looksBinary(url) else {
                throw DocumentIOError.unsupported(ext)
            }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                return DocText(kind: .plainText, text: text, sourceURL: url, ext: ext.isEmpty ? "txt" : ext, docxWorkDir: nil)
            } catch {
                throw DocumentIOError.readFailed(error.localizedDescription)
            }
        }
    }

    private static func looksBinary(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return true }
        // Heuristic: a NUL byte in the first 8KB → binary.
        return data.prefix(8192).contains(0)
    }

    private static func readPDF(_ url: URL) throws -> DocText {
        guard let doc = PDFDocument(url: url), let s = doc.string, !s.isEmpty else {
            throw DocumentIOError.pdfUnreadable
        }
        return DocText(kind: .pdf, text: s, sourceURL: url, ext: "pdf", docxWorkDir: nil)
    }

    private static func readDocx(_ url: URL) throws -> DocText {
        let work = try unzip(url)
        let docXML = work.appendingPathComponent("word/document.xml")
        guard let xml = try? XMLDocument(contentsOf: docXML, options: [.nodePreserveWhitespace]) else {
            throw DocumentIOError.unzipFailed("missing or invalid word/document.xml")
        }
        let paragraphs = paragraphTexts(in: xml)
        return DocText(kind: .docx, text: paragraphs.joined(separator: "\n"),
                       sourceURL: url, ext: "docx", docxWorkDir: work)
    }

    // MARK: Write (apply the scrub map, produce the output file)

    /// Suggested output URL: `<name>.scrubbed.<ext>` (pdf → `.scrubbed.txt`).
    public static func suggestedOutputURL(for doc: DocText) -> URL {
        let base = doc.sourceURL.deletingPathExtension().lastPathComponent
        let dir = doc.sourceURL.deletingLastPathComponent()
        let outExt = doc.kind == .pdf ? "txt" : doc.ext
        return dir.appendingPathComponent("\(base).scrubbed.\(outExt)")
    }

    /// Write the scrubbed document. `scrubbedFullText` is the already-scrubbed
    /// plaintext (from ScrubEngine) used for txt/pdf; `map` is applied to the
    /// docx XML runs so formatting survives.
    public static func writeScrubbed(doc: DocText, scrubbedFullText: String,
                                     map: SubstitutionMap, to url: URL) throws {
        switch doc.kind {
        case .plainText:
            try scrubbedFullText.write(to: url, atomically: true, encoding: .utf8)
        case .pdf:
            try scrubbedFullText.write(to: url, atomically: true, encoding: .utf8)
        case .docx:
            try writeDocx(doc: doc, map: map, to: url)
        }
    }

    private static func writeDocx(doc: DocText, map: SubstitutionMap, to url: URL) throws {
        guard let work = doc.docxWorkDir else { throw DocumentIOError.zipFailed("no working directory") }
        // Apply the map to document.xml plus any header/footer parts.
        let wordDir = work.appendingPathComponent("word")
        let parts = (try? FileManager.default.contentsOfDirectory(atPath: wordDir.path)) ?? []
        let targets = parts.filter { $0 == "document.xml" || $0.hasPrefix("header") || $0.hasPrefix("footer") }
                           .filter { $0.hasSuffix(".xml") }
        for name in targets {
            let fileURL = wordDir.appendingPathComponent(name)
            guard let xml = try? XMLDocument(contentsOf: fileURL, options: [.nodePreserveWhitespace]) else { continue }
            applyMapToParagraphs(in: xml, map: map)
            let data = xml.xmlData(options: [.nodeCompactEmptyElement])
            try data.write(to: fileURL)
        }
        try rezip(work, to: url)
    }

    // MARK: XML paragraph helpers

    /// Ordered plaintext of each <w:p> paragraph (its <w:t> runs concatenated).
    static func paragraphTexts(in xml: XMLDocument) -> [String] {
        paragraphs(in: xml).map { p in
            textRuns(in: p).map { $0.stringValue ?? "" }.joined()
        }
    }

    /// Scrub each paragraph's concatenated text with the map, then put the whole
    /// scrubbed string in the paragraph's first <w:t> and blank the remaining
    /// runs (the split-run mitigation).
    static func applyMapToParagraphs(in xml: XMLDocument, map: SubstitutionMap) {
        for p in paragraphs(in: xml) {
            let runs = textRuns(in: p)
            guard let first = runs.first else { continue }
            let combined = runs.map { $0.stringValue ?? "" }.joined()
            if combined.isEmpty { continue }
            let scrubbed = Substitution.apply(to: combined, map: map)
            first.stringValue = scrubbed
            for r in runs.dropFirst() { r.stringValue = "" }
        }
    }

    private static func paragraphs(in xml: XMLDocument) -> [XMLElement] {
        guard let root = xml.rootElement() else { return [] }
        var out: [XMLElement] = []
        collect(root, named: "w:p", into: &out)
        return out
    }

    private static func textRuns(in paragraph: XMLElement) -> [XMLElement] {
        var out: [XMLElement] = []
        collect(paragraph, named: "w:t", into: &out)
        return out
    }

    private static func collect(_ element: XMLElement, named: String, into out: inout [XMLElement]) {
        for child in (element.children ?? []) {
            guard let el = child as? XMLElement else { continue }
            if el.name == named {
                out.append(el)
                // w:t never nests w:t; w:p can nest (tables) so keep descending only for w:p.
                if named == "w:p" { collect(el, named: named, into: &out) }
            } else {
                collect(el, named: named, into: &out)
            }
        }
    }

    // MARK: ZIP via /usr/bin/unzip + /usr/bin/zip

    private static func unzip(_ docx: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloak-docx-\(abs(docx.path.hashValue))-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = run("/usr/bin/unzip", ["-o", "-q", docx.path, "-d", dir.path])
        guard r.status == 0 else { throw DocumentIOError.unzipFailed(r.err.isEmpty ? "exit \(r.status)" : r.err) }
        return dir
    }

    private static func rezip(_ workDir: URL, to output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        // zip must run with CWD = workDir so archive paths are relative to the docx root.
        let r = run("/usr/bin/zip", ["-r", "-X", "-q", output.path, "."], cwd: workDir)
        guard r.status == 0 else { throw DocumentIOError.zipFailed(r.err.isEmpty ? "exit \(r.status)" : r.err) }
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String], cwd: URL? = nil)
        -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return (1, "", error.localizedDescription) }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }
}
