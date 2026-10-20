import MangoReaderDomain
import MangoReaderSources
import SwiftUI

struct SourceCatalogSortMenu: View {
    let definitions: [SourceFilterDefinition]
    let defaults: [String: String]
    let configuration: SourceSearchConfiguration?
    @Binding var selectedSortID: String?
    @Binding var filterSelections: [String: String]
    var onSelectSort: ((String?) -> Void)? = nil

    var body: some View {
        Menu {
            NavigationMenuContent {
                if let configuration, !configuration.sortOptions.isEmpty {
                    Section("Sort Order") {
                        if let onSelectSort {
                            // Picker selection does not fire when its current value is chosen.
                            ForEach(configuration.sortOptions) { option in
                                Button {
                                    selectedSortID = option.id
                                    onSelectSort(option.id)
                                } label: {
                                    if option.id == (selectedSortID ?? configuration.defaultSortID) {
                                        Label(option.title, systemImage: "checkmark")
                                    } else {
                                        Text(option.title)
                                    }
                                }
                                .accessibilityIdentifier("source-filter-sort-\(option.id)")
                            }
                        } else {
                            Picker("Sort Order", selection: $selectedSortID) {
                                if configuration.defaultSortID == nil {
                                    Text("Default Order").tag(nil as String?)
                                }
                                ForEach(configuration.sortOptions) { option in
                                    Text(option.title).tag(option.id as String?)
                                }
                            }
                            .pickerStyle(.inline)
                            .accessibilityIdentifier("source-filter-sort")
                        }
                    }
                }

                ForEach(orderingDefinitions) { definition in
                    Section(definition.title) {
                        Picker(
                            definition.title,
                            selection: Binding(
                                get: {
                                    SourceCatalogFilterPolicy.compiledValue(
                                        for: definition, defaults: defaults, selections: filterSelections
                                    )
                                },
                                set: { filterSelections[definition.key] = $0 }
                            )
                        ) {
                            ForEach(definition.options) { option in
                                Text(option.title).tag(option.value)
                            }
                        }
                        .pickerStyle(.inline)
                        .accessibilityIdentifier("source-filter-compiled-\(definition.key)")
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Chooses the source sort order")
        .accessibilityIdentifier("source-sort-menu")
    }

    private var orderingDefinitions: [SourceFilterDefinition] {
        SourceCatalogFilterPolicy.orderingDefinitions(in: definitions)
    }

    private var accessibilityValue: String {
        var summaries = orderingDefinitions.map { definition in
            "\(definition.title): \(SourceCatalogFilterPolicy.compiledTitle(for: definition, defaults: defaults, selections: filterSelections))"
        }
        if configuration?.sortOptions.isEmpty == false {
            summaries.insert(
                SourceCatalogFilterPolicy.sortTitle(selectedSortID: selectedSortID, configuration: configuration),
                at: 0
            )
        }
        return summaries.joined(separator: ", ")
    }
}
