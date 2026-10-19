import MankoDomain
import MankoReaders
import MankoSources
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LibraryGridCell: View {
    @Environment(WorkDetailReaderPreparation.self) private var readerPreparation
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let work: Work
    let isBulkSelected: Bool
    let isDetailSelected: Bool

    private var entry: LibraryEntry? { model.libraryModel.libraryEntries[work.id] }

    var body: some View {
        PublicationCardLayout(title: work.title, cover: cover) {
            EmptyView()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isBulkSelected || isDetailSelected ? .isSelected : [])
    }

    private var cover: some View {
        ZStack(alignment: .topTrailing) {
            RemoteCover(work: work, animatesLoadingPlaceholder: false)
                .overlay {
                    if isBulkSelected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(colorSchemeContrast == .increased ? 0.26 : 0.18))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if model.libraryModel.pinnedWorkIDs.contains(work.id) {
                        Image(systemName: "pin.fill")
                            .font(.caption).padding(6).background(.thickMaterial, in: Circle())
                            .padding(7).accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let entry, entry.unreadCount > 0 {
                        LibraryUnreadIndicator(
                            count: entry.unreadCount,
                            usesMaterialBackground: true
                        )
                        .padding(7)
                    }
                }
            if isBulkSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(AppColors.onAction, AppColors.actionFill)
                    .padding(8)
                    .accessibilityHidden(true)
            }
            if readerPreparation.isPreparing, readerPreparation.workID == work.id {
                ProgressView("Preparing…")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var accessibilitySummary: String {
        var components = [work.title]
        if let entry, entry.unreadCount > 0 {
            components.append("\(entry.unreadCount) unread")
        }
        if model.libraryModel.pinnedWorkIDs.contains(work.id) { components.append("Pinned") }
        return components.joined(separator: ", ")
    }
}

struct LibraryListCell: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkDetailReaderPreparation.self) private var readerPreparation
    let work: Work

    private var entry: LibraryEntry? { model.libraryModel.libraryEntries[work.id] }

    private var secondaryLabel: String {
        work.authors.joined(separator: ", ")
    }

    var body: some View {
        PublicationRowLayout(
            title: work.title,
            cover: RemoteCover(work: work, animatesLoadingPlaceholder: false)
                .overlay(alignment: .bottomLeading) {
                    if let entry, entry.unreadCount > 0 {
                        LibraryUnreadIndicator(
                            count: entry.unreadCount,
                            usesMaterialBackground: true
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(3)
                        .allowsHitTesting(false)
                    }
                },
            metadata: {
                if !secondaryLabel.isEmpty {
                    Text(secondaryLabel)
                }
            },
            trailing: {
                if model.libraryModel.pinnedWorkIDs.contains(work.id) {
                    Image(systemName: "pin.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                if readerPreparation.isPreparing, readerPreparation.workID == work.id {
                    ProgressView().controlSize(.small).accessibilityLabel("Preparing reader")
                }
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var components = [work.title, secondaryLabel].filter { !$0.isEmpty }
        if let entry, entry.unreadCount > 0 {
            components.append("\(entry.unreadCount) unread")
        }
        if model.libraryModel.pinnedWorkIDs.contains(work.id) { components.append("Pinned") }
        return components.joined(separator: ", ")
    }
}

private struct LibraryUnreadIndicator: View {
    @ScaledMetric(relativeTo: .caption2) private var scaledHorizontalPadding: CGFloat = 7
    @ScaledMetric(relativeTo: .caption2) private var scaledVerticalPadding: CGFloat = 4
    let count: Int
    let usesMaterialBackground: Bool

    @ViewBuilder
    var body: some View {
        if usesMaterialBackground {
            indicator
                .padding(.horizontal, min(scaledHorizontalPadding, 14))
                .padding(.vertical, min(scaledVerticalPadding, 10))
                .background(.thickMaterial, in: Capsule())
        } else {
            indicator
        }
    }

    private var indicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .foregroundStyle(AppColors.information)
            Text(count.formatted())
                .foregroundStyle(.primary)
        }
        .font(.caption2.weight(.bold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) unread")
    }
}

/// A native collection owns interaction and draws its selection behind hosted cards.
struct NativeLibraryGrid<Card: View, Header: View>: UIViewControllerRepresentable {
    let works: [Work]
    @Binding var selection: Set<WorkID>
    let isSelecting: Bool
    let isSelectionEnabled: Bool
    let textSize: DynamicTypeSize
    let showsHeader: Bool
    let animatesChanges: Bool
    let onBeginDragging: () -> Void
    let contextMenu: (Work) -> UIMenu?
    @ViewBuilder var card: (Work) -> Card
    @ViewBuilder var header: () -> Header
    @Environment(\.refresh) private var refresh

    func makeUIViewController(context: Context) -> Controller {
        Controller(grid: self)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(grid: self)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.refreshTask?.cancel()
    }

    final class Controller: UICollectionViewController {
        private var grid: NativeLibraryGrid
        private var dataSource: UICollectionViewDiffableDataSource<Int, WorkID>!
        private var worksByID: [WorkID: Work] = [:]
        private var appliedSelection: Set<WorkID> = []
        fileprivate var refreshTask: Task<Void, Never>?

        init(grid: NativeLibraryGrid) {
            self.grid = grid
            super.init(collectionViewLayout: UICollectionViewFlowLayout())
            clearsSelectionOnViewWillAppear = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            collectionView.backgroundColor = .clear
            collectionView.accessibilityIdentifier = "library-grid-scroll"
            collectionView.keyboardDismissMode = .interactive
            collectionView.alwaysBounceVertical = true
            collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "card")
            collectionView.register(NativeLibraryGridHeader.self,
                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                withReuseIdentifier: "header")
            collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { [weak self] _, environment in
                self?.section(in: environment)
            }
            dataSource = UICollectionViewDiffableDataSource<Int, WorkID>(collectionView: collectionView) { [weak self] collection, indexPath, id in
                guard let self, let work = self.worksByID[id] else { return nil }
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath)
                cell.backgroundConfiguration = cell.defaultBackgroundConfiguration()
                cell.contentConfiguration = UIHostingConfiguration {
                    self.grid.card(work)
                        .id(work.id)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { [weak self] in self?.activate(id) }
                }
                .margins(.all, 8)
                return cell
            }
            dataSource.supplementaryViewProvider = { [weak self] collection, kind, indexPath in
                guard let self else { return nil }
                let header = collection.dequeueReusableSupplementaryView(ofKind: kind,
                    withReuseIdentifier: "header", for: indexPath) as! NativeLibraryGridHeader
                header.configure(self.grid.header())
                return header
            }
            let refreshControl = UIRefreshControl()
            refreshControl.addAction(UIAction { [weak self] _ in self?.refreshLibrary() }, for: .valueChanged)
            collectionView.refreshControl = refreshControl
            update(grid: grid)
        }

        func update(grid: NativeLibraryGrid) {
            let layoutChanged = self.grid.textSize != grid.textSize || self.grid.showsHeader != grid.showsHeader
                || self.grid.isSelecting != grid.isSelecting
                || self.grid.isSelectionEnabled != grid.isSelectionEnabled
            let nextWorks = Dictionary(uniqueKeysWithValues: grid.works.map { ($0.id, $0) })
            let selection = grid.selection
            let contentChanged = worksByID != nextWorks || appliedSelection != selection || layoutChanged
            let orderChanged = isViewLoaded && dataSource.snapshot().itemIdentifiers != grid.works.map(\.id)
            self.grid = grid
            guard isViewLoaded else { return }
            worksByID = nextWorks
            if collectionView.allowsMultipleSelection != grid.isSelecting {
                collectionView.allowsMultipleSelection = grid.isSelecting
            }
            collectionView.allowsSelection = grid.isSelectionEnabled
            collectionView.refreshControl?.isEnabled = grid.refresh != nil
            if layoutChanged { collectionView.collectionViewLayout.invalidateLayout() }

            if contentChanged || orderChanged || dataSource.snapshot().numberOfSections == 0 {
                appliedSelection = selection
                let previousOrder = dataSource.snapshot().itemIdentifiers
                let previousIDs = Set(previousOrder)
                var snapshot = NSDiffableDataSourceSnapshot<Int, WorkID>()
                snapshot.appendSections([0])
                snapshot.appendItems(grid.works.map(\.id))
                snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { previousIDs.contains($0) })
                let animatesOrder = grid.animatesChanges && !previousOrder.isEmpty && previousOrder != snapshot.itemIdentifiers
                dataSource.apply(snapshot, animatingDifferences: animatesOrder) { [weak self] in
                    self?.synchronizeSelection()
                }
            }
            let headers = collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
            for header in headers {
                (header as? NativeLibraryGridHeader)?.configure(grid.header())
            }
        }

        private func section(in environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
            let margin = PublicationGridLayout.contentMargin
            let spacing = PublicationGridLayout.horizontalSpacing
            let availableWidth = max(1, environment.container.effectiveContentSize.width - margin * 2)
            let minimumWidth: CGFloat = grid.textSize.isAccessibilitySize ? 200 : 150
            let count = max(1, Int((availableWidth + spacing) / (minimumWidth + spacing)))
            let width = (availableWidth - CGFloat(count - 1) * spacing) / CGFloat(count)
            let cellWidth = grid.textSize.isAccessibilitySize ? width : min(width, 210)
            let groupWidth = CGFloat(count) * cellWidth + CGFloat(count - 1) * spacing
            let height = NSCollectionLayoutDimension.estimated(cellWidth * 1.5 + 80)
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(cellWidth), heightDimension: height))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .absolute(groupWidth), heightDimension: height),
                subitems: Array(repeating: item, count: count))
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = PublicationGridLayout.verticalSpacing
            section.contentInsets = .init(top: margin, leading: margin, bottom: margin, trailing: margin)
            section.supplementariesFollowContentInsets = false
            if grid.showsHeader {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(56)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                header.pinToVisibleBounds = true
                header.zIndex = 10
                section.boundarySupplementaryItems = [header]
            }
            return section
        }

        private func synchronizeSelection() {
            let selectedPaths = Set(collectionView.indexPathsForSelectedItems ?? [])
            for indexPath in selectedPaths {
                guard let id = dataSource.itemIdentifier(for: indexPath) else { continue }
                if !grid.selection.contains(id) { collectionView.deselectItem(at: indexPath, animated: false) }
            }
            for id in grid.selection {
                if let indexPath = dataSource.indexPath(for: id), !selectedPaths.contains(indexPath) {
                    collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                }
            }
        }

        private func activate(_ id: WorkID) {
            guard grid.isSelectionEnabled else { return }
            if grid.isSelecting {
                var selection = grid.selection
                if !selection.insert(id).inserted { selection.remove(id) }
                grid.selection = selection
            } else {
                grid.selection = [id]
            }
        }

        override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let id = dataSource.itemIdentifier(for: indexPath), grid.isSelectionEnabled else { return }
            grid.selection = grid.isSelecting ? grid.selection.union([id]) : [id]
        }

        override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard grid.isSelecting, grid.isSelectionEnabled, let id = dataSource.itemIdentifier(for: indexPath) else { return }
            grid.selection = grid.selection.subtracting([id])
        }

        override func collectionView(_ collectionView: UICollectionView,
            contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard !grid.isSelecting, grid.isSelectionEnabled, indexPaths.count == 1,
                  let id = dataSource.itemIdentifier(for: indexPaths[0]),
                  let work = worksByID[id], let menu = grid.contextMenu(work) else { return nil }
            return UIContextMenuConfiguration(identifier: id.description as NSString, previewProvider: nil) { _ in menu }
        }

        override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            grid.onBeginDragging()
        }

        private func refreshLibrary() {
            guard refreshTask == nil, let refresh = grid.refresh else {
                collectionView.refreshControl?.endRefreshing()
                return
            }
            refreshTask = Task { [weak self] in
                await refresh()
                self?.collectionView.refreshControl?.endRefreshing()
                self?.refreshTask = nil
            }
        }
    }
}

private final class NativeLibraryGridHeader: UICollectionReusableView {
    private var hostedView: (UIView & UIContentView)?

    func configure<Content: View>(_ content: Content) {
        let configuration = UIHostingConfiguration { content }.margins(.all, 0)
        if let hostedView {
            hostedView.configuration = configuration
        } else {
            let hostedView = configuration.makeContentView()
            hostedView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hostedView)
            NSLayoutConstraint.activate([
                hostedView.topAnchor.constraint(equalTo: topAnchor),
                hostedView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostedView.bottomAnchor.constraint(equalTo: bottomAnchor),
                hostedView.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
            self.hostedView = hostedView
        }
    }
}
