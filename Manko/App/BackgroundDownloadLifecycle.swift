import MankoDomain
import MankoSources
import OSLog
import UIKit

#if !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif

@MainActor
final class MankoAppDelegate: NSObject, UIApplicationDelegate {
    static var readerOrientations: [ObjectIdentifier: UIInterfaceOrientationMask] = [:]
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        window.flatMap { Self.readerOrientations[ObjectIdentifier($0)] } ?? .allButUpsideDown
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard !MankoTestEnvironment.isUnitTesting else { return true }
        #if DEBUG
        if MankoScreenshotMode.isEnabled { return true }
        #endif
        LibraryAutomationHandoff.shared.registerBackgroundTask()
        SourceCacheRefresh.shared.register()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundDownloadHandoff.shared.receive(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

struct LibraryAutomationOutcome: Sendable {
    var succeeded: Bool
    var contentChanged: Bool

    static let cancelled = Self(succeeded: false, contentChanged: false)

    init(succeeded: Bool, contentChanged: Bool) {
        self.succeeded = succeeded
        self.contentChanged = contentChanged
    }

    init(succeeded: Bool, previous: LibraryAutomationRunReport?, report: LibraryAutomationRunReport?) {
        self.succeeded = succeeded
        contentChanged = report != previous && report.map {
            $0.updatedWorkCount > 0 || $0.queuedDownloadCount > 0 || $0.deletedDownloadCount > 0
        } == true
    }
}

@MainActor
final class LibraryAutomationHandoff {
    typealias ProcessOperation = @MainActor @Sendable (LibraryAutomationTrigger) async -> Bool

    static let shared = LibraryAutomationHandoff()
    static let taskIdentifier = "com.k800k.manko.library-maintenance"

    private let processOperation: ProcessOperation?
    private var foregroundOperation: ProcessOperation?
    private var foregroundReport: (@MainActor @Sendable () -> LibraryAutomationRunReport?)?
    private var foregroundError: (@MainActor @Sendable () -> String?)?
    private var processModel: AppModel?
    private var isPerforming = false
    private var activeWaiters: [UUID: CheckedContinuation<LibraryAutomationOutcome, Never>] = [:]
    private var rules: LibraryAutomationRules = .disabled
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.k800k.manko",
        category: "LibraryAutomation"
    )
    private(set) var lastError: String?
    private(set) var schedulingError: String?

    init(processOperation: ProcessOperation? = nil) {
        self.processOperation = processOperation
    }

    func updateRules(_ rules: LibraryAutomationRules) {
        self.rules = rules
        rescheduleBackgroundTask()
    }

    func registerForegroundOperation(_ operation: @escaping ProcessOperation) {
        registerForegroundOperation(operation, error: { nil })
    }

    func registerForegroundOperation(
        _ operation: @escaping ProcessOperation,
        error: @escaping @MainActor @Sendable () -> String?,
        report: (@MainActor @Sendable () -> LibraryAutomationRunReport?)? = nil
    ) {
        foregroundOperation = operation
        foregroundError = error
        foregroundReport = report
    }

    func perform(_ trigger: LibraryAutomationTrigger) async -> Bool {
        await performWithOutcome(trigger).succeeded
    }

    func performWithOutcome(_ trigger: LibraryAutomationTrigger) async -> LibraryAutomationOutcome {
        // Coalesce overlapping foreground, reader, and background triggers.
        // The active operation owns all mutations, and later callers await its
        // actual result so a background task cannot report success while the
        // process-wide pass is still running.
        guard !isPerforming else { return await waitForActivePass() }
        isPerforming = true

        var result = await performProcessOperation(trigger)
        result.succeeded = result.succeeded && !Task.isCancelled
        completeActivePass(result: result)
        return result
    }

    private func performProcessOperation(_ trigger: LibraryAutomationTrigger) async -> LibraryAutomationOutcome {
        if trigger != .backgroundProcessing, let foregroundOperation {
            let report = foregroundReport
            let error = foregroundError
            let previousReport = report?()
            let succeeded = await foregroundOperation(trigger)
            lastError = succeeded ? nil : (error?() ?? "Automation could not finish. Try again.")
            guard let report else {
                return .init(succeeded: succeeded, contentChanged: true)
            }
            return .init(succeeded: succeeded, previous: previousReport, report: report())
        }
        if let processOperation {
            let succeeded = await processOperation(trigger)
            lastError = succeeded ? nil : "Automation could not finish. Try again."
            return .init(succeeded: succeeded, contentChanged: true)
        }

        let model: AppModel
        if let processModel {
            model = processModel
        } else {
            model = AppModel(isLibraryAutomationProcess: true)
            processModel = model
        }

        await model.bootstrap()
        guard model.isReadyForProcessLibraryAutomation else {
            lastError = "Library storage is still starting."
            return .cancelled
        }
        guard !Task.isCancelled else {
            lastError = "Library automation was cancelled."
            return .cancelled
        }
        await model.reloadProcessLibraryAutomationConfiguration()
        guard !Task.isCancelled else {
            lastError = "Library automation was cancelled."
            return .cancelled
        }
        let previousReport = model.settingsSyncModel.lastAutomationRun
        let succeeded = await model.runLibraryAutomation(trigger: trigger)
        lastError = model.settingsSyncModel.automationLastError
        return .init(succeeded: succeeded, previous: previousReport, report: model.settingsSyncModel.lastAutomationRun)
    }

    private func waitForActivePass() async -> LibraryAutomationOutcome {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                activeWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        activeWaiters.removeValue(forKey: waiterID)?.resume(returning: .cancelled)
    }

    private func completeActivePass(result: LibraryAutomationOutcome) {
        isPerforming = false
        let waiters = Array(activeWaiters.values)
        activeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    var coalescedCallerCount: Int {
        activeWaiters.count
    }

    var isEnabled: Bool {
        rules.checksForUpdates || rules.deletesCompletedDownloads
    }

    #if !targetEnvironment(macCatalyst)
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            // Expiration may arrive on the scheduler's private queue before
            // MainActor gets a chance to start the app-owned operation. The
            // relay remembers that race and cancels the work when installed.
            let cancellationRelay = BackgroundTaskCancellationRelay()
            processingTask.expirationHandler = {
                Task { await cancellationRelay.expire() }
            }

            let workTask = Task { @MainActor in
                await LibraryAutomationHandoff.shared.handle(processingTask)
            }
            Task { await cancellationRelay.install(workTask) }
        }
    }

    private func handle(_ task: BGProcessingTask) async {
        var succeeded = false
        defer {
            // The process model hydrates durable rules before this point, so
            // the next request does not depend on any SwiftUI scene appearing.
            rescheduleBackgroundTask()
            task.setTaskCompleted(success: succeeded)
        }

        guard !Task.isCancelled else { return }
        succeeded = await perform(.backgroundProcessing)
        succeeded = succeeded && !Task.isCancelled
    }

    private func rescheduleBackgroundTask() {
        schedulingError = nil
        switch LibraryAutomationPolicy.backgroundScheduleAction(
            rules: rules,
            now: .now
        ) {
        case .cancel:
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)

        case let .submit(specification):
            let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
            request.earliestBeginDate = specification.earliestBeginDate
            request.requiresNetworkConnectivity = specification.requiresNetworkConnectivity
            request.requiresExternalPower = specification.requiresExternalPower
            do {
                // Submitting the same identifier replaces its pending request.
                // Do not pre-cancel: a rejected replacement must leave the
                // previously accepted request available as a fallback.
                try BGTaskScheduler.shared.submit(request)
            } catch {
                schedulingError = "Background maintenance could not be scheduled. Saved rules can still run while Manko is open."
                logger.error("Could not schedule library maintenance: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    #else
    func registerBackgroundTask() {}
    private func rescheduleBackgroundTask() {}
    #endif
}

#if !targetEnvironment(macCatalyst)
actor BackgroundTaskCancellationRelay {
    private var workTask: Task<Void, Never>?
    private var hasExpired = false

    func install(_ task: Task<Void, Never>) {
        guard !hasExpired else {
            task.cancel()
            return
        }
        workTask = task
    }

    func expire() {
        hasExpired = true
        workTask?.cancel()
        workTask = nil
    }
}
#endif

@MainActor
final class BackgroundDownloadHandoff {
    typealias CoordinatorLoader = @MainActor @Sendable (Bool, String) async throws -> DownloadCoordinator

    static let shared = BackgroundDownloadHandoff()
    static let sessionIdentifier = "com.k800k.manko.background-downloads"

    private let defaults: UserDefaults
    private let coordinatorLoader: CoordinatorLoader?
    private var coordinator: DownloadCoordinator?
    private var completions: [CompletionBox] = []
    private var bootstrapTask: Task<Void, Never>?
    private var handlerIsInstalled = false
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.k800k.manko",
        category: "BackgroundDownloads"
    )

    init(
        defaults: UserDefaults = .standard,
        coordinatorLoader: CoordinatorLoader? = nil
    ) {
        self.defaults = defaults
        self.coordinatorLoader = coordinatorLoader
    }

    func register(_ coordinator: DownloadCoordinator) {
        if self.coordinator !== coordinator {
            self.coordinator = coordinator
            handlerIsInstalled = false
        }
        ensureCoordinatorAndHandler()
    }

    func receive(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        completions.append(CompletionBox(completionHandler))
        ensureCoordinatorAndHandler()
    }

    func waitForPendingBootstrap() async {
        while let bootstrapTask {
            await bootstrapTask.value
        }
    }

    private func ensureCoordinatorAndHandler() {
        guard !completions.isEmpty, !handlerIsInstalled, bootstrapTask == nil else { return }
        bootstrapTask = Task { @MainActor [weak self] in
            await self?.bootstrapCoordinatorAndInstallHandler()
        }
    }

    private func bootstrapCoordinatorAndInstallHandler() async {
        defer {
            bootstrapTask = nil
            // A completion can arrive while an immediately-delivered latched
            // event is unwinding. Start a fresh one-shot handler if needed.
            ensureCoordinatorAndHandler()
        }

        do {
            if coordinator == nil {
                let wifiOnly = defaults.object(forKey: "wifiOnlyDownloads") as? Bool ?? true
                let deviceID = persistedDeviceID()
                if let coordinatorLoader {
                    coordinator = try await coordinatorLoader(wifiOnly, deviceID)
                } else {
                    let services = try await SharedAppServices.shared.load(
                        wifiOnlyDownloads: wifiOnly,
                        deviceID: deviceID
                    )
                    coordinator = services.downloadCoordinator
                }
            }

            guard let coordinator else {
                finishPendingCompletions()
                return
            }
            handlerIsInstalled = true
            await coordinator.setBackgroundEventsCompletionHandler { [weak self] in
                self?.finishPendingCompletions()
            }
        } catch {
            logger.error("Could not restore background downloads: \(error.localizedDescription, privacy: .public)")
            finishPendingCompletions()
        }
    }

    private func persistedDeviceID() -> String {
        if let value = defaults.string(forKey: "deviceID") {
            return value
        }
        let value = UUID().uuidString
        defaults.set(value, forKey: "deviceID")
        return value
    }

    private func finishPendingCompletions() {
        handlerIsInstalled = false
        let pendingCompletions = completions
        completions.removeAll()
        for completion in pendingCompletions {
            completion.call()
        }
    }
}

@MainActor
private final class CompletionBox {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        handler()
    }
}
