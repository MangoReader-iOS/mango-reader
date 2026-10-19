import CryptoKit
import Foundation
import MankoDomain
import ReadiumZIPFoundation

public enum MankoExtensionEPUBError: Error, Equatable, Sendable, LocalizedError {
    case invalidXHTML
    case contentTooLarge
    case archive(String)

    public var errorDescription: String? {
        switch self {
        case .invalidXHTML: "The extension returned unsafe or malformed XHTML."
        case .contentTooLarge: "The extension chapter exceeded the 2 MiB text limit."
        case let .archive(message): "Manko could not create the EPUB: \(message)"
        }
    }
}

public struct MankoExtensionEPUBBuilder: Sendable {
    public var destinationDirectory: URL
    public var retainedPublicationLimit: Int

    public init(
        destinationDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "MankoExtensionPublications", directoryHint: .isDirectory),
        retainedPublicationLimit: Int = 64
    ) {
        self.destinationDirectory = destinationDirectory
        self.retainedPublicationLimit = max(1, retainedPublicationLimit)
    }

    /// Upgrade a former disposable generated EPUB without downloading its
    /// volume again. Explicit downloads continue to open their original file.
    @concurrent
    public static func legacyContent(at url: URL, workID: String, volumeID: String) async throws -> MankoPublicationContent? {
        let archive = try await Archive(url: url, accessMode: .read)
        let entries = try await archive.entries()
        guard !entries.contains(where: { $0.path == GeneratedPublicationSections.resourcePath }),
              let entry = entries.first(where: { $0.path == "OEBPS/content.xhtml" }),
              entry.uncompressedSize <= 2 * 1_024 * 1_024 else { return nil }
        let collector = EPUBLegacyContentCollector()
        _ = try await archive.extract(entry) { data in
            try Task.checkCancellation()
            try await collector.append(data)
        }
        let data = await collector.data
        guard let text = String(data: data, encoding: .utf8) else { throw MankoExtensionEPUBError.invalidXHTML }
        return MankoPublicationContent(id: volumeID, workId: workID, mimeType: "application/xhtml+xml", text: text)
    }

    @concurrent
    public static func sectionMetadata(at url: URL) async throws -> GeneratedPublicationSections? {
        let archive = try await Archive(url: url, accessMode: .read)
        let entries = try await archive.entries()
        guard let entry = entries.first(where: { $0.path == GeneratedPublicationSections.resourcePath }),
              entry.uncompressedSize <= 4 * 1_024 * 1_024 else { return nil }
        let collector = EPUBLegacyContentCollector()
        _ = try await archive.extract(entry) { data in try Task.checkCancellation(); try await collector.append(data) }
        return try JSONDecoder().decode(GeneratedPublicationSections.self, from: await collector.data)
    }

    /// Generated publications are disposable and their file URL is not always
    /// persisted on the installment. Recover only this exact volume's old map.
    @concurrent
    public func cachedSectionMetadata(workID: String, volumeID: String, sourceNamespace: String) async throws -> GeneratedPublicationSections? {
        let identifier = "urn:manko:extension:\(Self.sha256(Data("\(sourceNamespace)|\(workID)|\(volumeID)".utf8)))"
        let urls = (try? FileManager.default.contentsOfDirectory(at: destinationDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidates = urls.filter { $0.pathExtension == "epub" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.prefix(retainedPublicationLimit)
        for url in candidates {
            try Task.checkCancellation()
            guard let archive = try? await Archive(url: url, accessMode: .read),
                  let entries = try? await archive.entries(),
                  let opf = entries.first(where: { $0.path == "OEBPS/content.opf" }), opf.uncompressedSize <= 64 * 1_024 else { continue }
            let collector = EPUBLegacyContentCollector()
            _ = try await archive.extract(opf) { data in try Task.checkCancellation(); try await collector.append(data) }
            let data = await collector.data
            guard String(data: data, encoding: .utf8)?.contains("<dc:identifier id=\"pub-id\">\(identifier)</dc:identifier>") == true else { continue }
            return try await Self.sectionMetadata(at: url)
        }
        return nil
    }

    @concurrent
    public func build(
        content: MankoPublicationContent,
        title: String,
        sourceNamespace: String,
        sectioned: Bool = false
    ) async throws -> URL {
        guard content.mimeType.lowercased().split(separator: ";").first == "application/xhtml+xml" else {
            throw MankoExtensionEPUBError.invalidXHTML
        }
        let xhtml = try Self.sanitize(content.text, title: title)
        let identifierSeed = "\(sourceNamespace)|\(content.workId)|\(content.id)"
        let identifier = "urn:manko:extension:\(Self.sha256(Data(identifierSeed.utf8)))"
        let sections = sectioned ? try EPUBSectionSplitter.split(xhtml) : []
        let layout = sectioned ? "sectioned-v\(GeneratedPublicationSections.layoutVersion)" : "legacy"
        let digest = Self.sha256(Data((identifier + layout + xhtml).utf8))
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appending(path: "\(digest).epub", directoryHint: .notDirectory)
        if fileManager.fileExists(atPath: destination.path) { return destination }

        let staging = destinationDirectory.appending(
            path: ".\(digest).\(UUID().uuidString).building",
            directoryHint: .notDirectory
        )
        defer { try? fileManager.removeItem(at: staging) }
        do {
            let archive = try await Archive(url: staging, accessMode: .create)
            var entries: [(String, Data, CompressionMethod)] = [
                ("mimetype", Data("application/epub+zip".utf8), .none),
                ("META-INF/container.xml", Data(Self.containerXML.utf8), .deflate),
            ]
            if sectioned {
                let map = GeneratedPublicationSections(sections: sections.enumerated().map { index, section in
                    .init(href: Self.sectionPath(index), title: section.title ?? "Part \(index + 1)", text: section.text)
                })
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                entries.append((GeneratedPublicationSections.resourcePath, try encoder.encode(map), .deflate))
                for (index, section) in sections.enumerated() {
                    entries.append((Self.sectionPath(index), Data(try Self.sanitize(section.xhtml, title: section.title ?? title).utf8), .deflate))
                }
                entries.append(("OEBPS/nav.xhtml", Data(Self.sectionNavigation(map: map).utf8), .deflate))
                entries.append(("OEBPS/content.opf", Data(Self.sectionPackage(identifier: identifier, title: title, map: map).utf8), .deflate))
            } else {
                entries += [
                    ("OEBPS/content.xhtml", Data(xhtml.utf8), .deflate),
                    ("OEBPS/nav.xhtml", Data(Self.navigationXHTML(title: title).utf8), .deflate),
                    ("OEBPS/content.opf", Data(Self.packageDocument(identifier: identifier, title: title).utf8), .deflate),
                ]
            }
            let fixedDate = Date(timeIntervalSince1970: 315_532_800)
            for (path, payload, compression) in entries {
                try Task.checkCancellation()
                try await archive.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(payload.count),
                    modificationDate: fixedDate,
                    permissions: 0o644,
                    compressionMethod: compression
                ) { position, size in
                    let start = Int(position)
                    let end = min(payload.count, start + size)
                    return start < end ? payload.subdata(in: start ..< end) : Data()
                }
            }
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            try Self.excludeFromBackup(destinationDirectory)
            try Self.excludeFromBackup(destination)
            try cleanup(excluding: destination)
            return destination
        } catch let error as MankoExtensionEPUBError {
            throw error
        } catch {
            throw MankoExtensionEPUBError.archive(error.localizedDescription)
        }
    }

    public static func sanitize(_ source: String, title: String) throws -> String {
        guard !source.isEmpty, source.utf8.count <= 2 * 1_024 * 1_024 else {
            throw MankoExtensionEPUBError.contentTooLarge
        }
        var body = source
        if let match = firstMatch(#"<body\b[^>]*>([\s\S]*?)</body\s*>"#, in: body),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: body) {
            body = String(body[range])
        }
        body = replacing(#"<!--[\s\S]*?-->"#, in: body, with: "")
        body = replacing(#"<(script|style|iframe|frame|frameset|object|embed|template|svg|math)\b[^>]*>[\s\S]*?</\1\s*>"#, in: body, with: "")
        body = replacing(#"<(script|style|iframe|frame|frameset|object|embed|template|svg|math|link|meta|base|img|audio|video|source|track)\b[^>]*?/?>"#, in: body, with: "")

        let allowed = Set([
            "p", "div", "span", "section", "article", "aside", "h1", "h2", "h3", "h4", "h5", "h6",
            "br", "hr", "em", "strong", "b", "i", "u", "s", "small", "sub", "sup", "blockquote",
            "pre", "code", "ol", "ul", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot",
            "tr", "th", "td", "figure", "figcaption", "a"
        ])
        let tagExpression = try NSRegularExpression(pattern: #"<\s*(/?)\s*([A-Za-z][A-Za-z0-9:-]*)\b[^>]*>"#)
        let matches = tagExpression.matches(in: body, range: NSRange(body.startIndex..., in: body))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: body),
                  let closingRange = Range(match.range(at: 1), in: body),
                  let nameRange = Range(match.range(at: 2), in: body)
            else { continue }
            let name = body[nameRange].lowercased()
            let closing = !body[closingRange].isEmpty
            let replacement: String
            if !allowed.contains(name) { replacement = "" }
            else if name == "br" || name == "hr" { replacement = closing ? "" : "<\(name) />" }
            else { replacement = closing ? "</\(name)>" : "<\(name)>" }
            body.replaceSubrange(fullRange, with: replacement)
        }
        body = body
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&copy;", with: "©")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&hellip;", with: "…")
        body = replacing(#"&(?!#\d+;|#x[0-9A-Fa-f]+;|amp;|lt;|gt;|quot;|apos;)"#, in: body, with: "&amp;")

        let xhtml = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; script-src 'none'; style-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; base-uri 'none'" />
        <title>\(xmlEscaped(title))</title>
        <style>body{font-family:serif;line-height:1.55;margin:5%;}img,video,audio,iframe,object,embed,form{display:none!important;}pre{white-space:pre-wrap;}table{border-collapse:collapse;}td,th{padding:.25em;vertical-align:top;}</style>
        </head>
        <body>\(body)</body>
        </html>
        """
        let parser = XMLParser(data: Data(xhtml.utf8))
        guard parser.parse() else { throw MankoExtensionEPUBError.invalidXHTML }
        return xhtml
    }

    private func cleanup(excluding retained: URL) throws {
        let fileManager = FileManager.default
        let files = try fileManager.contentsOfDirectory(
            at: destinationDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "epub" && $0 != retained }
        let sorted = try files.sorted {
            let lhs = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rhs = try $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return lhs > rhs
        }
        for file in sorted.dropFirst(max(0, retainedPublicationLimit - 1)) {
            try? fileManager.removeItem(at: file)
        }
    }

    private static func sectionPath(_ index: Int) -> String {
        "OEBPS/section-\(String(format: "%04d", index)).xhtml"
    }

    private static func sectionNavigation(map: GeneratedPublicationSections) -> String {
        let links = map.sections.map { "<li><a href=\"\(xmlEscaped(URL(fileURLWithPath: $0.href).lastPathComponent))\">\(xmlEscaped($0.title))</a></li>" }.joined()
        return "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Contents</title></head><body><nav epub:type=\"toc\"><ol>\(links)</ol></nav></body></html>"
    }

    private static func sectionPackage(identifier: String, title: String, map: GeneratedPublicationSections) -> String {
        let items = map.sections.enumerated().map { index, section in
            "<item id=\"s\(index)\" href=\"\(URL(fileURLWithPath: section.href).lastPathComponent)\" media-type=\"application/xhtml+xml\" />"
        }.joined()
        let spine = map.sections.indices.map { "<itemref idref=\"s\($0)\" />" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="pub-id">\(xmlEscaped(identifier))</dc:identifier><dc:title>\(xmlEscaped(title))</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">1980-01-01T00:00:00Z</meta></metadata><manifest>\(items)<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav" /><item id="section-map" href="manko-sections.json" media-type="application/json" /></manifest><spine>\(spine)</spine></package>
        """
    }

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml" /></rootfiles></container>
    """

    private static func packageDocument(identifier: String, title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="pub-id">\(xmlEscaped(identifier))</dc:identifier><dc:title>\(xmlEscaped(title))</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">1980-01-01T00:00:00Z</meta></metadata><manifest><item id="chapter" href="content.xhtml" media-type="application/xhtml+xml" /><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav" /></manifest><spine><itemref idref="chapter" /></spine></package>
        """
    }

    private static func navigationXHTML(title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="content.xhtml">\(xmlEscaped(title))</a></li></ol></nav></body></html>
        """
    }

    private static func firstMatch(_ pattern: String, in value: String) -> NSTextCheckingResult? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            .firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
    }

    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }

    private static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
    }
}

private actor EPUBLegacyContentCollector {
    private(set) var data = Data()
    func append(_ bytes: Data) throws {
        guard data.count + bytes.count <= 2 * 1_024 * 1_024 else { throw MankoExtensionEPUBError.contentTooLarge }
        data.append(bytes)
    }
}
