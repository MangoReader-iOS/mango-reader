import Foundation
import ImageIO
import MangoReaderData
import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import MangoReaderSync
import Observation
import OSLog
import SwiftUI
import WebKit

struct LibraryUpdateResult: Identifiable, Hashable, Sendable {
    var work: Work
    var plan: RemoteLibraryUpdatePlan?
    var errorMessage: String?

    var id: WorkID { work.id }
    var newInstallmentCount: Int { plan?.newlyAvailableInstallments.count ?? 0 }
    var changedInstallmentCount: Int { plan?.changedInstallments.count ?? 0 }
    var unavailableRemoteInstallmentCount: Int { plan?.removedInstallments.count ?? 0 }
    var hasApplicableChanges: Bool {
        guard let plan else { return false }
        return plan.workMetadataChanged
            || !plan.newlyAvailableInstallments.isEmpty
            || !plan.changedInstallments.isEmpty
    }

    init(work: Work, plan: RemoteLibraryUpdatePlan) {
        self.work = work
        self.plan = plan
        errorMessage = nil
    }

    init(work: Work, errorMessage: String) {
        self.work = work
        plan = nil
        self.errorMessage = errorMessage
    }
}

struct LibraryUpdateBatchSummary: Equatable, Sendable {
    var checkedTitleCount: Int
    var updatedTitleCount: Int
    var failedTitleCount: Int

    init(
        checkedTitleCount: Int = 0,
        updatedTitleCount: Int = 0,
        failedTitleCount: Int = 0
    ) {
        self.checkedTitleCount = max(0, checkedTitleCount)
        self.updatedTitleCount = max(0, updatedTitleCount)
        self.failedTitleCount = max(0, failedTitleCount)
    }
}

struct AppliedLibraryUpdate {
    var work: Work
    var newInstallments: [Installment]
}

struct LibraryUpdateBatchRun {
    var summary: LibraryUpdateBatchSummary
    var appliedUpdates: [AppliedLibraryUpdate]
}

struct LibraryUpdateBatchInterruption: LocalizedError {
    var checkedTitleCount: Int
    var message: String

    var errorDescription: String? { message }
}

typealias CloudSaveQueue = @Sendable ([String]) async -> Void

enum LibraryCategoryScope: Hashable, Sendable {
    case all
    case category(UUID)
    case uncategorized

    private static let uncategorizedStorageValue = "uncategorized"

    init(storageValue: String?) {
        if storageValue == Self.uncategorizedStorageValue {
            self = .uncategorized
        } else if let storageValue, let id = UUID(uuidString: storageValue) {
            self = .category(id)
        } else {
            self = .all
        }
    }

    var storageValue: String? {
        switch self {
        case .all: nil
        case let .category(id): id.uuidString
        case .uncategorized: Self.uncategorizedStorageValue
        }
    }

    var categoryID: UUID? {
        if case let .category(id) = self { id } else { nil }
    }
}
