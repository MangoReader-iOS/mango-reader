import Foundation
import MangoReaderDomain

public enum SourceCatalogFilterOptionState: Equatable, Sendable {
    case off
    case included
    case excluded
}

public enum SourceCatalogFilterPolicy {
    public static func showsSorting(
        definitions: [SourceFilterDefinition],
        configuration: SourceSearchConfiguration?
    ) -> Bool {
        !orderingDefinitions(in: definitions).isEmpty
            || configuration?.sortOptions.isEmpty == false
    }

    public static func orderingDefinitions(
        in definitions: [SourceFilterDefinition]
    ) -> [SourceFilterDefinition] {
        definitions.filter { definition in
            guard definition.valueKind == .choice, !definition.options.isEmpty else { return false }
            switch definition.sourceKind {
            case .opds: return definition.key == OPDSFilterKey.order.rawValue
            case .komga: return definition.key == KomgaFilterKey.sort.rawValue
            case .kavita: return definition.key == KavitaFilterKey.sort.rawValue
            default: return false
            }
        }
    }

    public static func activeCount(
        defaults: [String: String],
        selections: [String: String],
        selectedKind: ContentKind?,
        selectedSortID: String?,
        configuration: SourceSearchConfiguration?,
        temporarySelections: [SourceSearchSelection]
    ) -> Int {
        let changedCompiledFilters = Set(defaults.keys)
            .union(selections.keys)
            .filter { defaults[$0] != selections[$0] }
            .count
        let kindCount = selectedKind == nil ? 0 : 1
        let sortCount = selectedSortID == configuration?.defaultSortID ? 0 : 1
        return changedCompiledFilters + kindCount + sortCount + temporarySelections.count
    }

    public static func optionState(
        fieldID: String,
        value: String,
        selections: [SourceSearchSelection]
    ) -> SourceCatalogFilterOptionState {
        guard let selection = selections.first(where: {
            $0.fieldID == fieldID && $0.value == value
        }) else { return .off }
        return selection.polarity == .exclude ? .excluded : .included
    }

    public static func cycling(
        field: SourceSearchField,
        optionID: String,
        optionTitle: String,
        selections: [SourceSearchSelection]
    ) -> [SourceSearchSelection] {
        var result = selections
        guard let index = result.firstIndex(where: {
            $0.fieldID == field.id && $0.value == optionID
        }) else {
            if field.maximumSelections == 1 { result.removeAll { $0.fieldID == field.id } }
            result.append(SourceSearchSelection(
                fieldID: field.id,
                value: optionID,
                title: optionTitle,
                polarity: .include
            ))
            return result
        }

        if result[index].polarity == .include, field.supportsExclusion {
            result[index].polarity = .exclude
        } else {
            result.remove(at: index)
        }
        return result
    }

    public static func sortTitle(
        selectedSortID: String?,
        configuration: SourceSearchConfiguration?
    ) -> String {
        guard let selectedSortID,
              let option = configuration?.sortOptions.first(where: { $0.id == selectedSortID })
        else { return "Default" }
        return option.title
    }

    public static func compiledValue(
        for definition: SourceFilterDefinition,
        defaults: [String: String],
        selections: [String: String]
    ) -> String {
        selections[definition.key]
            ?? defaults[definition.key]
            ?? definition.defaultValue
            ?? ""
    }

    public static func compiledTitle(
        for definition: SourceFilterDefinition,
        defaults: [String: String],
        selections: [String: String]
    ) -> String {
        let value = compiledValue(
            for: definition,
            defaults: defaults,
            selections: selections
        )
        return definition.options.first(where: { $0.value == value })?.title ?? "Any"
    }

    public static func fieldSelectionSummary(
        for field: SourceSearchField,
        selections: [SourceSearchSelection]
    ) -> String {
        let values = selections.filter { $0.fieldID == field.id }
        guard let first = values.first else { return "Any" }
        guard values.count > 1 else {
            return first.polarity == .exclude ? "Exclude \(first.title)" : first.title
        }
        return "\(values.count) selected"
    }

    public static func chipTitle(
        for selection: SourceSearchSelection,
        configuration: SourceSearchConfiguration?
    ) -> String {
        let prefix = configuration?.fields
            .first(where: { $0.id == selection.fieldID })?
            .queryPrefix ?? "\(selection.fieldID):"
        return "\(prefix)\(selection.title)"
    }

    public static func removing(
        _ selection: SourceSearchSelection,
        from selections: [SourceSearchSelection]
    ) -> [SourceSearchSelection] {
        selections.filter {
            $0.fieldID.caseInsensitiveCompare(selection.fieldID) != .orderedSame
                || $0.value.caseInsensitiveCompare(selection.value) != .orderedSame
        }
    }

    public static func reset(
        defaults: [String: String],
        configuration: SourceSearchConfiguration?,
        selectedKind: inout ContentKind?,
        selectedSortID: inout String?,
        filterSelections: inout [String: String],
        temporarySelections: inout [SourceSearchSelection]
    ) {
        selectedKind = nil
        selectedSortID = configuration?.defaultSortID
        filterSelections = defaults
        temporarySelections = []
    }
}
