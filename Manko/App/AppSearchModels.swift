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

struct SearchSourceFailure: Identifiable, Hashable, Sendable {
    let id: String
    let sourceName: String
    let message: String
}

enum SearchSourcePhase: Hashable, Sendable {
    case loading
    case results(hasMore: Bool)
    case empty
    case verificationRequired
    case failed(SearchSourceFailure)
}

struct SearchSourceSection: Identifiable, Hashable, Sendable {
    let id: SourceID
    let name: String
    let descriptor: SourceDescriptor?
    let works: [Work]
    let phase: SearchSourcePhase
}

enum SearchState: Sendable {
    case initial
    case searching
    case results
    case partial([SearchSourceFailure])
    case noMatches
    case failed([SearchSourceFailure])
}

enum RepositoryRefreshOutcome: Sendable {
    case refreshed(RepositoryRefreshDelta)
    case failed(RepositoryRefreshFailure)
}
