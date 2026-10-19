import Foundation

/// Splits already-sanitized XML, never raw HTML or a string cut through tags.
/// Container ancestors are reopened around each unit; tables, lists, paragraphs
/// and preformatted blocks stay intact even when they exceed the target size.
enum EPUBSectionSplitter {
    struct Section {
        var xhtml: String
        var text: String
        var title: String?
    }

    static func split(_ xhtml: String, targetBytes: Int = 32 * 1_024) throws -> [Section] {
        let collector = Collector()
        let parser = XMLParser(data: Data(xhtml.utf8))
        parser.delegate = collector
        guard parser.parse(), let body = collector.body else { throw MankoExtensionEPUBError.invalidXHTML }
        var sections: [Section] = []
        var current = Section(xhtml: "", text: "", title: nil)
        func flush() {
            guard !current.xhtml.isEmpty else { return }
            current.text = current.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            sections.append(current)
            current = Section(xhtml: "", text: "", title: nil)
        }
        for unit in body.units {
            try Task.checkCancellation()
            if !current.xhtml.isEmpty, !unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               current.xhtml.utf8.count >= targetBytes || (unit.title != nil && current.xhtml.utf8.count >= targetBytes / 2) {
                flush()
            }
            current.xhtml += unit.xhtml
            current.text += unit.text
            if current.title == nil { current.title = unit.title }
        }
        flush()
        guard !sections.isEmpty else { throw MankoExtensionEPUBError.invalidXHTML }
        return sections
    }

    private final class Node {
        let name: String?
        var value = ""
        var children: [Node] = []
        init(_ name: String?) { self.name = name }
        var xhtml: String {
            guard let name else { return Self.escape(value) }
            if name == "br" || name == "hr" { return "<\(name) />" }
            return "<\(name)>\(children.map(\.xhtml).joined())</\(name)>"
        }
        var text: String {
            guard let name else { return value }
            let content = children.map(\.text).joined()
            return name == "span" || ["em", "strong", "b", "i", "a", "u", "s", "small", "sub", "sup", "code"].contains(name)
                ? content : " \(content) "
        }
        var title: String? {
            if let name, ["h1", "h2", "h3", "h4", "h5", "h6"].contains(name) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return children.lazy.compactMap(\.title).first
        }
        var units: [Section] {
            guard let name, ["body", "div", "section", "article", "aside", "blockquote", "figure"].contains(name) else {
                return [.init(xhtml: xhtml, text: text, title: title)]
            }
            return children.flatMap(\.units).map { unit in
                name == "body" ? unit : .init(xhtml: "<\(name)>\(unit.xhtml)</\(name)>", text: unit.text, title: unit.title)
            }
        }
        static func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var body: Node?
        var stack: [Node] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "body" { let node = Node(name); body = node; stack = [node] }
            else if let parent = stack.last { let node = Node(name); parent.children.append(node); stack.append(node) }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if !stack.isEmpty { stack.removeLast() }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let parent = stack.last else { return }
            if let last = parent.children.last, last.name == nil { last.value += string }
            else { let node = Node(nil); node.value = string; parent.children.append(node) }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
        }
    }
}
