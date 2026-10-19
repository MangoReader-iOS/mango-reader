import Foundation
import MankoDomain
import Observation

@MainActor @Observable
final class SourceSuggestionLoader {
    private(set) var suggestions: [SourceSearchSuggestion] = []
    private(set) var isLoading = false
    private(set) var isWaiting = false
    private(set) var errorMessage: String?
    private(set) var isAwaitingVerification = false
    private(set) var isOffline = false
    private(set) var completedRequest: SourceSearchSuggestionRequest?
    @ObservationIgnored private var gate = LatestOperationGate()
    @ObservationIgnored private var lastRequest: SourceSearchSuggestionRequest?

    func clearSuggestions() {
        gate.invalidate()
        suggestions = []
        isLoading = false
        isWaiting = false
        errorMessage = nil
        isAwaitingVerification = false
        isOffline = false
        completedRequest = nil
    }

    func acceptCached(_ values: [SourceSearchSuggestion], for request: SourceSearchSuggestionRequest) {
        guard lastRequest == request else { return }
        suggestions = values
    }

    func load(
        request: SourceSearchSuggestionRequest?,
        local: [SourceSearchSuggestion] = [],
        explicit: Bool = false,
        sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        isCurrent: @MainActor () -> Bool,
        fetch: @MainActor (SourceSearchSuggestionRequest) async throws -> [SourceSearchSuggestion],
        handleVerification: @MainActor (any Error) -> Bool
    ) async {
        let generation = gate.begin()
        if lastRequest != request { suggestions = local }
        else if !local.isEmpty { suggestions = local }
        lastRequest = request
        errorMessage = nil
        isOffline = false
        completedRequest = nil
        isAwaitingVerification = false
        isLoading = false
        isWaiting = false
        guard let request, !request.query.isEmpty else { return }
        isLoading = true
        isWaiting = true
        defer {
            if gate.accepts(generation) { isLoading = false; isWaiting = false }
        }
        do {
            guard explicit || request.query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
            if !explicit { try await sleep(.milliseconds(350)) }
            guard !Task.isCancelled, gate.accepts(generation), isCurrent() else { return }
            isWaiting = false
            let result = try await fetch(request)
            guard !Task.isCancelled, gate.accepts(generation), isCurrent() else { return }
            suggestions = result
            completedRequest = request
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, gate.accepts(generation), isCurrent() else { return }
            isAwaitingVerification = handleVerification(error)
            let networkCode = (error as? URLError)?.code
            isOffline = networkCode == .notConnectedToInternet || networkCode == .networkConnectionLost
            errorMessage = isAwaitingVerification
                ? "Complete source verification, then retry suggestions."
                : isOffline ? "You’re offline. Saved tags are still available."
                : "Couldn’t load suggestions: \(error.localizedDescription)"
        }
    }
}
