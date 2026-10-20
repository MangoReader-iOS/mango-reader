import Foundation
import MangoReaderReaders
import SwiftUI
import UIKit


enum SourceSkeletonVisibilityPolicy {
    static func shouldShow(isLoading: Bool, contentCount: Int) -> Bool {
        isLoading && contentCount == 0
    }
}

enum SourceSkeletonSectionKind: String, Codable, CaseIterable, Sendable {
    case shelf
    case gallery
}

struct SourceSkeletonSectionDescriptor: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String?
    var subtitle: String?
    var kind: SourceSkeletonSectionKind

    init(
        id: String,
        title: String?,
        subtitle: String? = nil,
        kind: SourceSkeletonSectionKind
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
    }
}

enum SourceSkeletonLayoutPolicy {
    static let maximumSectionCount = 6
    static let fallbackKinds: [SourceSkeletonSectionKind] = [.shelf, .gallery, .shelf]
    static let fallback: [SourceSkeletonSectionDescriptor] = fallbackKinds.enumerated().map { index, kind in
        SourceSkeletonSectionDescriptor(
            id: "fallback-\(index)",
            title: nil,
            kind: kind
        )
    }

    static func bounded(
        _ sections: [SourceSkeletonSectionDescriptor]
    ) -> [SourceSkeletonSectionDescriptor] {
        Array(sections.prefix(maximumSectionCount))
    }
}

struct SourceSkeletonLayoutStore {
    private struct Payload: Codable {
        var version: Int
        var sections: [SourceSkeletonSectionDescriptor]
    }

    private static let version = 2
    private static let keyPrefix = "sourceSkeletonLayout.v2."
    private static let legacyKeyPrefix = "sourceSkeletonLayout.v1."

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(sourceID: String) -> [SourceSkeletonSectionDescriptor] {
        if let data = defaults.data(forKey: Self.storageKey(for: sourceID)),
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           payload.version == Self.version {
            let sections = SourceSkeletonLayoutPolicy.bounded(payload.sections)
            if !sections.isEmpty {
                return sections
            }
        }

        if let rawValues = defaults.stringArray(forKey: Self.legacyStorageKey(for: sourceID)) {
            let legacySections = rawValues
                .compactMap(SourceSkeletonSectionKind.init(rawValue:))
                .enumerated()
                .map { index, kind in
                    SourceSkeletonSectionDescriptor(
                        id: "legacy-\(index)",
                        title: nil,
                        kind: kind
                    )
                }
            let sections = SourceSkeletonLayoutPolicy.bounded(legacySections)
            if !sections.isEmpty {
                return sections
            }
        }

        return SourceSkeletonLayoutPolicy.fallback
    }

    func save(_ sections: [SourceSkeletonSectionDescriptor], sourceID: String) {
        let sections = SourceSkeletonLayoutPolicy.bounded(sections)
        guard !sections.isEmpty else { return }
        let payload = Payload(version: Self.version, sections: sections)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.storageKey(for: sourceID))
    }

    static func storageKey(for sourceID: String) -> String {
        keyPrefix + sourceID
    }

    static func legacyStorageKey(for sourceID: String) -> String {
        legacyKeyPrefix + sourceID
    }
}

private struct SourceSkeletonReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var sourceSkeletonReduceMotionOverride: Bool {
        get { self[SourceSkeletonReduceMotionOverrideKey.self] }
        set { self[SourceSkeletonReduceMotionOverrideKey.self] = newValue }
    }
}

private struct SourceSkeletonShimmerModifier: ViewModifier {
    @Environment(\.sourceSkeletonReduceMotionOverride) private var reduceMotionOverride

    func body(content: Content) -> some View {
        content.loadingShimmer(active: !reduceMotionOverride)
    }
}

extension View {
    func sourceSkeletonVisual() -> some View {
        // Redaction can change text wrapping at large sizes. Measure the real
        // content and draw the placeholder within those same bounds.
        unredacted()
            .hidden()
            .overlay(alignment: .topLeading) {
                self.redacted(reason: .placeholder)
                    .modifier(SourceSkeletonShimmerModifier())
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    func sourceSkeletonContainer(accessibilityLabel: String) -> some View {
        allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    func sourceSkeletonSlot(_ isActive: Bool) -> some View {
        if isActive {
            sourceSkeletonVisual()
        } else {
            self
        }
    }

    func sourceCatalogShelfItemFrame(
        minimumCoverWidth: CGFloat,
        itemCount: Int
    ) -> some View {
        containerRelativeFrame(.horizontal, alignment: .topLeading) { length, _ in
            let contentWidth = max(
                0,
                length - (PublicationGridLayout.contentMargin * 2)
            )
            return SourceCatalogCoverLayoutPolicy.shelfLayout(
                availableWidth: contentWidth,
                minimumCoverWidth: minimumCoverWidth,
                itemCount: itemCount
            ).coverWidth
        }
    }
}

struct SourceSkeletonCover: View {
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(uiColor: .secondarySystemFill))
            .aspectRatio(2 / 3, contentMode: .fit)
            .shadow(color: .black.opacity(0.12), radius: 7, y: 4)
    }
}

struct SourceSectionHeaderLayout: View {
    let title: String
    let subtitle: String?
    var isPlaceholder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .sourceSkeletonSlot(isPlaceholder)

            if let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .sourceSkeletonSlot(isPlaceholder)
            }
        }
    }
}

struct PublicationCardLayout<Cover: View, Metadata: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    var isPlaceholder = false
    let cover: Cover
    @ViewBuilder var metadata: Metadata

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
                .frame(maxWidth: .infinity)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .fixedSize(horizontal: false, vertical: true)
                .sourceSkeletonSlot(isPlaceholder)

            VStack(alignment: .leading, spacing: 4) {
                PublicationGridTitle(title: title)
                    .sourceSkeletonSlot(isPlaceholder)

                metadata
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .sourceSkeletonSlot(isPlaceholder)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct PublicationRowLayout<Cover: View, Metadata: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scaledCoverWidth: CGFloat = 46

    let title: String
    var isPlaceholder = false
    let cover: Cover
    @ViewBuilder var metadata: Metadata
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        let coverWidth = min(max(scaledCoverWidth, 46), 84)

        layout {
            HStack(alignment: .top, spacing: 12) {
                cover
                    .frame(width: coverWidth, height: coverWidth * 1.5)
                    .sourceSkeletonSlot(isPlaceholder)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .sourceSkeletonSlot(isPlaceholder)

                    metadata
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .sourceSkeletonSlot(isPlaceholder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            trailing
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct SourceShelfCardLayout<Cover: View>: View {
    let title: String
    let metadata: String?
    var isPlaceholder = false
    let cover: Cover

    var body: some View {
        PublicationCardLayout(title: title, isPlaceholder: isPlaceholder, cover: cover) {
            if let metadata {
                Text(metadata)
            }
        }
    }
}

enum SourceGalleryTilePresentation {
    case standard
    case sourceSearch

    var showsLanguage: Bool {
        self == .sourceSearch
    }
}

struct SourceGalleryTileLayout<Cover: View>: View {
    let title: String
    let metadata: String?
    var languageCode: String? = nil
    var presentation = SourceGalleryTilePresentation.standard
    var isPlaceholder = false
    let cover: Cover

    var body: some View {
        let language = presentation.showsLanguage
            ? SourceLanguageIndicatorPolicy.content(for: languageCode)
            : nil
        PublicationCardLayout(title: title, isPlaceholder: isPlaceholder, cover: cover) {
            if presentation.showsLanguage, language != nil || metadata != nil {
                HStack(spacing: 4) {
                    if let language {
                        Text(language.displayText)
                            .accessibilityLabel(language.accessibilityLabel)
                    }
                    if let metadata {
                        Text(metadata)
                    }
                }
            } else if let metadata {
                Text(metadata)
            }
        }
    }
}

struct SourceLanguageIndicatorContent: Equatable {
    let displayText: String
    let accessibilityLabel: String
}

enum SourceLanguageIndicatorPolicy {
    private static let representativeRegions = [
        "en": "GB", "ja": "JP", "zh": "CN", "es": "ES", "fr": "FR",
        "de": "DE", "ko": "KR", "ru": "RU", "it": "IT", "pt": "PT",
        "pl": "PL", "nl": "NL", "vi": "VN", "id": "ID", "th": "TH",
        "cs": "CZ", "hu": "HU", "ar": "SA", "tr": "TR", "uk": "UA",
    ]

    static func content(for languageCode: String?) -> SourceLanguageIndicatorContent? {
        guard let languageCode else { return nil }
        let normalized = languageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        let parts = normalized.split(separator: "-").map(String.init)
        let language = parts.first ?? normalized
        let explicitRegion = parts.dropFirst().first { part in
            part.count == 2 && part.unicodeScalars.allSatisfy { scalar in
                CharacterSet.letters.contains(scalar)
            }
        }
        let region = explicitRegion?.uppercased() ?? representativeRegions[language]
        let displayText = region.flatMap(flagEmoji) ?? normalized.uppercased()
        return SourceLanguageIndicatorContent(
            displayText: displayText,
            accessibilityLabel: "Language, \(normalized.uppercased())"
        )
    }

    private static func flagEmoji(for region: String) -> String? {
        let scalars = region.uppercased().unicodeScalars
        guard scalars.count == 2,
              scalars.allSatisfy({ (65 ... 90).contains(Int($0.value)) })
        else { return nil }
        let flagScalars = scalars.compactMap { UnicodeScalar(127_397 + Int($0.value)) }
        guard flagScalars.count == 2 else { return nil }
        return String(flagScalars.map(Character.init))
    }
}

struct SourceDenseWorkRowLayout<Cover: View>: View {
    let title: String
    let latestChapterTitle: String?
    let languageCode: String?
    var isPlaceholder = false
    let cover: Cover

    var body: some View {
        let language = SourceLanguageIndicatorPolicy.content(for: languageCode)
        let latestChapter = latestChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        PublicationRowLayout(
            title: title,
            isPlaceholder: isPlaceholder,
            cover: cover,
            metadata: {
                if language != nil || latestChapter?.isEmpty == false {
                    HStack(spacing: 4) {
                        if let language {
                            Text(language.displayText)
                                .accessibilityLabel(language.accessibilityLabel)
                        }
                        if let latestChapter, !latestChapter.isEmpty {
                            Text(latestChapter)
                        }
                    }
                }
            },
            trailing: { EmptyView() }
        )
    }
}

struct SourceInstallmentRowLayout<Leading: View, Metadata: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scaledLeadingWidth: CGFloat = 30

    let title: String
    var isPlaceholder = false
    let leading: Leading
    let metadata: Metadata
    let trailing: Trailing

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))

        layout {
            HStack(alignment: .top, spacing: 12) {
                leading
                    .frame(width: min(scaledLeadingWidth, 52))
                    .sourceSkeletonSlot(isPlaceholder)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .sourceSkeletonSlot(isPlaceholder)
                    metadata
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .sourceSkeletonSlot(isPlaceholder)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .contentShape(Rectangle())
    }
}

struct SourceMigrationResultRowLayout<Cover: View, Trailing: View>: View {
    let title: String
    let authors: String?
    var isPlaceholder = false
    let cover: Cover
    let trailing: Trailing

    var body: some View {
        PublicationRowLayout(
            title: title,
            isPlaceholder: isPlaceholder,
            cover: cover,
            metadata: {
                if let authors, !authors.isEmpty {
                    Text(authors)
                }
            },
            trailing: { trailing }
        )
    }
}

struct SourceBulkStatusRowLayout<Cover: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scaledCoverWidth: CGFloat = 44
    let title: String
    let statusTitle: String
    let statusDetail: String
    var statusSystemImage = "circle"
    var statusColor: Color = .secondary
    var isIdentityPlaceholder = false
    var isStatusPlaceholder = false
    let cover: Cover

    var body: some View {
        HStack(spacing: 12) {
            cover
                .frame(width: min(scaledCoverWidth, 72))
                .sourceSkeletonSlot(isIdentityPlaceholder)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .sourceSkeletonSlot(isIdentityPlaceholder)
                Label(statusTitle, systemImage: statusSystemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .sourceSkeletonSlot(isStatusPlaceholder)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .sourceSkeletonSlot(isStatusPlaceholder)
            }
        }
    }
}

struct SourceSummaryMetric: Equatable, Identifiable {
    var id: String { label }
    let label: String
    let value: String?
}

struct SourceSummaryMetricsLayout: View {
    let metrics: [SourceSummaryMetric]

    var body: some View {
        ForEach(metrics) { metric in
            LabeledContent(metric.label) {
                if let value = metric.value {
                    Text(value)
                } else {
                    Text("000")
                        .sourceSkeletonVisual()
                }
            }
        }
    }
}

struct SourceCatalogSkeletonView: View {
    let sourceName: String
    let sections: [SourceSkeletonSectionDescriptor]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                ForEach(sections) { section in
                    SourceCatalogSkeletonSection(section: section)
                }
            }
            .padding(.vertical, 20)
        }
        .sourceSkeletonContainer(accessibilityLabel: "Connecting to \(sourceName)")
    }
}

private struct SourceCatalogSkeletonSection: View {
    let section: SourceSkeletonSectionDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title = section.title {
                SourceSectionHeaderLayout(
                    title: title,
                    subtitle: section.subtitle
                )
                .padding(.horizontal, PublicationGridLayout.contentMargin)
            } else {
                SourceSectionHeaderLayout(
                    title: "Loading source section",
                    subtitle: "Source collection description"
                )
                .sourceSkeletonVisual()
                .padding(.horizontal, PublicationGridLayout.contentMargin)
            }

            switch section.kind {
            case .shelf:
                SourceShelfSkeletonContent()
            case .gallery:
                SourceGallerySkeletonContent()
                    .padding(.horizontal, PublicationGridLayout.contentMargin)
            }
        }
    }
}

struct SourceShelfSkeletonContent: View {
    @ScaledMetric(relativeTo: .body) private var scaledMinimumCoverWidth = SourceCatalogCoverLayoutPolicy.baseMinimumWidth
    var itemCount = 6

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(
                alignment: .top,
                spacing: SourceCatalogCoverLayoutPolicy.horizontalSpacing
            ) {
                ForEach(0 ..< itemCount, id: \.self) { index in
                    SourceShelfCardLayout(
                        title: index.isMultiple(of: 2)
                            ? "Loading publication title"
                            : "Loading title",
                        metadata: index.isMultiple(of: 2)
                            ? "Latest installment"
                            : "New chapter",
                        cover: SourceSkeletonCover()
                    )
                    .sourceCatalogShelfItemFrame(
                        minimumCoverWidth: minimumCoverWidth,
                        itemCount: itemCount
                    )
                }
            }
            .padding(.horizontal, PublicationGridLayout.contentMargin)
        }
        .scrollIndicators(.hidden)
        .sourceSkeletonVisual()
    }

    private var minimumCoverWidth: CGFloat {
        SourceCatalogCoverLayoutPolicy.minimumCoverWidth(
            scaledWidth: scaledMinimumCoverWidth
        )
    }
}

struct SourceGallerySkeletonContent: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var scaledMinimumCoverWidth = SourceCatalogCoverLayoutPolicy.baseMinimumWidth
    @State private var availableWidth: CGFloat = 0
    var rowCount = 2
    var presentation = SourceGalleryTilePresentation.standard

    var body: some View {
        let minimumWidth = PublicationGridLayout.minimumWidth(
            for: dynamicTypeSize,
            horizontalSizeClass: horizontalSizeClass,
            regularMinimumWidth: minimumCoverWidth
        )
        let count = SourceCatalogCoverLayoutPolicy.skeletonCount(
            availableWidth: availableWidth,
            minimumCoverWidth: minimumWidth,
            rowCount: rowCount
        )
        LazyVGrid(
            columns: SourceCatalogCoverLayoutPolicy.columns(
                minimumCoverWidth: minimumCoverWidth,
                dynamicTypeSize: dynamicTypeSize,
                horizontalSizeClass: horizontalSizeClass
            ),
            alignment: .leading,
            spacing: PublicationGridLayout.verticalSpacing
        ) {
            ForEach(0 ..< count, id: \.self) { index in
                SourceGalleryTileLayout(
                    title: index.isMultiple(of: 2)
                        ? "Loading publication title"
                        : "Loading title",
                    metadata: index.isMultiple(of: 2)
                        ? "Latest installment"
                        : "New chapter",
                    languageCode: presentation.showsLanguage ? "en" : nil,
                    presentation: presentation,
                    cover: SourceSkeletonCover()
                )
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .sourceSkeletonVisual()
    }

    private var minimumCoverWidth: CGFloat {
        SourceCatalogCoverLayoutPolicy.minimumCoverWidth(scaledWidth: scaledMinimumCoverWidth)
    }
}

struct SourceDenseResultsSkeletonContent: View {
    var itemCount = 5

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(0 ..< itemCount, id: \.self) { index in
                SourceDenseWorkRowLayout(
                    title: index.isMultiple(of: 2)
                        ? "Loading publication title"
                        : "Loading title",
                    latestChapterTitle: "Latest installment",
                    languageCode: "EN",
                    cover: SourceSkeletonCover()
                )
                .padding(.vertical, 8)

                Divider()
            }
        }
        .sourceSkeletonVisual()
    }
}

struct SourceInstallmentSkeletonContent: View {
    var rowCount = 5

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0 ..< rowCount, id: \.self) { index in
                SourceInstallmentRowLayout(
                    title: index.isMultiple(of: 2)
                        ? "Loading installment title"
                        : "Loading chapter",
                    leading: Image(systemName: "doc.richtext")
                        .foregroundStyle(Color(uiColor: .secondarySystemFill)),
                    metadata: Text("Publication format · Date"),
                    trailing: Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                )
                .padding(.vertical, 10)

                if index < rowCount - 1 {
                    Divider()
                }
            }
        }
        .sourceSkeletonVisual()
    }
}

struct SourceMigrationResultsSkeletonContent: View {
    var rowCount = 5

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0 ..< rowCount, id: \.self) { index in
                SourceMigrationResultRowLayout(
                    title: index.isMultiple(of: 2)
                        ? "Loading publication title"
                        : "Loading title",
                    authors: index.isMultiple(of: 2) ? "Creator name" : "Author",
                    cover: SourceSkeletonCover(),
                    trailing: Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                )
                .padding(.vertical, 8)

                if index < rowCount - 1 {
                    Divider()
                }
            }
        }
        .sourceSkeletonVisual()
    }
}

struct SourceSummaryMetricsSkeletonContent: View {
    let labels: [String]

    var body: some View {
        SourceSummaryMetricsLayout(
            metrics: labels.map { SourceSummaryMetric(label: $0, value: nil) }
        )
    }
}

#Preview("Source skeletons - light") {
    SourceCatalogSkeletonView(
        sourceName: "Example Source",
        sections: SourceSkeletonLayoutPolicy.fallback
    )
}

#Preview("Source skeletons - dark RTL") {
    SourceCatalogSkeletonView(
        sourceName: "Example Source",
        sections: [
            SourceSkeletonSectionDescriptor(
                id: "popular",
                title: "Popular",
                subtitle: "Most-read titles this week",
                kind: .shelf
            ),
            SourceSkeletonSectionDescriptor(
                id: "latest",
                title: "Latest Updates",
                kind: .gallery
            ),
        ]
    )
    .preferredColorScheme(.dark)
    .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Source skeletons - accessibility reduce motion") {
    ScrollView {
        VStack(spacing: 24) {
            SourceDenseResultsSkeletonContent(itemCount: 3)
            SourceInstallmentSkeletonContent(rowCount: 3)
        }
        .padding()
        .sourceSkeletonContainer(accessibilityLabel: "Loading source content")
    }
    .dynamicTypeSize(.accessibility2)
    .environment(\.sourceSkeletonReduceMotionOverride, true)
}

private struct SourceFixturePreviewCover: View {
    var body: some View {
        LinearGradient(
            colors: [.indigo, .cyan.opacity(0.65)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 7, y: 4)
    }
}

private struct SourceResponsiveCoverPreview: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var scaledMinimumCoverWidth = SourceCatalogCoverLayoutPolicy.baseMinimumWidth

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                SourceSectionHeaderLayout(
                    title: "Responsive shelf",
                    subtitle: "Loaded and loading cards share the viewport width"
                )
                .padding(.horizontal, PublicationGridLayout.contentMargin)

                ScrollView(.horizontal) {
                    LazyHStack(
                        alignment: .top,
                        spacing: SourceCatalogCoverLayoutPolicy.horizontalSpacing
                    ) {
                        ForEach(0 ..< 8, id: \.self) { index in
                            if index.isMultiple(of: 2) {
                                SourceShelfCardLayout(
                                    title: "Loaded shelf title",
                                    metadata: "Chapter 42",
                                    cover: SourceFixturePreviewCover()
                                )
                                .sourceCatalogShelfItemFrame(
                                    minimumCoverWidth: minimumCoverWidth,
                                    itemCount: 8
                                )
                            } else {
                                SourceShelfCardLayout(
                                    title: "Loading publication title",
                                    metadata: "Latest installment",
                                    isPlaceholder: true,
                                    cover: SourceSkeletonCover()
                                )
                                .sourceCatalogShelfItemFrame(
                                    minimumCoverWidth: minimumCoverWidth,
                                    itemCount: 8
                                )
                            }
                        }
                    }
                    .padding(.horizontal, PublicationGridLayout.contentMargin)
                }
                .scrollIndicators(.hidden)

                SourceSectionHeaderLayout(
                    title: "Responsive gallery",
                    subtitle: "Adaptive columns use the same minimum density target"
                )
                .padding(.horizontal, PublicationGridLayout.contentMargin)

                LazyVGrid(
                    columns: SourceCatalogCoverLayoutPolicy.columns(
                        minimumCoverWidth: minimumCoverWidth,
                        dynamicTypeSize: dynamicTypeSize,
                        horizontalSizeClass: horizontalSizeClass
                    ),
                    alignment: .leading,
                    spacing: PublicationGridLayout.verticalSpacing
                ) {
                    ForEach(0 ..< 10, id: \.self) { index in
                        if index.isMultiple(of: 2) {
                            SourceGalleryTileLayout(
                                title: "Loaded gallery title",
                                metadata: "Chapter 18",
                                cover: SourceFixturePreviewCover()
                            )
                        } else {
                            SourceGalleryTileLayout(
                                title: "Loading gallery title",
                                metadata: "Latest installment",
                                isPlaceholder: true,
                                cover: SourceSkeletonCover()
                            )
                        }
                    }
                }
                .padding(.horizontal, PublicationGridLayout.contentMargin)
            }
            .padding(.vertical, 20)
        }
    }

    private var minimumCoverWidth: CGFloat {
        SourceCatalogCoverLayoutPolicy.minimumCoverWidth(
            scaledWidth: scaledMinimumCoverWidth
        )
    }
}

#Preview("Responsive covers - iPhone") {
    SourceResponsiveCoverPreview()
        .frame(width: 390, height: 844)
}

#Preview("Responsive covers - iPad portrait") {
    SourceResponsiveCoverPreview()
        .frame(width: 834, height: 900)
}

#Preview("Responsive covers - iPad landscape") {
    SourceResponsiveCoverPreview()
        .frame(width: 1_194, height: 700)
}

#Preview("Responsive covers - split width") {
    SourceResponsiveCoverPreview()
        .frame(width: 600, height: 800)
}

#Preview("Responsive covers - accessibility") {
    SourceResponsiveCoverPreview()
        .frame(width: 834, height: 900)
        .dynamicTypeSize(.accessibility2)
}

#Preview("Fixture-accurate component pairs") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            GroupBox("Shelf card") {
                HStack(alignment: .top, spacing: 18) {
                    SourceShelfCardLayout(
                        title: "Loaded shelf title",
                        metadata: "Chapter 42",
                        cover: SourceFixturePreviewCover()
                    )
                    SourceShelfCardLayout(
                        title: "Loading publication title",
                        metadata: "Latest installment",
                        isPlaceholder: true,
                        cover: SourceSkeletonCover()
                    )
                }
            }

            GroupBox("Gallery tile") {
                HStack(alignment: .top, spacing: 18) {
                    SourceGalleryTileLayout(
                        title: "Loaded gallery title",
                        metadata: "Chapter 18",
                        cover: SourceFixturePreviewCover()
                    )
                    SourceGalleryTileLayout(
                        title: "Loading gallery title",
                        metadata: "Latest installment",
                        isPlaceholder: true,
                        cover: SourceSkeletonCover()
                    )
                }
            }

            GroupBox("Dense result") {
                VStack(spacing: 12) {
                    SourceDenseWorkRowLayout(
                        title: "Loaded dense result",
                        latestChapterTitle: "Chapter 12",
                        languageCode: "EN",
                        cover: SourceFixturePreviewCover()
                    )
                    SourceDenseWorkRowLayout(
                        title: "Loading publication title",
                        latestChapterTitle: "Latest installment",
                        languageCode: "EN",
                        isPlaceholder: true,
                        cover: SourceSkeletonCover()
                    )
                }
            }

            GroupBox("Installment row") {
                VStack(spacing: 12) {
                    SourceInstallmentRowLayout(
                        title: "Chapter 42",
                        leading: Image(systemName: "photo.on.rectangle"),
                        metadata: Text("Image Sequence · Aug 3, 2026"),
                        trailing: Image(systemName: "chevron.right")
                    )
                    SourceInstallmentRowLayout(
                        title: "Loading installment title",
                        isPlaceholder: true,
                        leading: Image(systemName: "doc.richtext"),
                        metadata: Text("Publication format · Date"),
                        trailing: Image(systemName: "chevron.right")
                    )
                }
            }

            GroupBox("Migration result") {
                VStack(spacing: 12) {
                    SourceMigrationResultRowLayout(
                        title: "Loaded migration result",
                        authors: "Creator name",
                        cover: SourceFixturePreviewCover(),
                        trailing: Image(systemName: "chevron.right")
                    )
                    SourceMigrationResultRowLayout(
                        title: "Loading migration result",
                        authors: "Creator name",
                        isPlaceholder: true,
                        cover: SourceSkeletonCover(),
                        trailing: Image(systemName: "chevron.right")
                    )
                }
            }

            GroupBox("Summary metrics") {
                VStack(spacing: 12) {
                    SourceSummaryMetricsLayout(
                        metrics: [
                            SourceSummaryMetric(label: "Matched", value: "12"),
                            SourceSummaryMetric(label: "Ambiguous", value: "0"),
                        ]
                    )
                    Divider()
                    SourceSummaryMetricsLayout(
                        metrics: [
                            SourceSummaryMetric(label: "Matched", value: nil),
                            SourceSummaryMetric(label: "Ambiguous", value: nil),
                        ]
                    )
                }
            }

            GroupBox("Bulk status") {
                VStack(spacing: 12) {
                    SourceBulkStatusRowLayout(
                        title: "Known selected title",
                        statusTitle: "Ready",
                        statusDetail: "Exact match found",
                        statusSystemImage: "checkmark.circle.fill",
                        statusColor: .green,
                        cover: SourceFixturePreviewCover()
                    )
                    SourceBulkStatusRowLayout(
                        title: "Known selected title",
                        statusTitle: "Checking match",
                        statusDetail: "Comparing source installments",
                        isStatusPlaceholder: true,
                        cover: SourceFixturePreviewCover()
                    )
                }
            }
        }
        .padding()
    }
}

/// Content placeholders share the destination's layout; operation feedback uses native progress.
struct AppContentSkeleton: View {
    enum Kind: String, CaseIterable { case grid, rows, textRows, chapters, metrics, preview, filters }
    let kind: Kind
    var count = 6
    var label = String(localized: "Loading content")
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            switch kind {
            case .grid:
                LazyVGrid(columns: PublicationGridLayout.columns(for: dynamicTypeSize, horizontalSizeClass: horizontalSizeClass),
                          alignment: .leading, spacing: PublicationGridLayout.verticalSpacing) {
                    ForEach(0..<count, id: \.self) { _ in
                        PublicationCardLayout(title: "Publication title", cover: SourceSkeletonCover()) {
                            EmptyView()
                        }
                        .sourceSkeletonVisual()
                    }
                }.frame(maxWidth: .infinity)
            case .rows:
                SourceMigrationResultsSkeletonContent(rowCount: count)
            case .chapters:
                SourceInstallmentSkeletonContent(rowCount: count)
            case .textRows:
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(0..<count, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            block(height: 18).frame(maxWidth: 240)
                            block(height: 12)
                            block(height: 12).frame(maxWidth: 300)
                        }
                        Divider()
                    }
                }.loadingShimmer()
            case .metrics:
                VStack(spacing: AppLayout.sectionSpacing) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) { metricPlaceholders }
                        VStack(alignment: .leading, spacing: 14) { metricPlaceholders }
                    }.sourceSkeletonVisual()
                    VStack(alignment: .leading, spacing: 8) {
                        block(height: 18).frame(maxWidth: 160)
                        HStack(spacing: 4) {
                            ForEach(0..<12, id: \.self) { _ in
                                VStack(spacing: 4) {
                                    ForEach(0..<7, id: \.self) { _ in
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color(uiColor: .secondarySystemFill))
                                            .aspectRatio(1, contentMode: .fit)
                                    }
                                }
                            }
                        }
                    }.loadingShimmer()
                    SourceShelfSkeletonContent(itemCount: 4)
                }
            case .preview:
                Rectangle().fill(Color(uiColor: .secondarySystemFill)).aspectRatio(1, contentMode: .fit).loadingShimmer()
            case .filters:
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { _ in
                            Capsule().fill(Color(uiColor: .secondarySystemFill)).frame(width: 90, height: 32)
                        }
                    }
                }.scrollIndicators(.hidden).loadingShimmer()
            }
        }
        .sourceSkeletonContainer(accessibilityLabel: label)
    }

    private var metricPlaceholders: some View {
        ForEach(["Pages", "Sessions", "Time"], id: \.self) { title in
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption)
                Text("000").font(.title2.weight(.semibold))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func block(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Color(uiColor: .secondarySystemFill)).frame(height: height)
    }
}

#if DEBUG
/// Held loading states for manual verification without changing stored user data.
struct LoadingVerificationView: View {
    @State private var showSourceGallery = false
    @State private var sourceGalleryRows = 2
    @State private var kind = AppContentSkeleton.Kind.grid
    @State private var showCovers = false
    @State private var showReader = false
    @State private var showText = false
    @State private var state = "Loading"

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let layout = arguments.first { $0.hasPrefix("--loading-layout=") }?.split(separator: "=").last.map(String.init)
        _showSourceGallery = State(initialValue: arguments.contains("--loading-source-gallery"))
        _sourceGalleryRows = State(initialValue: arguments.contains("--loading-more") ? 1 : 2)
        _kind = State(initialValue: layout.flatMap(AppContentSkeleton.Kind.init(rawValue:)) ?? .grid)
        _showCovers = State(initialValue: arguments.contains("--loading-covers"))
        _showReader = State(initialValue: arguments.contains("--loading-reader"))
        _showText = State(initialValue: arguments.contains("--loading-text"))
        _state = State(initialValue: arguments.contains("--loading-failed") ? "Failed" : "Loading")
    }

    var body: some View {
        VStack {
            Toggle("Source gallery", isOn: $showSourceGallery)
            if showSourceGallery {
                Picker("Loading rows", selection: $sourceGalleryRows) {
                    Text("Initial").tag(2)
                    Text("More").tag(1)
                }.pickerStyle(.segmented)
                ScrollView {
                    SourceGallerySkeletonContent(rowCount: sourceGalleryRows)
                        .environment(\.sourceSkeletonReduceMotionOverride, ProcessInfo.processInfo.arguments.contains("--loading-reduce-motion"))
                        .sourceSkeletonContainer(accessibilityLabel: "Loading source titles")
                }
            } else {
                Toggle("Cover placeholders", isOn: $showCovers)
                if showCovers {
                    CoverPlaceholderVerificationView()
                } else {
                    contentVerification
                }
            }
        }.padding(.horizontal, AppLayout.pageMargin)
            .navigationTitle("Loading Verification")
            .toolbarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .appBackground()
    }

    private var contentVerification: some View {
        VStack {
            Picker("Content layout", selection: $kind) {
                ForEach(AppContentSkeleton.Kind.allCases, id: \.self) { kind in Text(kind.rawValue.capitalized).tag(kind) }
            }.pickerStyle(.menu)
            Toggle("Reader page", isOn: $showReader)
            Toggle("Text page", isOn: $showText)
            HStack {
                Button("Complete") { state = "Complete" }
                Button("Fail") { state = "Failed" }
                Button("Reset") { state = "Loading" }
            }.buttonStyle(.bordered)
            if state == "Loading" {
                if showReader { ReaderContentSkeleton(layout: showText ? .text : .page) }
                else { ScrollView { AppContentSkeleton(kind: kind).padding(AppLayout.pageMargin) } }
            } else if state == "Failed" {
                ContentUnavailableView("Couldn’t load content", systemImage: "exclamationmark.triangle")
                Button("Retry") { state = "Loading" }
            } else {
                ContentUnavailableView("Content loaded", systemImage: "checkmark")
            }
            HStack {
                ProgressView("Saving changes…")
                Button("Save") {}.disabled(true)
                Button("Cancel") { state = "Complete" }
            }
        }
    }
}
#endif
