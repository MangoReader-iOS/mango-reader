import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let mangoReaderBackup = UTType(exportedAs: "com.k800k.manko.backup", conformingTo: .zip)
}

struct BackupExportItem: Transferable, Sendable {
    nonisolated static let defaultFilename = "Mango Reader Backup"
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mangoReaderBackup) { item in
            SentTransferredFile(item.url)
        }
        .suggestedFileName(defaultFilename + ".mankobackup")
    }
}
