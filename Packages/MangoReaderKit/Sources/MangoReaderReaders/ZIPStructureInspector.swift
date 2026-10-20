import Foundation

public struct ZIPInspectionLimits: Codable, Hashable, Sendable {
    public let maximumEntryCount: Int
    public let maximumEntryUncompressedBytes: UInt64
    public let maximumTotalUncompressedBytes: UInt64
    public let maximumExpansionRatio: Double

    public init(
        maximumEntryCount: Int = 100_000,
        maximumEntryUncompressedBytes: UInt64 = 512 * 1_024 * 1_024,
        maximumTotalUncompressedBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024,
        maximumExpansionRatio: Double = 200
    ) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumEntryUncompressedBytes = max(1, maximumEntryUncompressedBytes)
        self.maximumTotalUncompressedBytes = max(1, maximumTotalUncompressedBytes)
        self.maximumExpansionRatio = max(1, maximumExpansionRatio)
    }

    public static let publication = Self()
}

struct ZIPEntryMetadata: Hashable, Sendable {
    let path: String
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let isEncrypted: Bool
    let isDirectory: Bool
}

struct ZIPInspection: Hashable, Sendable {
    let entries: [ZIPEntryMetadata]

    var totalUncompressedBytes: UInt64 {
        entries.reduce(into: 0) { result, entry in
            result += entry.uncompressedSize
        }
    }
}

struct ZIPStructureInspector: Sendable {
    let limits: ZIPInspectionLimits

    init(limits: ZIPInspectionLimits = .publication) {
        self.limits = limits
    }

    func inspect(url: URL) throws -> ZIPInspection {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ReaderError.unreadableFile
        }
        return try inspect(data: data)
    }

    func inspect(data: Data) throws -> ZIPInspection {
        guard data.count >= 22, let eocdOffset = endOfCentralDirectoryOffset(in: data) else {
            throw ReaderError.malformedPublication("missing ZIP central directory")
        }

        guard
            let entryCount = data.uint16LE(at: eocdOffset + 10),
            let centralDirectorySize = data.uint32LE(at: eocdOffset + 12),
            let centralDirectoryOffset = data.uint32LE(at: eocdOffset + 16)
        else {
            throw ReaderError.malformedPublication("truncated ZIP central directory")
        }

        guard entryCount != .max, centralDirectorySize != .max, centralDirectoryOffset != .max else {
            throw ReaderError.archiveLimitExceeded("ZIP64 archives are not supported")
        }
        guard Int(entryCount) <= limits.maximumEntryCount else {
            throw ReaderError.archiveLimitExceeded("too many entries")
        }

        let directoryStart = Int(centralDirectoryOffset)
        let directorySize = Int(centralDirectorySize)
        let (directoryEnd, overflow) = directoryStart.addingReportingOverflow(directorySize)
        guard !overflow, directoryStart >= 0, directoryEnd <= data.count else {
            throw ReaderError.malformedPublication("invalid ZIP central-directory bounds")
        }

        var cursor = directoryStart
        var entries: [ZIPEntryMetadata] = []
        entries.reserveCapacity(Int(entryCount))
        var totalUncompressedBytes: UInt64 = 0

        for _ in 0..<Int(entryCount) {
            guard data.uint32LE(at: cursor) == 0x0201_4B50 else {
                throw ReaderError.malformedPublication("invalid ZIP central-directory entry")
            }
            guard
                let flags = data.uint16LE(at: cursor + 8),
                let compressedSize = data.uint32LE(at: cursor + 20),
                let uncompressedSize = data.uint32LE(at: cursor + 24),
                let nameLength = data.uint16LE(at: cursor + 28),
                let extraLength = data.uint16LE(at: cursor + 30),
                let commentLength = data.uint16LE(at: cursor + 32),
                let externalAttributes = data.uint32LE(at: cursor + 38)
            else {
                throw ReaderError.malformedPublication("truncated ZIP entry")
            }

            guard compressedSize != .max, uncompressedSize != .max else {
                throw ReaderError.archiveLimitExceeded("ZIP64 entries are not supported")
            }

            let fixedSize = 46
            let variableSize = Int(nameLength) + Int(extraLength) + Int(commentLength)
            let (nextCursor, cursorOverflow) = cursor.addingReportingOverflow(fixedSize + variableSize)
            let nameStart = cursor + fixedSize
            let nameEnd = nameStart + Int(nameLength)
            guard !cursorOverflow, nextCursor <= directoryEnd, nameEnd <= data.count else {
                throw ReaderError.malformedPublication("truncated ZIP entry name")
            }

            let nameData = data.subdata(in: nameStart..<nameEnd)
            guard let path = String(data: nameData, encoding: .utf8), !path.isEmpty else {
                throw ReaderError.malformedPublication("archive entry names must be UTF-8")
            }
            try validate(path: path)

            let unixMode = UInt16((externalAttributes >> 16) & 0xFFFF)
            if unixMode & 0xF000 == 0xA000 {
                throw ReaderError.unsafeArchivePath(path)
            }

            let uncompressed = UInt64(uncompressedSize)
            let compressed = UInt64(compressedSize)
            guard uncompressed <= limits.maximumEntryUncompressedBytes else {
                throw ReaderError.archiveLimitExceeded("entry \(path) is too large")
            }

            let (newTotal, totalOverflow) = totalUncompressedBytes.addingReportingOverflow(uncompressed)
            guard !totalOverflow, newTotal <= limits.maximumTotalUncompressedBytes else {
                throw ReaderError.archiveLimitExceeded("expanded archive is too large")
            }
            totalUncompressedBytes = newTotal

            if uncompressed > 0 {
                guard compressed > 0 else {
                    throw ReaderError.archiveLimitExceeded("entry \(path) has an invalid expansion ratio")
                }
                let ratio = Double(uncompressed) / Double(compressed)
                guard ratio <= limits.maximumExpansionRatio else {
                    throw ReaderError.archiveLimitExceeded("entry \(path) expands excessively")
                }
            }

            entries.append(
                ZIPEntryMetadata(
                    path: path,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    isEncrypted: flags & 0x0001 != 0,
                    isDirectory: path.hasSuffix("/")
                )
            )
            cursor = nextCursor
        }

        guard cursor <= directoryEnd else {
            throw ReaderError.malformedPublication("invalid ZIP central-directory size")
        }
        return ZIPInspection(entries: entries)
    }

    private func endOfCentralDirectoryOffset(in data: Data) -> Int? {
        let minimumOffset = max(0, data.count - (22 + 65_535))
        var cursor = data.count - 22
        while cursor >= minimumOffset {
            if data.uint32LE(at: cursor) == 0x0605_4B50,
               let commentLength = data.uint16LE(at: cursor + 20),
               cursor + 22 + Int(commentLength) == data.count
            {
                return cursor
            }
            if cursor == minimumOffset {
                break
            }
            cursor -= 1
        }
        return nil
    }

    private func validate(path: String) throws {
        guard
            !path.hasPrefix("/"),
            !path.hasPrefix("\\"),
            !path.contains("\\"),
            !path.contains(":"),
            !path.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw ReaderError.unsafeArchivePath(path)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." }) else {
            throw ReaderError.unsafeArchivePath(path)
        }
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else {
            return nil
        }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else {
            return nil
        }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
