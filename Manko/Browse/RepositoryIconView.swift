import AuthenticationServices
import CryptoKit
import MankoDomain
import MankoExtensions
import SwiftUI
import UIKit
import WebKit

struct RepositoryIconView: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var scaledDimension: CGFloat = 48
    let repositoryID: String
    let entryID: String
    let iconIdentity: String
    @State private var image: UIImage?

    init(
        repositoryID: String,
        entryID: String,
        iconIdentity: String,
        dimension: CGFloat = 48
    ) {
        self.repositoryID = repositoryID
        self.entryID = entryID
        self.iconIdentity = iconIdentity
        _scaledDimension = ScaledMetric(wrappedValue: dimension, relativeTo: .body)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .background(Color.white)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.quaternary)
                    Image(systemName: "books.vertical.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(
            width: min(scaledDimension, 72),
            height: min(scaledDimension, 72)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityHidden(true)
        .task(id: "\(repositoryID)::\(entryID)::\(iconIdentity)") {
            image = nil
            guard let data = try? await model.sourcesModel.repositoryIconData(repositoryID: repositoryID, entryID: entryID),
                  !Task.isCancelled
            else { return }
            image = UIImage(data: data)
        }
    }
}

enum RepositoryMaturityFlairContent: Equatable {
    case safe
    case mature
    case adult
    case unrated

    init(rating: RepositoryMaturityRating?) {
        switch rating {
        case .safe: self = .safe
        case .mature: self = .mature
        case .adult: self = .adult
        case nil: self = .unrated
        }
    }

    var text: String {
        switch self {
        case .safe: String(localized: "SAFE")
        case .mature: "17+"
        case .adult: "18+"
        case .unrated: String(localized: "UNRATED")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .safe: String(localized: "Safe maturity rating")
        case .mature: String(localized: "Maturity rating 17+")
        case .adult: String(localized: "Maturity rating 18+")
        case .unrated: String(localized: "Maturity rating unavailable")
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .mature: .orange
        case .adult: .red
        case .unrated: .secondary
        }
    }
}

struct RepositoryFlair: View {
    @ScaledMetric(relativeTo: .caption2) private var scaledHorizontalPadding: CGFloat = 7
    @ScaledMetric(relativeTo: .caption2) private var scaledVerticalPadding: CGFloat = 3
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, min(scaledHorizontalPadding, 14))
            .padding(.vertical, min(scaledVerticalPadding, 8))
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
            .accessibilityLabel(text == "NEW" ? "New source" : (text == "UPDATE" ? "Update available" : "Age rating \(text)"))
    }
}

/// Repository artwork is untrusted. Only an inert, self-contained SVG document
/// reaches WebKit; it has no account cookies, JavaScript, or network access.
@MainActor
final class RepositorySVGRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Data, Error>?
    private var deadline: Task<Void, Never>?

    private override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 256, height: 256), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.isScrollEnabled = false
    }

    static func render(_ data: Data) async throws -> Data {
        try Task.checkCancellation()
        let svg = try RepositorySVGValidation.document(data)
        let renderer = RepositorySVGRenderer()
        return try await renderer.run(svg)
    }

    private func run(_ svg: String) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else { finish(.failure(CancellationError())); return }
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { return }
                    self?.finish(.failure(SourceError.unsupportedResponse))
                }
                webView.loadHTMLString("""
                <!doctype html><html><head><meta name="viewport" content="width=256,initial-scale=1">
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
                <style>html,body{margin:0;width:256px;height:256px;background:white;overflow:hidden}body>svg{display:block;width:256px;height:256px}</style>
                </head><body>\(svg)</body></html>
                """, baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { [weak self] in
            guard let self, continuation != nil else { return }
            do {
                let config = WKSnapshotConfiguration()
                config.rect = CGRect(x: 0, y: 0, width: 256, height: 256)
                config.snapshotWidth = 256
                let image = try await webView.takeSnapshot(configuration: config)
                guard let data = image.pngData(), data.count <= SourceRepositoryLimits.iconBytes else {
                    throw SourceError.unsupportedResponse
                }
                finish(.success(data))
            } catch { finish(.failure(error)) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.absoluteString == "about:blank" && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        continuation.resume(with: result)
    }
}

final class RepositorySVGValidation: NSObject, XMLParserDelegate {
    private var valid = true
    private var elements = 0
    private var element = ""

    static func document(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= SourceRepositoryLimits.iconBytes,
              let text = String(data: data, encoding: .utf8),
              !text.lowercased().contains("<!doctype"), !text.lowercased().contains("<!entity") else {
            throw SourceError.unsupportedResponse
        }
        let delegate = RepositorySVGValidation()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.valid, delegate.elements > 0 else { throw SourceError.unsupportedResponse }
        return text.replacingOccurrences(of: #"<\?xml\s[^?]*\?>"#, with: "", options: .regularExpression)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = elementName.lowercased().split(separator: ":").last.map(String.init) ?? ""
        elements += 1
        let forbidden = ["script", "foreignobject", "iframe", "object", "embed", "image", "audio", "video", "animate", "animatemotion", "animatetransform", "set", "discard"]
        if (elements == 1 && element != "svg") || elements > 10_000 || forbidden.contains(element) { valid = false }
        for (name, value) in attributes {
            let name = name.lowercased().split(separator: ":").last.map(String.init) ?? ""
            if name.hasPrefix("on") || ((name == "href" || name == "src") && !value.hasPrefix("#")) || !Self.isLocalStyle(value) { valid = false }
        }
        if !valid { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if element == "style" && !Self.isLocalStyle(string) { valid = false; parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        valid = false
        parser.abortParsing()
    }

    static func isLocalStyle(_ value: String) -> Bool {
        let lower = value.lowercased()
        guard !lower.contains("@import"), !lower.contains("@font-face") else { return false }
        let expression = try! NSRegularExpression(pattern: #"url\s*\(([^)]*)\)"#, options: .caseInsensitive)
        let string = value as NSString
        return expression.matches(in: value, range: NSRange(location: 0, length: string.length)).allSatisfy {
            string.substring(with: $0.range(at: 1)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))).hasPrefix("#")
        }
    }
}
