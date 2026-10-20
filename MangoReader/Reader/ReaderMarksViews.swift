import MangoReaderDomain
import MangoReaderReaders
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ReaderAnnotationEditorDraft: Identifiable, Hashable {
    let id: UUID
    let annotation: Annotation?
    let anchor: ReaderAnnotationAnchor

    static func new(anchor: ReaderAnnotationAnchor) -> Self {
        Self(id: UUID(), annotation: nil, anchor: anchor)
    }

    static func edit(annotation: Annotation) -> Self {
        Self(
            id: annotation.id,
            annotation: annotation,
            anchor: ReaderAnnotationAnchor(
                locator: annotation.locator,
                selectedText: annotation.selectedText,
                kind: annotation.selectedText == nil ? .currentPosition : .textSelection
            )
        )
    }
}

private enum ReaderMarkDeletion: Identifiable {
    case bookmark(Bookmark)
    case annotation(Annotation)

    var id: UUID {
        switch self {
        case let .bookmark(bookmark): bookmark.id
        case let .annotation(annotation): annotation.id
        }
    }

    var actionTitle: String {
        switch self {
        case .bookmark: "Delete Bookmark"
        case .annotation: "Delete Highlight or Note"
        }
    }
}

struct ReaderMarksSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    @Binding var bookmarks: [Bookmark]
    @Binding var annotations: [Annotation]
    let format: PublicationFormat
    let controller: ReadiumReaderController
    let highlightAppearanceIsDark: Bool
    let increasedContrast: Bool
    let onNavigate: @MainActor (ReadingLocator) -> Void

    @State private var editorDraft: ReaderAnnotationEditorDraft?
    @State private var mutatingIDs: Set<UUID> = []
    @State private var pendingDeletion: ReaderMarkDeletion?

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty && annotations.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks or Notes",
                        systemImage: "bookmark.slash"
                    )
                } else {
                    marksList
                }
            }
            .accessibilityIdentifier("reader-marks-list")
            .navigationTitle("Bookmarks & Notes")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    FixedNavigationChrome {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("reader-marks-done")
                    }
                }
            }
            .navigationDestination(item: $editorDraft) { draft in
                ReaderAnnotationEditor(
                    draft: draft,
                    highlightAppearanceIsDark: highlightAppearanceIsDark,
                    increasedContrast: increasedContrast
                ) { note, highlightColor in
                    guard
                        let annotation = draft.annotation,
                        let updated = await model.libraryModel.updateAnnotation(
                            annotation,
                            note: note,
                            highlightColor: highlightColor
                        )
                    else {
                        return false
                    }
                    annotations.removeAll { $0.id == updated.id }
                    annotations.insert(updated, at: 0)
                    controller.setAnnotations(annotations)
                    model.feedback.showStatus("Highlight or note updated.", systemImage: "highlighter")
                    return true
                }
            }
        }
        .appFeedbackOverlay()
        .confirmationDialog(
            "Delete saved mark?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { pendingDeletion = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { deletion in
            Button(deletion.actionTitle, role: .destructive) {
                delete(deletion)
            }
        } message: { _ in
            Text("This removes the saved mark from this library and from synced devices. This action cannot be undone.")
        }
    }

    private var marksList: some View {
        List {
            if !bookmarks.isEmpty {
                Section("Bookmarks") {
                    ForEach(bookmarks) { bookmark in
                        HStack(spacing: 8) {
                            Button {
                                open(bookmark.locator)
                            } label: {
                                ReaderMarkSummary(
                                    symbol: "bookmark.fill",
                                    tint: .accentColor,
                                    title: bookmark.title,
                                    detail: readerLocationLabel(bookmark.locator),
                                    date: bookmark.createdAt
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Bookmark, \(bookmark.title), \(readerLocationLabel(bookmark.locator))")
                            .accessibilityHint("Opens this saved position")

                            Menu {
                                Button("Delete Bookmark", systemImage: "trash", role: .destructive) {
                                    pendingDeletion = .bookmark(bookmark)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .appIconControlFrame(dimension: 48)
                            }
                            .accessibilityLabel("Actions for bookmark")
                        }
                        .disabled(mutatingIDs.contains(bookmark.id))
                        .accessibilityIdentifier("reader-bookmark-\(bookmark.id.uuidString)")
                        .accessibilityAction(named: "Delete bookmark") {
                            pendingDeletion = .bookmark(bookmark)
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) {
                                pendingDeletion = .bookmark(bookmark)
                            }
                        }
                    }
                }
                .appFullWidthListSeparator()
            }

            if !annotations.isEmpty {
                Section {
                    ForEach(annotations) { annotation in
                        HStack(spacing: 8) {
                            Button {
                                open(annotation.locator)
                            } label: {
                                ReaderMarkSummary(
                                    symbol: annotation.selectedText == nil ? "note.text" : "highlighter",
                                    tint: annotation.highlightColor.color(
                                        isDark: highlightAppearanceIsDark,
                                        increasedContrast: increasedContrast
                                    ),
                                    title: annotationTitle(annotation),
                                    detail: readerLocationLabel(annotation.locator),
                                    date: annotation.modifiedAt
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(annotationAccessibilityLabel(annotation))
                            .accessibilityHint("Opens this saved position")

                            Menu {
                                Button {
                                    editorDraft = .edit(annotation: annotation)
                                } label: {
                                    Text("Edit")
                                }

                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    pendingDeletion = .annotation(annotation)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .appIconControlFrame(dimension: 48)
                            }
                            .accessibilityLabel("Actions for annotation")
                        }
                        .disabled(mutatingIDs.contains(annotation.id))
                        .accessibilityIdentifier("reader-annotation-\(annotation.id.uuidString)")
                        .accessibilityAction(named: "Edit annotation") {
                            editorDraft = .edit(annotation: annotation)
                        }
                        .accessibilityAction(named: "Delete annotation") {
                            pendingDeletion = .annotation(annotation)
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) {
                                pendingDeletion = .annotation(annotation)
                            }
                            Button("Edit") {
                                editorDraft = .edit(annotation: annotation)
                            }
                            .tint(.accentColor)
                        }
                    }
                } header: {
                    Text("Highlights & Notes")
                } footer: {
                    if format == .pdf, annotations.contains(where: { $0.selectedText != nil }) {
                        Text("PDF highlights are saved and navigable. This Readium PDF navigator does not currently draw highlight overlays on the page.")
                    }
                }
                .appFullWidthListSeparator()
            }
        }
    }

    private func open(_ locator: ReadingLocator) {
        onNavigate(locator)
        dismiss()
    }

    private func delete(_ deletion: ReaderMarkDeletion) {
        pendingDeletion = nil
        switch deletion {
        case let .bookmark(bookmark):
            deleteConfirmed(bookmark)
        case let .annotation(annotation):
            deleteConfirmed(annotation)
        }
    }

    private func deleteConfirmed(_ bookmark: Bookmark) {
        guard mutatingIDs.insert(bookmark.id).inserted else { return }
        Task {
            if await model.libraryModel.deleteBookmark(bookmark) {
                bookmarks.removeAll { $0.id == bookmark.id }
                model.feedback.showStatus("Bookmark removed.", systemImage: "bookmark.slash.fill")
            }
            mutatingIDs.remove(bookmark.id)
        }
    }

    private func deleteConfirmed(_ annotation: Annotation) {
        guard mutatingIDs.insert(annotation.id).inserted else { return }
        Task {
            if await model.libraryModel.deleteAnnotation(annotation) {
                annotations.removeAll { $0.id == annotation.id }
                controller.setAnnotations(annotations)
                model.feedback.showStatus("Highlight or note removed.", systemImage: "highlighter")
            }
            mutatingIDs.remove(annotation.id)
        }
    }

    private func annotationTitle(_ annotation: Annotation) -> String {
        let note = annotation.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return note }
        let selectedText = annotation.selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return selectedText.isEmpty ? "Position note" : selectedText
    }

    private func annotationAccessibilityLabel(_ annotation: Annotation) -> String {
        let kind = annotation.selectedText == nil ? "Note" : "Highlight"
        return "\(kind), \(annotationTitle(annotation)), \(readerLocationLabel(annotation.locator))"
    }
}

private struct ReaderMarkSummary: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scaledIconColumnWidth: CGFloat = 24
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let date: Date

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: min(scaledIconColumnWidth, 44))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(AppDynamicTypeSizing.contentLineLimit(3, for: dynamicTypeSize))
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(detail)
                            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(detail)
                            Text("•")
                                .accessibilityHidden(true)
                            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

struct ReaderAnnotationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .caption) private var scaledColorFillSize: CGFloat = 34
    @ScaledMetric(relativeTo: .caption) private var scaledColorRingSize: CGFloat = 42
    @ScaledMetric(relativeTo: .caption) private var scaledColorTargetSize: CGFloat = 54

    let draft: ReaderAnnotationEditorDraft
    let highlightAppearanceIsDark: Bool
    let increasedContrast: Bool
    let onSave: @MainActor (String, ReaderHighlightColor) async -> Bool

    @State private var note: String
    @State private var highlightColor: ReaderHighlightColor
    @State private var isSaving = false
    @State private var isConfirmingDiscard = false

    init(
        draft: ReaderAnnotationEditorDraft,
        highlightAppearanceIsDark: Bool,
        increasedContrast: Bool,
        onSave: @escaping @MainActor (String, ReaderHighlightColor) async -> Bool
    ) {
        self.draft = draft
        self.highlightAppearanceIsDark = highlightAppearanceIsDark
        self.increasedContrast = increasedContrast
        self.onSave = onSave
        _note = State(initialValue: draft.annotation?.note ?? "")
        _highlightColor = State(initialValue: draft.annotation?.highlightColor ?? .yellow)
    }

    var body: some View {
        Form {
            if let selectedText = draft.anchor.selectedText, !selectedText.isEmpty {
                Section("Selected Text") {
                    Text(selectedText)
                        .font(.body)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("reader-annotation-selected-text")
                }
            }

            Section("Note") {
                TextEditor(text: $note)
                    .frame(minHeight: 140)
                    .accessibilityLabel("Annotation note")
                    .accessibilityIdentifier("reader-annotation-note")
            }

            Section("Highlight Color") {
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(ReaderHighlightColor.allCases, id: \.self) { choice in
                            Button {
                                highlightColor = choice
                            } label: {
                                VStack(spacing: 6) {
                                    ZStack {
                                        Circle()
                                            .fill(choice.color(
                                                isDark: highlightAppearanceIsDark,
                                                increasedContrast: increasedContrast
                                            ))
                                            .frame(
                                                width: min(scaledColorFillSize, 56),
                                                height: min(scaledColorFillSize, 56)
                                            )
                                        if highlightColor == choice {
                                            Circle()
                                                .stroke(.primary, lineWidth: 3)
                                                .frame(
                                                    width: min(scaledColorRingSize, 64),
                                                    height: min(scaledColorRingSize, 64)
                                                )
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.primary)
                                                .offset(x: 15, y: -15)
                                        }
                                    }
                                    Text(choice.label)
                                        .font(.caption2)
                                        .foregroundStyle(.primary)
                                }
                                .frame(
                                    minWidth: AppDynamicTypeSizing.controlDimension(
                                        scaledDimension: scaledColorTargetSize
                                    ),
                                    minHeight: AppDynamicTypeSizing.controlDimension(
                                        scaledDimension: scaledColorTargetSize
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(choice.label) highlight color")
                            .accessibilityValue(highlightColor == choice ? "Selected" : "Not selected")
                            .accessibilityIdentifier("reader-annotation-color-\(choice.rawValue)")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle(draft.annotation == nil ? "New Highlight or Note" : "Edit Highlight or Note")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                FixedNavigationChrome {
                    Button("Cancel") { cancel() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("reader-annotation-cancel")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                FixedNavigationChrome {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave || isSaving)
                    .accessibilityIdentifier("reader-annotation-save")
                }
            }
        }
        .interactiveDismissDisabled(isSaving || isDirty)
        .confirmationDialog(
            "Discard changes?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { dismiss() }
        } message: {
            Text("Your note and highlight-color changes have not been saved.")
        }
    }

    private var canSave: Bool {
        let hasTextSelection = draft.anchor.selectedText?.isEmpty == false
        return hasTextSelection || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isDirty: Bool {
        note != (draft.annotation?.note ?? "")
            || highlightColor != (draft.annotation?.highlightColor ?? .yellow)
    }

    private func cancel() {
        if isDirty {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func save() {
        guard canSave, !isSaving else { return }
        isSaving = true
        Task {
            let didSave = await onSave(note, highlightColor)
            isSaving = false
            if didSave { dismiss() }
        }
    }
}

private extension ReaderHighlightColor {
    var label: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .orange: "Orange"
        case .pink: "Pink"
        }
    }

    func color(isDark: Bool, increasedContrast: Bool) -> Color {
        Color(uiColor: resolvedUIColor(
            interfaceStyle: isDark ? .dark : .light,
            accessibilityContrast: increasedContrast ? .high : .normal
        ))
    }
}

private func readerLocationLabel(_ locator: ReadingLocator) -> String {
    switch locator {
    case let .image(page, total, _):
        if let total, total > 0 {
            return "Page \(page + 1) of \(total)"
        }
        return "Page \(page + 1)"
    case .publication:
        guard
            let persisted = try? PersistedReadiumLocator(readingLocator: locator),
            let progression = persisted.totalProgression
        else {
            return "Saved position"
        }
        return progression.formatted(.percent.precision(.fractionLength(0)))
    }
}
