import Foundation
import MangoReaderDomain
import MangoReaderSources

@MainActor
final class SourceSuggestionStore {
    let scope: String
    let isPrivate: Bool
    var index = SourceSuggestionIndex() { didSet { lookups.removeAll() } }
    private struct Lookup {
        let query: String
        let fieldID: String?
        let date: Date
        let values: [SourceSearchSuggestion]
    }
    private var lookups: [Lookup] = []
    var loaded = false
    let coordinator = SourceSearchRequestCoordinator()
    init(scope: String, isPrivate: Bool) { self.scope = scope; self.isPrivate = isPrivate }
    var key: String { ContentCache.key([scope, "learnedSuggestions-v1"]) }

    func suggestions(query: String, fieldID: String?) -> [SourceSearchSuggestion] {
        let query = SourceSearchMatching.normalized(query), now = Date.now
        if let cached = lookups.first(where: { $0.query == query && $0.fieldID == fieldID && now.timeIntervalSince($0.date) < 60 }) {
            return cached.values
        }
        let values = index.suggestions(query: query, fieldID: fieldID, at: now)
        if lookups.count == 8 { lookups.removeFirst() }
        lookups.append(Lookup(query: query, fieldID: fieldID, date: now, values: values))
        return values
    }
}

extension SourcesModel {
    func suggestionStore(for id: SourceID) -> SourceSuggestionStore {
        let scope = contentCacheScope(id), isPrivate = !usesPersistentContentCache
        if let store = suggestionStores[id], store.scope == scope, store.isPrivate == isPrivate { return store }
        suggestionStores[id]?.coordinator.invalidate()
        let store = SourceSuggestionStore(scope: scope, isPrivate: isPrivate)
        suggestionStores[id] = store
        return store
    }

    func clearSourceSuggestionMemory() {
        for store in suggestionStores.values { store.coordinator.invalidate() }
        suggestionStores.removeAll()
        sourceSuggestionRevision &+= 1
    }

    func loadSourceSuggestionStore(for id: SourceID) async {
        let store = suggestionStore(for: id)
        guard !store.loaded else { return }
        store.loaded = true
        guard !store.isPrivate else { return }
        if let entry = await contentCache.entry(for: store.key),
           let saved = try? entry.decode(SourceSuggestionIndex.self),
           suggestionStore(for: id) === store {
            store.index.merge(saved)
            sourceSuggestionRevision &+= 1
        }
    }

    func localSourceSuggestions(for id: SourceID, query: String, fieldID: String?) -> [SourceSearchSuggestion] {
        _ = sourceSuggestionRevision
        return suggestionStore(for: id).suggestions(query: query, fieldID: fieldID)
    }

    func learnSourceSuggestions(_ suggestions: [SourceSearchSuggestion], for id: SourceID,
                                selected: Bool = false) async {
        let store = suggestionStore(for: id)
        await loadSourceSuggestionStore(for: id)
        guard suggestionStore(for: id) === store else { return }
        if selected { for suggestion in suggestions { store.index.selected(suggestion) } }
        else { store.index.learn(suggestions) }
        sourceSuggestionRevision &+= 1
        guard !store.isPrivate else { return }
        let token = await contentCache.writeToken()
        guard suggestionStore(for: id) === store,
              let data = try? JSONEncoder().encode(store.index) else { return }
        await contentCache.store(data, for: store.key, token: token, ttlSeconds: SourceSuggestionIndex.lifetime)
    }

    func learnSourceFacets(_ works: [Work], for id: SourceID) async {
        let suggestions = works.filter { $0.sourceID == id }.flatMap { work in
            work.searchFacets.map { SourceSearchSuggestion(fieldID: $0.fieldID, value: $0.value, title: $0.title,
                                                           subtitle: $0.groupTitle) }
        }
        guard !suggestions.isEmpty else { return }
        await learnSourceSuggestions(suggestions, for: id)
    }
}
