import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import Observation
import PhotosUI
import SwiftUI

struct WorkMetadataSearchItem: Identifiable, Equatable {
    let id: String
    let title: String
    let searchRoute: SourceMetadataSearchRoute?
}

struct WorkMetadataSearchGroup: Identifiable, Equatable {
    let id: String
    let title: String?
    let items: [WorkMetadataSearchItem]
}

enum WorkMetadataSearchPolicy {
    static func authorItems(
        for work: Work,
        sources: [SourceDescriptor]
    ) -> [WorkMetadataSearchItem] {
        let source = searchableSource(for: work, sources: sources)
        let facets = work.searchFacets.filter { $0.presentation == .creator }
        let titles = normalizedDisplayValues(work.authors.flatMap { value in
            facets.contains { canonicalValue($0.title) == canonicalValue(value) }
                ? [value] : normalizedAuthorValues([value])
        })
        return titles.enumerated().map { index, title in
            let facet = facets.first { canonicalValue($0.title) == canonicalValue(title) }
            let exactRoute = facet.flatMap { facetItems([$0], identifierPrefix: "author", source: source).first?.searchRoute }
            return WorkMetadataSearchItem(
                id: "author-\(index)", title: title,
                searchRoute: exactRoute ?? textSearchRoute(title: title, source: source)
            )
        }
    }

    static func tagItems(
        for work: Work,
        sources: [SourceDescriptor]
    ) -> [WorkMetadataSearchItem] {
        tagGroups(for: work, sources: sources).flatMap(\.items)
    }

    static func tagGroups(
        for work: Work,
        sources: [SourceDescriptor]
    ) -> [WorkMetadataSearchGroup] {
        let source = searchableSource(for: work, sources: sources)
        let titles = normalizedDisplayValues(work.tags)
        let allowed = Set(titles.map(canonicalValue))
        let facets = work.searchFacets.filter { $0.presentation == .tag && allowed.contains(canonicalValue($0.title)) }
        var groups: [(title: String?, facets: [WorkSearchFacet])] = []
        for facet in facets {
            let title = normalizedGroupTitle(facet.groupTitle)
            if let index = groups.firstIndex(where: { $0.title.map(canonicalValue) == title.map(canonicalValue) }) {
                groups[index].facets.append(facet)
            } else { groups.append((title, [facet])) }
        }
        var result = groups.enumerated().map { index, group in
            WorkMetadataSearchGroup(id: "tag-group-\(index)", title: group.title,
                items: facetItems(group.facets, identifierPrefix: "tag-\(index)", source: source).map { item in
                    WorkMetadataSearchItem(id: item.id,
                        title: titles.first { canonicalValue($0) == canonicalValue(item.title) } ?? item.title,
                        searchRoute: item.searchRoute)
                })
        }
        let matched = Set(facets.map { canonicalValue($0.title) })
        let custom = titles.filter { !matched.contains(canonicalValue($0)) }.enumerated().map { index, title in
            WorkMetadataSearchItem(id: "tag-custom-\(index)", title: title, searchRoute: nil)
        }
        if !custom.isEmpty { result.append(WorkMetadataSearchGroup(id: "tag-custom", title: nil, items: custom)) }
        return result
    }

    private static func searchableSource(
        for work: Work,
        sources: [SourceDescriptor]
    ) -> SourceDescriptor? {
        guard work.sourceID != .local else { return nil }
        return sources.first {
            $0.id == work.sourceID
                && $0.isEnabled
                && $0.capabilities.contains(.search)
        }
    }

    private static func facetItems(
        _ facets: [WorkSearchFacet],
        identifierPrefix: String,
        source: SourceDescriptor?
    ) -> [WorkMetadataSearchItem] {
        var seen: Set<String> = []
        var items: [WorkMetadataSearchItem] = []
        for facet in facets {
            let title = facet.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(canonicalValue(title)).inserted else { continue }
            let fieldID = facet.fieldID.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = facet.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let route = source.map { source in
                guard !fieldID.isEmpty, !value.isEmpty else {
                    return source.kind == .mangoReaderExtension
                        ? nil
                        : SourceMetadataSearchRoute(source: source, query: title)
                }
                return SourceMetadataSearchRoute(
                    source: source,
                    selections: [
                        SourceSearchSelection(fieldID: fieldID, value: value, title: title),
                    ]
                )
            } ?? nil
            items.append(WorkMetadataSearchItem(
                id: "\(identifierPrefix)-\(items.count)",
                title: title,
                searchRoute: route
            ))
        }
        return items
    }

    private static func textSearchRoute(
        title: String,
        source: SourceDescriptor?
    ) -> SourceMetadataSearchRoute? {
        guard let source, source.kind != .mangoReaderExtension else { return nil }
        return SourceMetadataSearchRoute(source: source, query: title)
    }

    private static func normalizedAuthorValues(_ values: [String]) -> [String] {
        normalizedDisplayValues(values.flatMap { value in
            value.components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
        })
    }

    private static func normalizedDisplayValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(canonicalValue(trimmed)).inserted else {
                return nil
            }
            return trimmed
        }
    }

    private static func normalizedGroupTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func canonicalValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }
}

private struct WorkMetadataAuthorsView: View {
    let items: [WorkMetadataSearchItem]
    let openSearch: OpenSourceMetadataSearchAction

    var body: some View {
        GlassCapsuleGroup(spacing: GlassCapsuleLayout.effectContainerSpacing) {
            MetadataFlowLayout(
                horizontalSpacing: GlassCapsuleLayout.compactSpacing,
                verticalSpacing: GlassCapsuleLayout.compactSpacing
            ) {
                Text("Authors:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("work-detail-author-group")
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if let route = item.searchRoute {
                        Button {
                            openSearch(route)
                        } label: {
                            GlassCapsuleLabel(
                                title: item.title,
                                isInteractive: true,
                                allowsMultiline: true,
                                size: .metadataCompact
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Search for author \(item.title)")
                        .accessibilityHint("Opens a search in \(route.source.name). Go back to return to this title.")
                        .accessibilityInputLabels([
                            Text(item.title),
                            Text("Search \(item.title)"),
                        ])
                        .accessibilityIdentifier("work-detail-author-\(index)")
                    } else {
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: 44)
                        .accessibilityIdentifier("work-detail-author-\(index)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkMetadataTagsView: View {
    let authors: [WorkMetadataSearchItem]
    let groups: [WorkMetadataSearchGroup]
    let openSearch: OpenSourceMetadataSearchAction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                GlassCapsuleGroup(spacing: GlassCapsuleLayout.effectContainerSpacing) {
                    MetadataFlowLayout(
                        horizontalSpacing: GlassCapsuleLayout.compactSpacing,
                        verticalSpacing: GlassCapsuleLayout.compactSpacing
                    ) {
                        if let title = group.title {
                            Text("\(title):")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(minHeight: 44)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("work-detail-tag-group-\(groupIndex)")
                        }
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { itemIndex, item in
                            if let route = item.searchRoute {
                                Button {
                                    openSearch(route)
                                } label: {
                                    GlassCapsuleLabel(
                                        title: item.title,
                                        isInteractive: true,
                                        allowsMultiline: true,
                                        size: .metadataCompact
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    searchLabel(
                                        for: item.title,
                                        group: group.title
                                    )
                                )
                                .accessibilityHint("Opens a search in \(route.source.name). Go back to return to this title.")
                                .accessibilityInputLabels([
                                    Text(item.title),
                                    Text("Search \(item.title)"),
                                ])
                                .accessibilityIdentifier("work-detail-tag-\(groupIndex)-\(itemIndex)")
                            } else {
                                Text(item.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(minHeight: 44)
                                .accessibilityIdentifier("work-detail-tag-\(groupIndex)-\(itemIndex)")
                            }
                        }
                    }
                }
            }
            if !authors.isEmpty {
                WorkMetadataAuthorsView(
                    items: authors,
                    openSearch: openSearch
                )
            }
        }
    }

    private func searchLabel(
        for title: String,
        group: String?
    ) -> String {
        if let group {
            return "Search for \(group.lowercased()) tag \(title)"
        }
        return "Search for tag \(title)"
    }
}

private struct MetadataFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        for index in subviews.indices {
            let position = result.positions[index]
            let size = result.sizes[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }

    private func layout(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, sizes: [CGSize], positions: [CGPoint]) {
        guard !subviews.isEmpty else {
            return (.zero, [], [])
        }

        let proposedWidth = proposal.width.map { max(0, $0) }
        let maximumWidth = proposedWidth ?? .infinity
        let subviewProposal = ProposedViewSize(
            width: maximumWidth.isFinite ? maximumWidth : nil,
            height: nil
        )
        let sizes = subviews.map { $0.sizeThatFits(subviewProposal) }
        var positions: [CGPoint] = []
        positions.reserveCapacity(sizes.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for size in sizes {
            if x > 0, x + size.width > maximumWidth {
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: x, y: y))
            contentWidth = max(contentWidth, x + size.width)
            lineHeight = max(lineHeight, size.height)
            x += size.width + horizontalSpacing
        }

        return (
            CGSize(width: proposedWidth ?? contentWidth, height: y + lineHeight),
            sizes,
            positions
        )
    }
}
