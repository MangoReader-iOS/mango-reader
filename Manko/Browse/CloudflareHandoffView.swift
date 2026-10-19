import Foundation
import MankoDomain
import MankoExtensions
import MankoSources
import Observation
import SwiftUI
import WebKit

#if DEBUG
enum CloudflareUITestFixture {
    nonisolated static let launchArgument = "--manko-ui-test-cloudflare"
    nonisolated static let namespace = "ui-test-cloudflare"
    nonisolated static let challengeURL = URL(string: "https://fixture.example/challenge")!

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }
}

actor CloudflareUITestRecoveryOperation {
    static let shared = CloudflareUITestRecoveryOperation()

    private var attempt = 0
    private var verifiedResult: CloudflareHandoffResult?
    private var fallbackFetchCount = 0
    private var fallbackNavigationCount = 0

    func reset() {
        attempt = 0
        verifiedResult = nil
        fallbackFetchCount = 0
        fallbackNavigationCount = 0
    }

    func accept(_ result: CloudflareHandoffResult) {
        verifiedResult = result
    }

    func perform() throws -> String {
        attempt += 1
        if attempt == 1 {
            throw MankoExtensionRuntimeError.cloudflareHandoff(
                CloudflareChallengeContext(
                    url: CloudflareUITestFixture.challengeURL,
                    namespace: CloudflareUITestFixture.namespace,
                    permittedBrowserHosts: ["fixture.example"]
                )
            )
        }
        guard let verifiedResult,
              !verifiedResult.userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              verifiedResult.cookies.contains(where: {
                  $0.name.caseInsensitiveCompare("cf_clearance") == .orderedSame
              })
        else {
            throw SourceError.transport(
                "The synthetic native retry did not receive WebKit's verified user agent and clearance cookie."
            )
        }
        guard attempt == 2 else {
            throw CloudflareBrowserOnlyProtectionError()
        }

        // Exercise the same bounded shape as the production transport: the
        // verified fetch is challenged, one top-level navigation succeeds,
        // and no third attempt or verification loop is allowed.
        fallbackFetchCount += 1
        let fetchCFMitigated = "challenge"
        guard fetchCFMitigated.caseInsensitiveCompare("challenge") == .orderedSame else {
            throw SourceError.transport("The synthetic fetch did not reach the fallback.")
        }
        fallbackNavigationCount += 1
        guard fallbackFetchCount == 1, fallbackNavigationCount == 1 else {
            throw SourceError.transport("The synthetic navigation fallback repeated.")
        }
        return "Cloudflare navigation fallback succeeded."
    }
}
#endif

struct CloudflareHandoffRequest: Identifiable, Equatable {
    let id: UUID
    let context: CloudflareChallengeContext
    let url: URL
    var seed: ExtensionBrowserSessionSeed

    var namespace: String { context.namespace }
    var allowedHTTPSHosts: Set<String> { context.authorizedBrowserHosts }
    var verifiedHostname: String { url.host?.lowercased() ?? url.absoluteString }

    init?(
        id: UUID = UUID(),
        context: CloudflareChallengeContext,
        seed: ExtensionBrowserSessionSeed
    ) {
        guard let url = context.url,
              CloudflareHandoffPolicy.permitsInitialHandoff(
                  to: url,
                  permittedBrowserHosts: context.authorizedBrowserHosts
              )
        else { return nil }
        self.id = id
        self.context = context
        self.url = url
        self.seed = seed
    }

    init?(
        id: UUID = UUID(),
        url: URL,
        namespace: String,
        allowedHTTPSHosts: Set<String>,
        seed: ExtensionBrowserSessionSeed = .init(profile: nil, cookies: [])
    ) {
        let context = CloudflareChallengeContext(
            url: url,
            namespace: namespace,
            permittedBrowserHosts: allowedHTTPSHosts
        )
        self.init(id: id, context: context, seed: seed)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

struct CloudflareHandoffResult: Equatable, Sendable {
    var canonicalHTTPSOrigin: URL
    var userAgent: String
    var cookies: [ExtensionHTTPStateCookie]
    var websiteDataStoreIdentifier: UUID
}

enum CloudflareWebsiteDataStore {
    static func identifier(for namespace: String) -> UUID {
        ExtensionBrowserSessionProfile.websiteDataStoreIdentifier(for: namespace)
    }

    @MainActor
    static func remove(for namespace: String) async throws {
        let identifier = identifier(for: namespace)
        // Identifier-only APIs do not initialize WebKit's main run loop.
        // Pending cleanup can be the first WebKit call after a cold launch.
        _ = WKWebsiteDataStore.default()
        let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
        guard identifiers.contains(identifier) else { return }
        var lastError: Error?
        // Removing a source dismisses any verifier first, but WebKit can hold
        // the sheet's data store through the dismissal animation.
        for attempt in 0 ..< 4 {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                return
            } catch {
                lastError = error
                guard attempt < 3 else { break }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        if let lastError { throw lastError }
    }
}

enum CloudflareHandoffPolicy {
    private static let cloudflareChallengeHosts: Set<String> = [
        "challenges.cloudflare.com",
        "*.challenges.cloudflare.com",
    ]

    /// Valid handoff entry points are always HTTPS. `about:` URLs are handled
    /// separately for WebKit-created empty frames.
    static func allows(_ url: URL) -> Bool {
        canonicalHTTPSOrigin(for: url) != nil
    }

    static func canonicalHTTPSOrigin(for url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let rawHost = components.host
        else { return nil }
        let host = normalizedHost(rawHost)
        guard !host.isEmpty else { return nil }

        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        if components.port != 443 {
            origin.port = components.port
        }
        origin.path = "/"
        return origin.url
    }

    static func matchesCanonicalHTTPSOrigin(_ candidate: URL?, challengedOrigin: URL) -> Bool {
        guard let candidate else { return false }
        return canonicalHTTPSOrigin(for: candidate) == canonicalHTTPSOrigin(for: challengedOrigin)
    }

    static func blockedNavigationMessage(
        _ current: String?,
        afterAllowingNavigationInMainFrame isMainFrame: Bool
    ) -> String? {
        isMainFrame ? nil : current
    }

    static func permitsInitialHandoff(
        to url: URL,
        permittedBrowserHosts: Set<String>
    ) -> Bool {
        guard let origin = canonicalHTTPSOrigin(for: url),
              let host = origin.host.map(normalizedHost)
        else { return false }
        let declarations = Set(permittedBrowserHosts.filter(isSafeBrowserHostDeclaration))
        return HTTPSHostAccess.allows(host, declarations: declarations)
    }

    static func permitsNavigation(
        to url: URL,
        isMainFrame: Bool,
        sourceURL: URL,
        permittedBrowserHosts: Set<String>
    ) -> Bool {
        guard permitsInitialHandoff(
            to: sourceURL,
            permittedBrowserHosts: permittedBrowserHosts
        ) else { return false }
        if url.scheme?.lowercased() == "about" {
            return !isMainFrame &&
                (url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc")
        }
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let rawHost = url.host
        else { return false }

        let host = normalizedHost(rawHost)
        var declarations = Set(permittedBrowserHosts.filter(isSafeBrowserHostDeclaration))
        declarations.formUnion(cloudflareChallengeHosts)

        // HTTPS main-frame redirects and child-frame navigations use the same
        // narrow source/challenge allowlist. Resource loads are unaffected.
        return HTTPSHostAccess.allows(host, declarations: declarations)
    }

    private static func isSafeBrowserHostDeclaration(_ rawValue: String) -> Bool {
        let value = normalizedHost(rawValue)
        guard !value.isEmpty else { return false }
        if value.hasPrefix("*.") {
            let suffix = String(value.dropFirst(2))
            return !suffix.isEmpty &&
                !suffix.contains("*") &&
                !ExtensionHTTPStateCookie.isPublicSuffixDomain(suffix)
        }
        return !value.contains("*")
    }

    static func approvedCookies(
        _ cookies: [ExtensionHTTPStateCookie],
        for origin: URL,
        requestPath: String? = nil,
        now: Date = .now
    ) -> [ExtensionHTTPStateCookie] {
        guard let canonicalOrigin = canonicalHTTPSOrigin(for: origin),
              var components = URLComponents(url: canonicalOrigin, resolvingAgainstBaseURL: false)
        else { return [] }
        components.path = normalizedRequestPath(requestPath ?? origin.path)
        guard let requestURL = components.url else { return [] }

        return Array(cookies.lazy.filter { $0.isApplicable(to: requestURL, at: now) }.prefix(100))
    }

    static func containsApplicableClearance(
        in cookies: [ExtensionHTTPStateCookie],
        for origin: URL,
        requestPath: String? = nil,
        now: Date = .now
    ) -> Bool {
        approvedCookies(cookies, for: origin, requestPath: requestPath, now: now)
            .contains { $0.name.caseInsensitiveCompare("cf_clearance") == .orderedSame }
    }

    /// A protected acquisition URL can become a CBZ, EPUB, image, or other
    /// binary response immediately after verification. WebKit cannot always
    /// commit those responses as a page, so there is no DOM in which to search
    /// for challenge markup. Only a successful, explicitly non-HTML response
    /// may stand in for that markup check; clearance and the captured WebKit UA
    /// are still required by `CloudflareVerificationPageState`.
    static func isChallengeFreeNonHTMLMainFrameResponse(
        statusCode: Int,
        mimeType: String?,
        contentDisposition: String?,
        canShowMIMEType: Bool,
        cfMitigated: String? = nil
    ) -> Bool {
        if responseIndicatesCloudflareChallenge(cfMitigated) { return false }
        guard (200 ..< 300).contains(statusCode),
              let mimeType = mimeType?
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              !mimeType.isEmpty,
              mimeType != "text/html",
              mimeType != "application/xhtml+xml"
        else { return false }

        let disposition = contentDisposition?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let knownBinary = mimeType.hasPrefix("image/") || [
            "application/epub+zip",
            "application/octet-stream",
            "application/pdf",
            "application/vnd.comicbook+zip",
            "application/x-cbz",
            "application/x-zip-compressed",
            "application/zip",
        ].contains(mimeType)
        return !canShowMIMEType || disposition?.hasPrefix("attachment") == true || knownBinary
    }

    static func responseIndicatesCloudflareChallenge(_ cfMitigated: String?) -> Bool {
        cfMitigated?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("challenge") == .orderedSame
    }

    static func seedIdentityMatches(
        _ profile: ExtensionBrowserSessionProfile?,
        origin: URL,
        userAgent: String
    ) -> Bool {
        guard let profile,
              !userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profile.userAgent == userAgent,
              let profileOrigin = canonicalHTTPSOrigin(for: profile.canonicalHTTPSOrigin),
              let requestedOrigin = canonicalHTTPSOrigin(for: origin)
        else { return false }
        return profileOrigin == requestedOrigin
    }

    static func cookiesForWebKitSeeding(
        _ seed: ExtensionBrowserSessionSeed,
        for origin: URL,
        requestPath: String,
        userAgent: String,
        now: Date = .now
    ) -> [ExtensionHTTPStateCookie] {
        let mayReuseClearance = seedIdentityMatches(
            seed.profile,
            origin: origin,
            userAgent: userAgent
        )
        return approvedCookies(
            seed.cookies,
            for: origin,
            requestPath: requestPath,
            now: now
        ).filter {
            mayReuseClearance || $0.name.caseInsensitiveCompare("cf_clearance") != .orderedSame
        }
    }

    /// Clearance is bound to a browser identity, not a request path. When the
    /// identity cannot be reused, remove every clearance that could be sent to
    /// this origin even if it was issued for a different path.
    static func isClearanceCookie(
        _ cookie: ExtensionHTTPStateCookie,
        scopedTo origin: URL
    ) -> Bool {
        guard cookie.name.caseInsensitiveCompare("cf_clearance") == .orderedSame,
              let canonicalOrigin = canonicalHTTPSOrigin(for: origin)
        else { return false }
        var domainProbe = cookie
        domainProbe.path = "/"
        domainProbe.expires = nil
        return domainProbe.isApplicable(to: canonicalOrigin)
    }

    static func cookieExpirationDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) { return parsed }
        return ISO8601DateFormatter().date(from: value)
    }

    /// Foundation/WebKit use a leading dot as the only round-trip provenance
    /// for a domain cookie. Preserve it explicitly when seeding so importing
    /// the WebKit jar cannot silently narrow that cookie to host-only.
    static func webKitDomain(for cookie: ExtensionHTTPStateCookie) -> String? {
        guard !cookie.hostOnly else { return nil }
        var rawDomain = cookie.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        while rawDomain.hasPrefix(".") { rawDomain.removeFirst() }
        let domain = normalizedHost(rawDomain)
        guard !domain.isEmpty else { return nil }
        return ".\(domain)"
    }

    private static func normalizedRequestPath(_ path: String) -> String {
        path.hasPrefix("/") && !path.isEmpty ? path : "/"
    }

    private static func normalizedHost(_ value: String) -> String {
        var value = value.lowercased().trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "[]"))
        )
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

}

enum CloudflareChallengeMarkupPolicy {
    static let selectors = [
        "#challenge-form",
        "#challenge-running",
        "#challenge-stage",
        "[id^=\"cf-chl-\"]",
        "script[src*=\"/cdn-cgi/challenge-platform/\"]",
        "form[action*=\"__cf_chl\"]",
        "form[action*=\"/cdn-cgi/challenge-platform/\"]",
        "iframe[src*=\"/cdn-cgi/challenge-platform/\"]",
        "iframe[src*=\"challenges.cloudflare.com\"]",
    ]

    static var evaluationJavaScript: String {
        let selector = selectors.joined(separator: ", ")
        return #"""
        (() => {
            const title = (document.title || '').toLowerCase();
            const bodyText = (document.body ? document.body.innerText : '').toLowerCase();
            const challenge =
                title.includes('just a moment') ||
                typeof window._cf_chl_opt !== 'undefined' ||
                Boolean(document.querySelector('\#(selector)')) ||
                bodyText.includes('enable javascript and cookies to continue');
            return {
                containsChallengeMarkup: challenge
            };
        })()
        """#
    }
}

struct CloudflareVerificationPageState: Equatable {
    var mainFrameStatusCode: Int?
    var hasFinishedMainFrameNavigation: Bool
    var mainFrameMatchesChallengedOrigin: Bool
    var mainFrameIndicatesChallenge: Bool
    var containsChallengeMarkup: Bool
    var hasApplicableClearance: Bool
    var userAgent: String

    var isComplete: Bool {
        guard let mainFrameStatusCode else { return false }
        return hasFinishedMainFrameNavigation &&
            mainFrameMatchesChallengedOrigin &&
            !mainFrameIndicatesChallenge &&
            mainFrameStatusCode != 403 &&
            mainFrameStatusCode != 503 &&
            !containsChallengeMarkup &&
            hasApplicableClearance &&
            !userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CloudflareHandoffView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: CloudflareHandoffRequest
    @State private var session: CloudflareBrowserSession
    @State private var isSaving = false
    @State private var completionMessage: String?

    init(request: CloudflareHandoffRequest) {
        self.request = request
        _session = State(initialValue: CloudflareBrowserSession(request: request))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Secure verification host")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(request.verifiedHostname)
                            .font(.headline.monospaced())
                            .textSelection(.enabled)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppLayout.pageMargin)
                .padding(.vertical, 10)
                .background(AppColors.secondaryBackground)
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Secure verification host, \(request.verifiedHostname)")
                .accessibilityIdentifier("cloudflare-verification-host")

                CloudflareWebView(session: session)
                    .id(ObjectIdentifier(session))
                    .overlay {
                        if isSaving {
                            ProgressView("Saving verification…")
                        } else if session.isLoading {
                            ProgressView("Opening verification…")
                        }
                    }
                if isSaving {
                    ProgressView("Saving verification…")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppLayout.pageMargin)
                        .background(AppColors.secondaryBackground)
                        .overlay(alignment: .top) { Divider() }
                } else if let message = completionMessage ?? session.loadErrorMessage ?? session.blockedNavigationMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(AppColors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        if completionMessage != nil, let result = session.verificationResult {
                            Button { complete(result) } label: {
                                Text("Retry Saving")
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("cloudflare-retry-saving")
                        }
                        Button(action: reload) {
                            Label("Reload Verification", systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("cloudflare-reload")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppLayout.pageMargin)
                    .background(AppColors.secondaryBackground)
                    .overlay(alignment: .top) { Divider() }
                } else {
                    Text("Complete Cloudflare’s verification. This window closes automatically after the source page opens.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppLayout.pageMargin)
                        .background(AppColors.secondaryBackground)
                        .overlay(alignment: .top) { Divider() }
                }
            }
            .appBackground()
            .navigationTitle("Verify Source")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    FixedNavigationChrome {
                        Button("Cancel") {
                            session.stop()
                            model.sourcesModel.cancelCloudflareHandoff(request)
                            dismiss()
                        }
                        .disabled(isSaving)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .onChange(of: session.verificationResult) { _, result in
            guard let result else { return }
            complete(result)
        }
    }

    private func complete(_ result: CloudflareHandoffResult) {
        guard !isSaving else { return }
        isSaving = true
        completionMessage = nil
        Task {
            guard let verifiedWebView = session.transferVerifiedWebView() else {
                isSaving = false
                completionMessage = "The verified browser session is unavailable. Reload verification to try again."
                return
            }
            let accepted = await model.completeCloudflareHandoff(
                request,
                result: result,
                verifiedWebView: verifiedWebView,
                onFailure: { completionMessage = $0 }
            )
            if !accepted {
                session.reclaimTransferredWebView()
                if completionMessage == nil {
                    completionMessage = "Verification could not be saved. Try saving again, or reload the page."
                }
            }
            isSaving = false
            if model.sourcesModel.pendingCloudflareHandoff == nil {
                dismiss()
            }
        }
    }

    private func reload() {
        guard !isSaving else { return }
        completionMessage = nil
        session.stop()
        // A new WebView captures its user agent before loading source code.
        session = CloudflareBrowserSession(request: request)
        session.start()
    }
}

private struct CloudflareWebView: UIViewRepresentable {
    let session: CloudflareBrowserSession

    func makeUIView(context _: Context) -> WKWebView { session.webView }
    func updateUIView(_: WKWebView, context _: Context) {}
}

@MainActor
@Observable
final class CloudflareBrowserSession: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    let webView: WKWebView
    private let request: CloudflareHandoffRequest
    private let canonicalOrigin: URL
    private let cookieStore: WKHTTPCookieStore
    private var hasStarted = false
    private var isStopped = false
    private var hasLoadedInitialRequest = false
    private var hasFinishedMainFrameNavigation = false
    private var mainFrameMatchesChallengedOrigin = false
    private var mainFrameIndicatesChallenge = false
    private var hasChallengeFreeNonHTMLMainFrameResponse = false
    private var isEvaluating = false
    private var mainFrameStatusCode: Int?
    private var userAgent = ""
    private var isObservingCookies = false
    private var evaluationTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
#if DEBUG
    private enum SyntheticFixturePhase {
        case inactive
        case challenge
        case clean
    }

    private var syntheticFixturePhase = SyntheticFixturePhase.inactive
    private var syntheticFixtureTransitionTask: Task<Void, Never>?
#endif
    var isLoading = true
    var blockedNavigationMessage: String?
    var loadErrorMessage: String?
    var verificationResult: CloudflareHandoffResult?
    private(set) var hasTransferredWebView = false

    init(request: CloudflareHandoffRequest) {
        self.request = request
        canonicalOrigin = CloudflareHandoffPolicy.canonicalHTTPSOrigin(for: request.url)!
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = request.namespace.hasPrefix("private-") ? .nonPersistent() : WKWebsiteDataStore(
            forIdentifier: CloudflareWebsiteDataStore.identifier(for: request.namespace)
        )
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Intentionally leave customUserAgent unset. The exact navigator UA is
        // captured below and handed to the native request broker.
        webView = WKWebView(frame: .zero, configuration: configuration)
        cookieStore = configuration.websiteDataStore.httpCookieStore
        super.init()
        webView.navigationDelegate = self
        cookieStore.add(self)
        isObservingCookies = true
    }

    func start() {
        guard !hasStarted, !isStopped else { return }
        hasStarted = true
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareAndLoad()
            self.preparationTask = nil
        }
    }

    func stop() {
        isStopped = true
        cancelOwnedTasks()
        removeCookieObserver()
        guard !hasTransferredWebView else { return }
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    func transferVerifiedWebView() -> WKWebView? {
        guard verificationResult != nil,
              !isStopped,
              !hasTransferredWebView
        else { return nil }
        cancelOwnedTasks()
        removeCookieObserver()
        webView.navigationDelegate = nil
        hasTransferredWebView = true
        return webView
    }

    @discardableResult
    func reclaimTransferredWebView() -> Bool {
        guard hasTransferredWebView else { return false }
        hasTransferredWebView = false
        guard !isStopped else {
            webView.stopLoading()
            return false
        }
        webView.navigationDelegate = self
        if !isObservingCookies {
            cookieStore.add(self)
            isObservingCookies = true
        }
        return true
    }

    private func cancelOwnedTasks() {
        preparationTask?.cancel()
        preparationTask = nil
        evaluationTask?.cancel()
        evaluationTask = nil
#if DEBUG
        syntheticFixtureTransitionTask?.cancel()
        syntheticFixtureTransitionTask = nil
#endif
    }

    private func removeCookieObserver() {
        guard isObservingCookies else { return }
        cookieStore.remove(self)
        isObservingCookies = false
    }

    private func prepareAndLoad() async {
        do {
            try await ExtensionNetworkPolicy(hosts: request.allowedHTTPSHosts).configureBrowser(webView.configuration)
        } catch {
            isLoading = false
            loadErrorMessage = error.localizedDescription
            return
        }
        userAgent = await navigatorUserAgent()
        guard !Task.isCancelled, !isStopped else { return }
        guard !userAgent.isEmpty else {
            isLoading = false
            loadErrorMessage = "The verification browser could not start. Reload verification to try again."
            return
        }
#if DEBUG
        if CloudflareUITestFixture.isEnabled,
           request.namespace == CloudflareUITestFixture.namespace
        {
            hasLoadedInitialRequest = true
            syntheticFixturePhase = .challenge
            webView.loadHTMLString(
                """
                <!doctype html>
                <html><head><title>Just a moment...</title></head>
                <body><div id="challenge-running">Checking your browser…</div></body></html>
                """,
                baseURL: request.url
            )
            return
        }
#endif
        let mayReuseSeedIdentity = CloudflareHandoffPolicy.seedIdentityMatches(
            request.seed.profile,
            origin: canonicalOrigin,
            userAgent: userAgent
        )
        if !mayReuseSeedIdentity {
            var origins = [canonicalOrigin]
            if let priorOrigin = request.seed.profile?.canonicalHTTPSOrigin {
                origins.append(priorOrigin)
            }
            await removeClearanceCookies(scopedTo: origins)
        }

        guard !Task.isCancelled, !isStopped else { return }

        let seed = CloudflareHandoffPolicy.cookiesForWebKitSeeding(
            request.seed,
            for: canonicalOrigin,
            requestPath: request.url.path,
            userAgent: userAgent
        )
        for cookie in seed.compactMap(makeHTTPCookie) {
            guard !Task.isCancelled, !isStopped else { return }
            await setCookie(cookie)
        }

        guard !Task.isCancelled, !isStopped else { return }
        hasLoadedInitialRequest = true
        webView.load(URLRequest(url: request.url, timeoutInterval: 30))
    }

    private func navigatorUserAgent() async -> String {
        let value = try? await webView.evaluateJavaScript("navigator.userAgent")
        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func removeClearanceCookies(scopedTo origins: [URL]) async {
        for cookie in await cookieStore.allCookies() {
            let state = makeStateCookie(cookie)
            guard origins.contains(where: {
                CloudflareHandoffPolicy.isClearanceCookie(state, scopedTo: $0)
            }) else { continue }
            await cookieStore.deleteCookie(cookie)
        }
    }

    private func setCookie(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            cookieStore.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    private func makeHTTPCookie(_ cookie: ExtensionHTTPStateCookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .path: cookie.path,
        ]
        if cookie.hostOnly {
            properties[.originURL] = canonicalOrigin
        } else {
            guard let domain = CloudflareHandoffPolicy.webKitDomain(for: cookie) else {
                return nil
            }
            properties[.domain] = domain
        }
        if cookie.secure { properties[.secure] = "TRUE" }
        if cookie.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires = cookie.expires {
            guard let expiration = CloudflareHandoffPolicy.cookieExpirationDate(expires) else { return nil }
            properties[.expires] = expiration
        }
        return HTTPCookie(properties: properties)
    }

    private func makeStateCookie(_ cookie: HTTPCookie) -> ExtensionHTTPStateCookie {
        ExtensionHTTPStateCookie(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            expires: cookie.expiresDate?.ISO8601Format(),
            secure: cookie.isSecure,
            httpOnly: cookie.isHTTPOnly,
            hostOnly: !cookie.domain.hasPrefix(".")
        )
    }

    private func scheduleEvaluation() {
        guard !isStopped, hasLoadedInitialRequest, verificationResult == nil else { return }
        evaluationTask?.cancel()
        evaluationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.evaluateVerificationState()
        }
    }

    private func evaluateVerificationState() async {
        guard !isStopped, !isEvaluating, verificationResult == nil else { return }
        isEvaluating = true
        defer { isEvaluating = false }

        let containsChallengeMarkup: Bool
        if hasChallengeFreeNonHTMLMainFrameResponse {
            containsChallengeMarkup = false
        } else {
            containsChallengeMarkup = await self.containsChallengeMarkup()
        }
        guard !Task.isCancelled, !isStopped else { return }
        let cookies = (await cookieStore.allCookies()).map(makeStateCookie)
        guard !Task.isCancelled, !isStopped else { return }
        let approved = CloudflareHandoffPolicy.approvedCookies(
            cookies,
            for: canonicalOrigin,
            requestPath: request.url.path
        )
        let state = CloudflareVerificationPageState(
            mainFrameStatusCode: mainFrameStatusCode,
            hasFinishedMainFrameNavigation: hasFinishedMainFrameNavigation,
            mainFrameMatchesChallengedOrigin: mainFrameMatchesChallengedOrigin,
            mainFrameIndicatesChallenge: mainFrameIndicatesChallenge,
            containsChallengeMarkup: containsChallengeMarkup,
            hasApplicableClearance: approved.contains {
                $0.name.caseInsensitiveCompare("cf_clearance") == .orderedSame
            },
            // This value was captured from WebKit's blank page before any
            // untrusted source script loaded. Page-world JavaScript can
            // shadow `navigator.userAgent`, so never read it again here.
            userAgent: userAgent
        )
        guard state.isComplete else { return }

        verificationResult = CloudflareHandoffResult(
            canonicalHTTPSOrigin: canonicalOrigin,
            userAgent: state.userAgent,
            cookies: approved,
            websiteDataStoreIdentifier: CloudflareWebsiteDataStore.identifier(for: request.namespace)
        )
    }

    private func containsChallengeMarkup() async -> Bool {
        guard let value = try? await webView.evaluateJavaScript(
            CloudflareChallengeMarkupPolicy.evaluationJavaScript
        ),
              let values = value as? [String: Any]
        else { return true }
        return (values["containsChallengeMarkup"] as? Bool) ?? true
    }

    func cookiesDidChange(in _: WKHTTPCookieStore) {
        scheduleEvaluation()
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        isLoading = true
        loadErrorMessage = nil
        hasFinishedMainFrameNavigation = false
        mainFrameMatchesChallengedOrigin = false
        mainFrameIndicatesChallenge = false
        hasChallengeFreeNonHTMLMainFrameResponse = false
        mainFrameStatusCode = nil
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        isLoading = false
        hasFinishedMainFrameNavigation = true
#if DEBUG
        switch syntheticFixturePhase {
        case .challenge:
            mainFrameStatusCode = 503
            mainFrameMatchesChallengedOrigin = true
            scheduleEvaluation()
            syntheticFixtureTransitionTask?.cancel()
            syntheticFixtureTransitionTask = Task { @MainActor [weak self] in
                // Keep the synthetic challenge visible long enough for the UI
                // test to observe the real verification sheet transition.
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self else { return }
                let clearance = ExtensionHTTPStateCookie(
                    name: "cf_clearance",
                    value: "synthetic-ui-fixture",
                    domain: "fixture.example",
                    path: "/",
                    secure: true,
                    httpOnly: true,
                    hostOnly: true
                )
                guard let cookie = self.makeHTTPCookie(clearance) else { return }
                await self.setCookie(cookie)
                guard !Task.isCancelled else { return }
                self.syntheticFixturePhase = .clean
                self.webView.loadHTMLString(
                    """
                    <!doctype html>
                    <html><head><title>Fixture source</title></head>
                    <body><main>Verification complete.</main></body></html>
                    """,
                    baseURL: self.request.url
                )
            }
            return
        case .clean:
            mainFrameStatusCode = 200
            mainFrameMatchesChallengedOrigin = true
        case .inactive:
            break
        }
#endif
        scheduleEvaluation()
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        recordNavigationFailure(error)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        recordNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        guard !isStopped, !hasTransferredWebView else { return }
        cancelOwnedTasks()
        isLoading = false
        verificationResult = nil
        hasFinishedMainFrameNavigation = false
        loadErrorMessage = "The verification browser stopped. Reload verification to continue."
    }

    private func recordNavigationFailure(_ error: Error) {
        guard !isStopped, !hasTransferredWebView else { return }
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled),
              !hasChallengeFreeNonHTMLMainFrameResponse else { return }
        isLoading = false
        hasFinishedMainFrameNavigation = false
        verificationResult = nil
        loadErrorMessage = "Couldn’t open verification: \(error.localizedDescription)"
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        guard CloudflareHandoffPolicy.permitsNavigation(
            to: url,
            isMainFrame: isMainFrame,
            sourceURL: request.url,
            permittedBrowserHosts: request.allowedHTTPSHosts
        ) else {
            if isMainFrame {
                blockedNavigationMessage = "Blocked a redirect outside this source’s secure verification hosts: \(url.host ?? url.absoluteString)"
            }
            decisionHandler(.cancel)
            return
        }
        blockedNavigationMessage = CloudflareHandoffPolicy.blockedNavigationMessage(
            blockedNavigationMessage,
            afterAllowingNavigationInMainFrame: isMainFrame
        )
        decisionHandler(.allow)
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse
        {
            mainFrameStatusCode = response.statusCode
            mainFrameMatchesChallengedOrigin = CloudflareHandoffPolicy
                .matchesCanonicalHTTPSOrigin(response.url, challengedOrigin: canonicalOrigin)
            let cfMitigated = response.value(forHTTPHeaderField: "cf-mitigated")
            mainFrameIndicatesChallenge = CloudflareHandoffPolicy
                .responseIndicatesCloudflareChallenge(cfMitigated)
            if mainFrameMatchesChallengedOrigin,
               CloudflareHandoffPolicy.isChallengeFreeNonHTMLMainFrameResponse(
                statusCode: response.statusCode,
                mimeType: response.mimeType,
                contentDisposition: response.value(forHTTPHeaderField: "Content-Disposition"),
                canShowMIMEType: navigationResponse.canShowMIMEType,
                cfMitigated: cfMitigated
            ) {
                isLoading = false
                hasFinishedMainFrameNavigation = true
                hasChallengeFreeNonHTMLMainFrameResponse = true
                scheduleEvaluation()
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }
}
