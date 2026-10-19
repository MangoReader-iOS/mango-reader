import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let mankoBackup = UTType(exportedAs: "com.k800k.manko.backup", conformingTo: .zip)
}

struct BackupExportItem: Transferable, Sendable {
    nonisolated static let defaultFilename = "Manko Backup"
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mankoBackup) { item in
            SentTransferredFile(item.url)
        }
        .suggestedFileName(defaultFilename + ".mankobackup")
    }
}
