import Foundation
import MangoReaderDomain

public struct ReaderRegistration: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let priority: Int
    public let engine: any ReaderEngine

    public init(
        id: String,
        displayName: String,
        priority: Int = 0,
        engine: any ReaderEngine
    ) {
        self.id = id
        self.displayName = displayName
        self.priority = priority
        self.engine = engine
    }
}

public struct ReaderRegistry: Sendable {
    private var registrations: [ReaderRegistration]

    public init(registrations: [ReaderRegistration] = []) {
        self.registrations = []
        for registration in registrations {
            register(registration)
        }
    }

    public static func standard(
        validator: any LocalPublicationValidating = DefaultLocalPublicationValidator()
    ) -> Self {
        Self(registrations: [
            ReaderRegistration(
                id: "image-sequence",
                displayName: "Image Reader",
                priority: 100,
                engine: ImageSequenceReaderEngine(validator: validator)
            ),
            ReaderRegistration(
                id: "readium",
                displayName: "Publication Reader",
                priority: 100,
                engine: ReadiumReaderEngine(validator: validator)
            ),
        ])
    }

    public var allRegistrations: [ReaderRegistration] {
        registrations.sorted(by: Self.isPreferred)
    }

    public mutating func register(_ registration: ReaderRegistration) {
        registrations.removeAll { $0.id == registration.id }
        registrations.append(registration)
    }

    @discardableResult
    public mutating func unregister(id: String) -> Bool {
        let previousCount = registrations.count
        registrations.removeAll { $0.id == id }
        return registrations.count != previousCount
    }

    public func registration(for format: PublicationFormat) -> ReaderRegistration? {
        registrations
            .filter { $0.engine.supportedFormats.contains(format) }
            .sorted(by: Self.isPreferred)
            .first
    }

    public func engine(for format: PublicationFormat) throws -> any ReaderEngine {
        guard let registration = registration(for: format) else {
            throw ReaderError.unsupportedFormat(format)
        }
        return registration.engine
    }

    public func validate(_ session: ReaderSessionDescriptor) async throws {
        let engine = try engine(for: session.installment.format)
        try await engine.validate(session)
    }

    private static func isPreferred(_ lhs: ReaderRegistration, _ rhs: ReaderRegistration) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        return lhs.id < rhs.id
    }
}

public struct ImageSequenceReaderEngine: ReaderEngine {
    public let supportedFormats: Set<PublicationFormat> = [.remoteImageSequence, .cbz]
    private let validator: any LocalPublicationValidating

    public init(validator: any LocalPublicationValidating = DefaultLocalPublicationValidator()) {
        self.validator = validator
    }

    public func validate(_ session: ReaderSessionDescriptor) async throws {
        switch session.installment.format {
        case .remoteImageSequence:
            return
        case .cbz:
            guard let fileURL = session.fileURL else {
                throw ReaderError.missingLocalFile
            }
            _ = try await validator.validate(fileURL, expectedFormat: .cbz)
        case .epub, .pdf:
            throw ReaderError.unsupportedFormat(session.installment.format)
        }
    }
}

public struct ReadiumReaderEngine: ReaderEngine {
    public let supportedFormats: Set<PublicationFormat> = [.epub, .pdf]
    private let validator: any LocalPublicationValidating

    public init(validator: any LocalPublicationValidating = DefaultLocalPublicationValidator()) {
        self.validator = validator
    }

    public func validate(_ session: ReaderSessionDescriptor) async throws {
        guard supportedFormats.contains(session.installment.format) else {
            throw ReaderError.unsupportedFormat(session.installment.format)
        }
        guard let fileURL = session.fileURL else {
            throw ReaderError.missingLocalFile
        }
        _ = try await validator.validate(fileURL, expectedFormat: session.installment.format)
    }
}
