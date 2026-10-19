import Foundation
import ImageIO
import MankoData
import MankoDomain
import MankoExtensions
import MankoReaders
import MankoSources
import MankoSync
import Observation
import OSLog
import SwiftUI
import WebKit

@MainActor
@Observable
final class SettingsSyncModel {
    @ObservationIgnored let cloudSaveQueue: CloudSaveQueue?
    @ObservationIgnored var cloudSyncEngine: CloudSyncEngine?
    @ObservationIgnored var database: MankoDatabase?
    let defaults: UserDefaults
    let deviceID: String
    let sourcesModel: SourcesModel

    init(
        cloudSaveQueue: CloudSaveQueue?,
        database: MankoDatabase?,
        defaults: UserDefaults,
        deviceID: String,
        sourcesModel: SourcesModel
    ) {
        self.cloudSaveQueue = cloudSaveQueue
        self.database = database
        self.defaults = defaults
        self.deviceID = deviceID
        self.sourcesModel = sourcesModel
    }

    var layoutMode: AppModel.LayoutMode = .grid

    var librarySort: LibrarySort = .recentlyAdded

    var incognitoMode: Bool = false {
        didSet {
            guard oldValue != incognitoMode else { return }
            let enabled = incognitoMode
            sourcesModel.clearSourceSuggestionMemory()
            sourcesModel.coverImageCache.clear()
            for source in sourcesModel.sources { sourcesModel.workDetailCache.invalidate(sourceID: source.id) }
            let registry = sourcesModel.extensionRuntimeRegistry
            let installed = sourcesModel.installedRepositorySources
            Task {
                await sourcesModel.contentCache.setPrivacyMode(enabled)
                for source in installed where source.descriptor.kind == .mankoExtension {
                    await registry?.invalidate(installedSourceID: source.id)
                }
            }
        }
    }

    var syncImportedFiles: Bool = false

    var preferredAppearance: String = "system"

    /// Changes whenever a durable settings record is applied in this window.
    /// AppStorage-backed reader controls observe UserDefaults directly; this
    /// revision gives app-level tests and non-AppStorage surfaces an explicit
    /// active-window refresh boundary.
    var syncedSettingsRevision = 0

    var wifiOnlyDownloads: Bool = true

    var cloudSyncAvailability: CloudSyncAvailability = .stopped

    var isCloudSyncing = false

    var importedFileSyncStatus: String?

    var importedFileSyncNeedsRetry = false

    var isUpdatingImportedFileSync = false

    var automationRules: LibraryAutomationRules = .disabled

    var isRunningAutomation = false

    var isRequestingAutomation = false

    var automationScheduleError: String?

    var lastAutomationRun: LibraryAutomationRunReport?

    var automationLastError: String?

    @ObservationIgnored var automationVerificationInterruptionDescription: String?

    @ObservationIgnored var syncedSettingsSaveTask: Task<Void, Never>?

    var lastAppliedSyncedSettings: SyncedAppSettings?

    var preferredColorScheme: ColorScheme? {
        switch preferredAppearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    func cloudFilePolicy(for workID: WorkID) async -> CloudFilePolicy {
        guard let database else { return .inheritGlobal }
        do {
            return try await database.libraryEntry(for: workID)?.cloudFilePolicy ?? .inheritGlobal
        } catch {
            sourcesModel.show(error, title: "Couldn’t load file sync policy")
            return .inheritGlobal
        }
    }

    var automationIsEnabled: Bool {
        automationRules.checksForUpdates || automationRules.deletesCompletedDownloads
    }

    func saveAutomationRules(_ rules: LibraryAutomationRules) async -> Bool {
        let normalizedRules = LibraryAutomationRules(
            checksForUpdates: rules.checksForUpdates,
            downloadsNewInstallments: rules.checksForUpdates && rules.downloadsNewInstallments,
            deletesCompletedDownloads: rules.deletesCompletedDownloads,
            deleteDelayDays: rules.deleteDelayDays
        )
        automationRules = normalizedRules
        do {
            defaults.set(try JSONEncoder().encode(automationRules), forKey: "libraryAutomationRules")
            if !sourcesModel.isPrivate { LibraryAutomationHandoff.shared.updateRules(automationRules) }
            automationScheduleError = LibraryAutomationHandoff.shared.schedulingError
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t save automation rules")
            return false
        }
    }

    func configureLibraryAutomation() {
        if !sourcesModel.isPrivate { LibraryAutomationHandoff.shared.updateRules(automationRules) }
    }

    func setIncognito(_ enabled: Bool) {
        incognitoMode = enabled
        defaults.set(enabled, forKey: "incognitoMode")
    }

    /// Persists one locally observed preference snapshot. This internal seam is
    /// deterministic in Swift Testing and is also used for account reseeding.
    @discardableResult
    func persistSyncedSettingsIfChanged(
        modifiedAt: Date = .now,
        forceMetadataRefresh: Bool = false
    ) async -> Bool {
        guard let database else { return false }
        let proposed = currentSyncedAppSettings(modifiedAt: modifiedAt, deviceID: deviceID)

        do {
            guard let settings = try await database.saveSyncedAppSettingsIfPreferencesChanged(
                proposed,
                forceMetadataRefresh: forceMetadataRefresh
            ) else {
                if let durable = try await database.syncedAppSettings() {
                    lastAppliedSyncedSettings = durable
                }
                return false
            }
            lastAppliedSyncedSettings = settings
            defaults.set(settings.modifiedAt, forKey: Self.syncedSettingsModifiedAtKey)
            await queueCloudSave(CloudSyncRecordID.settings())
            return true
        } catch {
            // Preference synchronization is best-effort and never prevents the
            // local setting from taking effect.
            return false
        }
    }

    /// Reads the LWW winner written by DatabaseCloudRecordStore and applies it
    /// to this window's observable state plus AppStorage's shared defaults.
    func refreshSyncedAppSettingsFromDatabase() async {
        guard let database else { return }
        do {
            guard let settings = try await database.syncedAppSettings() else { return }
            applySyncedAppSettings(settings)
        } catch {
            // A malformed cloud value is rejected by the store. Local settings
            // remain usable and the sync status reports transport failures.
        }
    }

    func bootstrapSyncedAppSettings() async {
        guard !sourcesModel.isPrivate, let database else { return }
        do {
            if let settings = try await database.syncedAppSettings() {
                applySyncedAppSettings(settings)
            }
        } catch {
            // Database and CloudKit settings are an optional enhancement. The
            // local library and current UserDefaults remain fully functional.
        }
    }

    /// Creates a settings singleton only after a successful initial fetch has
    /// established that the current private zone has no settings winner. This
    /// avoids an equal-timestamp bootstrap record participating in LWW at all.
    func ensureSyncedAppSettingsRecordExists() async {
        guard let database else { return }
        do {
            guard try await database.syncedAppSettings() == nil else { return }
            let settings = currentSyncedAppSettings(modifiedAt: .now, deviceID: deviceID)
            try await database.save(syncedAppSettings: settings)
            lastAppliedSyncedSettings = settings
            defaults.set(settings.modifiedAt, forKey: Self.syncedSettingsModifiedAtKey)
        } catch {
            // Local preferences remain usable even when the optional singleton
            // cannot be created.
        }
    }

    func applySyncedAppSettings(_ settings: SyncedAppSettings) {
        guard settings.isValidForCloudSync else { return }
        let current = currentSyncedAppSettings(
            modifiedAt: settings.modifiedAt,
            deviceID: settings.deviceID
        )
        let preferencesChanged = !settings.hasSamePreferences(as: current)

        layoutMode = AppModel.LayoutMode(rawValue: settings.library.layout) ?? .grid
        librarySort = settings.library.sort
        preferredAppearance = settings.appearance.mode

        defaults.set(settings.library.layout, forKey: "libraryLayout")
        defaults.set(settings.library.sort.rawValue, forKey: "librarySort")
        defaults.set(settings.appearance.mode, forKey: "preferredAppearance")
        defaults.set(settings.reader.additional.encoded, forKey: ReaderAdditionalPreferences.storageKey)
        defaults.set(settings.reader.direction, forKey: "readerDirection")
        defaults.set(settings.reader.epubScroll, forKey: "epubScroll")
        defaults.set(settings.reader.publisherStyles, forKey: "publisherStyles")
        defaults.set(settings.reader.verticalWriting, forKey: "verticalWriting")
        defaults.set(settings.reader.publicationTheme, forKey: "publicationTheme")
        defaults.set(settings.reader.fontPreset, forKey: "readerFontPreset")
        defaults.set(settings.reader.fontScale, forKey: "readerFontScale")
        defaults.set(settings.reader.fontWeight, forKey: "readerFontWeight")
        defaults.set(settings.reader.lineHeight, forKey: "readerLineHeight")
        defaults.set(settings.reader.paragraphSpacing, forKey: "readerParagraphSpacing")
        defaults.set(settings.reader.paragraphIndent, forKey: "readerParagraphIndent")
        defaults.set(settings.reader.pageMargins, forKey: "readerPageMargins")
        defaults.set(settings.reader.wordSpacing, forKey: "readerWordSpacing")
        defaults.set(settings.reader.letterSpacing, forKey: "readerLetterSpacing")
        defaults.set(settings.reader.hyphenation, forKey: "readerHyphenation")
        defaults.set(settings.reader.textNormalization, forKey: "readerTextNormalization")
        defaults.set(settings.reader.textAlignment, forKey: "readerTextAlignment")
        defaults.set(settings.reader.columnCount, forKey: "readerColumnCount")
        defaults.set(settings.reader.pdfDoublePage, forKey: "pdfDoublePage")
        defaults.set(settings.reader.pdfContinuous, forKey: "pdfContinuous")
        defaults.set(settings.reader.reduceTransitions, forKey: "reduceReaderTransitions")
        defaults.set(settings.reader.imagePageSpread, forKey: "imageReaderPageSpread")
        defaults.set(
            settings.reader.imageWidePageBehavior,
            forKey: "imageReaderWidePageBehavior"
        )
        defaults.set(settings.reader.imageCropMargins, forKey: "imageReaderCropMargins")
        defaults.set(settings.reader.imageLiveText, forKey: "imageReaderLiveText")
        defaults.set(settings.reader.imageTransition, forKey: "imageReaderTransition")
        defaults.set(
            settings.reader.imageTapLeadingAction,
            forKey: "imageReaderTapLeadingAction"
        )
        defaults.set(
            settings.reader.imageTapCenterAction,
            forKey: "imageReaderTapCenterAction"
        )
        defaults.set(
            settings.reader.imageTapTrailingAction,
            forKey: "imageReaderTapTrailingAction"
        )
        defaults.set(settings.modifiedAt, forKey: Self.syncedSettingsModifiedAtKey)

        lastAppliedSyncedSettings = settings
        if preferencesChanged {
            syncedSettingsRevision += 1
        }
    }

    func currentSyncedAppSettings(
        modifiedAt: Date,
        deviceID: String
    ) -> SyncedAppSettings {
        SyncedAppSettings(
            library: SyncedLibraryPreferences(
                layout: defaults.string(forKey: "libraryLayout") ?? layoutMode.rawValue,
                sort: defaults.string(forKey: "librarySort")
                    .flatMap(LibrarySort.init(rawValue:)) ?? librarySort
            ),
            appearance: SyncedAppearancePreferences(
                mode: defaults.string(forKey: "preferredAppearance") ?? preferredAppearance
            ),
            reader: SyncedReaderPreferences(
                additional: ReaderAdditionalPreferences.read(from: defaults),
                direction: defaults.string(forKey: "readerDirection") ?? "vertical",
                epubScroll: defaults.object(forKey: "epubScroll") as? Bool ?? true,
                publisherStyles: defaults.object(forKey: "publisherStyles") as? Bool ?? true,
                verticalWriting: defaults.bool(forKey: "verticalWriting"),
                publicationTheme: defaults.string(forKey: "publicationTheme") ?? "system",
                fontPreset: defaults.string(forKey: "readerFontPreset") ?? "publisher",
                fontScale: defaults.object(forKey: "readerFontScale") as? Double ?? 1,
                fontWeight: defaults.object(forKey: "readerFontWeight") as? Double ?? 1,
                lineHeight: defaults.object(forKey: "readerLineHeight") as? Double ?? 1.4,
                paragraphSpacing: defaults.object(forKey: "readerParagraphSpacing") as? Double ?? 0.5,
                paragraphIndent: defaults.object(forKey: "readerParagraphIndent") as? Double ?? 0,
                pageMargins: defaults.object(forKey: "readerPageMargins") as? Double ?? 1,
                wordSpacing: defaults.object(forKey: "readerWordSpacing") as? Double ?? 0,
                letterSpacing: defaults.object(forKey: "readerLetterSpacing") as? Double ?? 0,
                hyphenation: defaults.object(forKey: "readerHyphenation") as? Bool ?? true,
                textNormalization: defaults.bool(forKey: "readerTextNormalization"),
                textAlignment: defaults.string(forKey: "readerTextAlignment") ?? "publisher",
                columnCount: defaults.string(forKey: "readerColumnCount") ?? "automatic",
                pdfDoublePage: defaults.bool(forKey: "pdfDoublePage"),
                pdfContinuous: defaults.object(forKey: "pdfContinuous") as? Bool ?? true,
                reduceTransitions: defaults.bool(forKey: "reduceReaderTransitions"),
                imagePageSpread: defaults.string(forKey: "imageReaderPageSpread") ?? "single",
                imageWidePageBehavior: defaults.string(
                    forKey: "imageReaderWidePageBehavior"
                ) ?? "fit",
                imageCropMargins: defaults.bool(forKey: "imageReaderCropMargins"),
                imageLiveText: defaults.bool(forKey: "imageReaderLiveText"),
                imageTransition: defaults.string(forKey: "imageReaderTransition") ?? "slide",
                imageTapLeadingAction: defaults.string(
                    forKey: "imageReaderTapLeadingAction"
                ) ?? "",
                imageTapCenterAction: defaults.string(
                    forKey: "imageReaderTapCenterAction"
                ) ?? "",
                imageTapTrailingAction: defaults.string(
                    forKey: "imageReaderTapTrailingAction"
                ) ?? ""
            ),
            modifiedAt: modifiedAt,
            deviceID: deviceID
        )
    }

    static let syncedSettingsModifiedAtKey = "syncedAppSettingsModifiedAt"

    func queueCloudSave(_ recordName: String) async {
        if let cloudSaveQueue {
            await cloudSaveQueue([recordName])
            return
        }
        guard let cloudSyncEngine else { return }
        await cloudSyncEngine.queueSave(recordName: recordName)
    }

    func queueCloudSaves(_ recordNames: [String]) async {
        guard !recordNames.isEmpty else { return }
        if let cloudSaveQueue {
            await cloudSaveQueue(recordNames)
            return
        }
        guard let cloudSyncEngine else { return }
        await cloudSyncEngine.queueSaves(recordNames: recordNames)
    }

    static func loadAutomationRules(from defaults: UserDefaults) -> LibraryAutomationRules {
        guard let data = defaults.data(forKey: "libraryAutomationRules") else { return .disabled }
        return (try? JSONDecoder().decode(LibraryAutomationRules.self, from: data)) ?? .disabled
    }

    static func loadLastAutomationRun(
        from defaults: UserDefaults
    ) -> LibraryAutomationRunReport? {
        guard let data = defaults.data(forKey: "lastLibraryAutomationRun") else { return nil }
        return try? JSONDecoder().decode(LibraryAutomationRunReport.self, from: data)
    }
}
