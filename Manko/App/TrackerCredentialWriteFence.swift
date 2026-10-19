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
final class TrackerCredentialWriteFence {
    struct Lease {
        fileprivate let sourceID: String
        fileprivate let id = UUID()
    }

    private var activeLeaseIDs: [String: Set<UUID>] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func begin(sourceID: String) -> Lease {
        let lease = Lease(sourceID: sourceID)
        activeLeaseIDs[sourceID, default: []].insert(lease.id)
        return lease
    }

    func finish(_ lease: Lease) {
        guard var leases = activeLeaseIDs[lease.sourceID],
              leases.remove(lease.id) != nil
        else { return }

        guard leases.isEmpty else {
            activeLeaseIDs[lease.sourceID] = leases
            return
        }

        activeLeaseIDs.removeValue(forKey: lease.sourceID)
        let sourceWaiters = waiters.removeValue(forKey: lease.sourceID) ?? []
        for waiter in sourceWaiters {
            waiter.resume()
        }
    }

    func wait(for sourceIDs: Set<String>) async {
        for sourceID in sourceIDs.sorted() where activeLeaseIDs[sourceID]?.isEmpty == false {
            await withCheckedContinuation { continuation in
                waiters[sourceID, default: []].append(continuation)
            }
        }
    }
}
