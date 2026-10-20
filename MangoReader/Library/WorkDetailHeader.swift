import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import Observation
import PhotosUI
import SwiftUI

struct WorkDetailHeader<Options: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let work: Work
    let authorItems: [WorkMetadataSearchItem]
    let isInLibrary: Bool
    let canRead: Bool
    let isLoadingInstallments: Bool
    let isUpdatingCover: Bool
    let isPreparingReader: Bool
    let isUpdatingLibraryMembership: Bool
    let continuationTitle: String?
    let onRead: () -> Void
    let onToggleLibrary: () -> Void
    let options: Options

    init(
        work: Work,
        authorItems: [WorkMetadataSearchItem],
        isInLibrary: Bool,
        canRead: Bool,
        isLoadingInstallments: Bool = false,
        isUpdatingCover: Bool,
        isPreparingReader: Bool,
        isUpdatingLibraryMembership: Bool,
        continuationTitle: String? = nil,
        onRead: @escaping () -> Void,
        onToggleLibrary: @escaping () -> Void,
        @ViewBuilder options: () -> Options
    ) {
        self.work = work
        self.authorItems = authorItems
        self.isInLibrary = isInLibrary
        self.canRead = canRead
        self.isLoadingInstallments = isLoadingInstallments
        self.isUpdatingCover = isUpdatingCover
        self.isPreparingReader = isPreparingReader
        self.isUpdatingLibraryMembership = isUpdatingLibraryMembership
        self.continuationTitle = continuationTitle
        self.onRead = onRead
        self.onToggleLibrary = onToggleLibrary
        self.options = options()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    title
                    if !authorItems.isEmpty {
                        authors
                    }
                    HStack(alignment: .bottom, spacing: 16) {
                        cover
                        secondaryActions
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 16) {
                    cover
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            title
                            if !authorItems.isEmpty {
                                authors
                            }
                        }

                        Spacer(minLength: 8)

                        secondaryActions
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 168,
                        alignment: .topLeading
                    )
                }
            }
            if canRead || isLoadingInstallments {
                readButton
                if let continuationTitle {
                    Text(continuationTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Continue with \(continuationTitle)")
                        .accessibilityIdentifier("work-detail-continuation")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: some View {
        Text(work.title)
            .font(.title3.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .textSelection(.enabled)
            .accessibilityIdentifier("work-detail-title")
    }

    private var cover: some View {
        RemoteCover(work: work)
            .frame(width: 112, height: 168)
            .overlay {
                if isUpdatingCover {
                    ProgressView("Updating cover…")
                        .font(.caption)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .accessibilityIdentifier("work-detail-cover")
    }

    private var authors: some View {
        Text(authorNames)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(AppDynamicTypeSizing.contentLineLimit(1, for: dynamicTypeSize))
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Authors: \(authorNames)")
            .accessibilityIdentifier("work-detail-author-byline")
    }

    private var authorNames: String {
        authorItems.map(\.title).joined(separator: ", ")
    }

    private var secondaryActions: some View {
        GlassCapsuleGroup(spacing: 8) {
            HStack(spacing: 8) {
                if work.sourceID != .local {
                    libraryButton
                }
                options
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var libraryButton: some View {
        Button(action: onToggleLibrary) {
            WorkDetailHeaderIconLabel(
                systemImage: isInLibrary ? "bookmark.fill" : "bookmark",
                isSelected: isInLibrary
            )
        }
        .buttonStyle(.plain)
        .disabled(isUpdatingLibraryMembership)
        .accessibilityLabel(isInLibrary ? "Remove from Library" : "Add to Library")
        .accessibilityValue(isInLibrary ? "Saved" : "Not Saved")
        .accessibilityHint("Toggles whether this title appears in Library and receives update checks")
        .accessibilityIdentifier("work-detail-library-bookmark")
    }

    private var readButton: some View {
        Button(action: onRead) {
            Text("Read")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 44)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    if isPreparingReader || isLoadingInstallments {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AppColors.onAction)
                            .padding(.leading, 16)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(WorkDetailReadButtonStyle(height: actionDimension, isPreparing: isPreparingReader))
        .layoutPriority(1)
        .disabled(isPreparingReader || !canRead)
        .accessibilityLabel("Read")
        .accessibilityValue(isLoadingInstallments ? "Loading installments" : isPreparingReader ? "Preparing reader" : "")
        .accessibilityIdentifier("work-detail-read")
    }

    private var actionDimension: CGFloat {
        AppDynamicTypeSizing.iconControlDimension
    }
}

private struct WorkDetailReadButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let height: CGFloat
    let isPreparing: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppColors.onAction)
            .frame(maxWidth: .infinity)
            .frame(minHeight: height)
            .background(AppColors.actionFill, in: Capsule())
            .contentShape(Capsule())
            .opacity(isPreparing ? 1 : (isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct WorkDetailHeaderIconLabel: View {
    let systemImage: String
    var isSelected = false

    @ViewBuilder
    var body: some View {
#if targetEnvironment(macCatalyst)
        fallbackLabel
#else
        if #available(iOS 26.0, *) {
            labelContent
                .foregroundStyle(isSelected ? AppColors.action : Color.primary)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            fallbackLabel
        }
#endif
    }

    private var labelContent: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .appIconControlFrame()
            .contentShape(Circle())
    }

    private var fallbackLabel: some View {
        labelContent
            .foregroundStyle(isSelected ? AppColors.action : Color.primary)
            .background(AppColors.tertiaryFill, in: Circle())
    }
}

extension View {
    func workDetailFlatListRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    func workDetailInstallmentListRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.visible)
            .appFullWidthListSeparator()
    }

}
