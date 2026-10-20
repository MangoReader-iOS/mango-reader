import Foundation
import OSLog
// WasmKit 0.4.1 exposes its allocation limiter through this SPI.
@_spi(Fuzzing) import WasmKit

actor MangoReaderWasmInstance {
    enum ExecutionLimit: String, Sendable {
        case dispatchFuel, invocationFuel
    }
    struct InvocationContext: Sendable {
        var sourceID: String
        var operation: String
        var startedAt: ContinuousClock.Instant = .now
    }
    private static let logger = Logger(subsystem: "com.k800k.manko", category: "WasmExecution")
    static let memoryBytes = 128 * 1_024 * 1_024
    static let dispatchFuel: UInt64 = 100_000_000
    static let invocationFuel: UInt64 = 500_000_000
    private var store: Store?
    private var instance: Instance?
    private var budgets: [UUID: UInt64] = [:]
    private let fuelPerDispatch: UInt64
    private let fuelPerInvocation: UInt64
    private(set) var lastExecutionLimit: ExecutionLimit?

    init(dispatchFuel: UInt64 = MangoReaderWasmInstance.dispatchFuel, invocationFuel: UInt64 = MangoReaderWasmInstance.invocationFuel) {
        fuelPerDispatch = dispatchFuel
        fuelPerInvocation = invocationFuel
    }

    private final class Limits: ResourceLimiter {
        func limitMemoryGrowth(to desired: Int) throws -> Bool { desired <= MangoReaderWasmInstance.memoryBytes }
        func limitTableGrowth(to desired: Int) throws -> Bool { desired <= 16_384 }
    }

    func load(url: URL) throws {
        try Task.checkCancellation()
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !bytes.isEmpty, bytes.count <= SourceRepositoryLimits.scriptBytes,
              bytes.starts(with: [0, 97, 115, 109, 1, 0, 0, 0]) else {
            throw MangoReaderExtensionRuntimeError.invalidPackage
        }
        // WasmKit 0.4.1's direct-threaded ARM64 handlers clobber x22 in the
        // optimized build while runDirectThreaded keeps its trap-field address
        // there. Even normal guest completion can then retain a guest value as
        // an Error (TestFlight build 7). Use Swift's token loop in every build
        // configuration until the direct-threaded calling convention is fixed.
        let engine = Engine(configuration: EngineConfiguration(
            threadingModel: .token,
            features: [.referenceTypes], memoryBoundsChecking: .software, fuelMetering: true
        ))
        let module = try parseWasm(bytes: Array(bytes), features: engine.configuration.features)
        guard module.imports.isEmpty else { throw MangoReaderExtensionRuntimeError.invalidPackage }
        let store = Store(engine: engine)
        store.resourceLimiter = Limits()
        store.fuel = Fuel(remaining: fuelPerDispatch)
        let instance = try module.instantiate(store: store)
        guard let memory = instance.exports[memory: "memory"], memory.byteCount <= Self.memoryBytes,
              instance.exports[function: "manko_alloc"]?.type == FunctionType(parameters: [.i32], results: [.i32]),
              instance.exports[function: "manko_dealloc"]?.type == FunctionType(parameters: [.i32, .i32], results: []),
              instance.exports[function: "manko_dispatch"]?.type == FunctionType(parameters: [.i32, .i32], results: [.i64]) else {
            throw MangoReaderExtensionRuntimeError.invalidPackage
        }
        self.store = store
        self.instance = instance
    }

    func dispatch(_ input: JSONValue, owner: UUID, context: InvocationContext? = nil) throws -> JSONValue {
        try Task.checkCancellation()
        lastExecutionLimit = nil
        guard let store, let instance, let memory = instance.exports[memory: "memory"],
              let allocate = instance.exports[function: "manko_alloc"],
              let deallocate = instance.exports[function: "manko_dealloc"],
              let dispatch = instance.exports[function: "manko_dispatch"] else {
            throw MangoReaderExtensionRuntimeError.runtimeTerminated
        }
        let data = try JSONEncoder().encode(input)
        guard data.count <= 32 * 1_024 * 1_024 else { throw MangoReaderExtensionRuntimeError.responseTooLarge }
        let remaining = budgets[owner] ?? fuelPerInvocation
        let budget = min(remaining, fuelPerDispatch)
        guard budget > 0 else {
            reportFuelLimit(.invocationFuel, budget: budget, remaining: 0, owner: owner, context: context)
            throw MangoReaderExtensionRuntimeError.executionBudgetExceeded
        }
        store.fuel = Fuel(remaining: budget)
        defer { budgets[owner] = remaining - (budget - (store.fuel?.remaining ?? 0)) }
        do {
            guard case let .i32(pointer)? = try allocate([.i32(UInt32(data.count))]).first else {
                throw MangoReaderExtensionRuntimeError.invalidPackage
            }
            try validate(pointer: pointer, count: data.count, memory: memory)
            _ = memory.withUnsafeMutableBufferPointer(offset: UInt(pointer), count: data.count) { buffer in
                data.copyBytes(to: buffer.bindMemory(to: UInt8.self))
            }
            guard case let .i64(packed)? = try dispatch([.i32(pointer), .i32(UInt32(data.count))]).first else {
                throw MangoReaderExtensionRuntimeError.invalidPackage
            }
            _ = try deallocate([.i32(pointer), .i32(UInt32(data.count))])
            let outputPointer = UInt32(truncatingIfNeeded: packed >> 32)
            let outputCount = Int(UInt32(truncatingIfNeeded: packed))
            guard outputCount <= 24 * 1_024 * 1_024 else { throw MangoReaderExtensionRuntimeError.responseTooLarge }
            try validate(pointer: outputPointer, count: outputCount, memory: memory)
            let output = memory.withUnsafeBufferPointer(offset: UInt(outputPointer), count: outputCount) { Data($0) }
            _ = try deallocate([.i32(outputPointer), .i32(UInt32(outputCount))])
            try Task.checkCancellation()
            return try JSONDecoder().decode(JSONValue.self, from: output)
        } catch {
            // Cancellation is checked after the guest returned and its buffers
            // were freed. It does not corrupt the shared instance; discarding it
            // here would leave the still-valid runtime unable to handle retries.
            if error is CancellationError { throw error }
            // A trapped guest may have partially mutated its allocator or futures.
            self.instance = nil
            self.store = nil
            // WasmKit charges entire regions, leaving a nonzero remainder
            // when the next region costs more than the available budget.
            if let trap = error as? Trap {
                Self.logger.debug("WASM trap: \(trap.description, privacy: .private)")
                if trap.description.split(separator: "\n", maxSplits: 1).first == "Trap: out of fuel" {
                    reportFuelLimit(remaining <= fuelPerDispatch ? .invocationFuel : .dispatchFuel,
                                    budget: budget, remaining: store.fuel?.remaining ?? 0, owner: owner, context: context)
                    throw MangoReaderExtensionRuntimeError.executionBudgetExceeded
                }
            }
            if store.fuel?.remaining == 0 {
                reportFuelLimit(remaining <= fuelPerDispatch ? .invocationFuel : .dispatchFuel,
                                budget: budget, remaining: 0, owner: owner, context: context)
                throw MangoReaderExtensionRuntimeError.executionBudgetExceeded
            }
            throw (error as? MangoReaderExtensionRuntimeError) ?? MangoReaderExtensionRuntimeError.invalidPackage
        }
    }

    // Guest cleanup and budget removal are one actor turn. A late cancelled
    // dispatch checks cancellation before it can recreate this owner's budget.
    func cancelAndFinish(_ owner: UUID, context: InvocationContext?) throws {
        defer { budgets[owner] = nil }
        guard instance != nil else { return }
        _ = try dispatch(.object([
            "action": .string("cancel"), "invocationID": .string(owner.uuidString)
        ]), owner: owner, context: context)
    }

    func finish(_ owner: UUID) { budgets[owner] = nil }

    private func reportFuelLimit(_ limit: ExecutionLimit, budget: UInt64, remaining: UInt64, owner: UUID, context: InvocationContext?) {
        lastExecutionLimit = limit
        let source = context?.sourceID ?? "unknown"
        let operation = context?.operation ?? "dispatch"
        let elapsed = context.map { String(describing: $0.startedAt.duration(to: .now)) } ?? "unknown"
        Self.logger.notice("source=\(source, privacy: .public) operation=\(operation, privacy: .public) invocation=\(owner.uuidString, privacy: .public) elapsed=\(elapsed, privacy: .public) WASM execution limit: \(limit.rawValue, privacy: .public); dispatchBudget=\(budget) remaining=\(remaining)")
    }

    func invalidate() {
        instance = nil
        store = nil
        budgets.removeAll()
    }

    private func validate(pointer: UInt32, count: Int, memory: Memory) throws {
        guard count >= 0, UInt64(pointer) + UInt64(count) <= UInt64(memory.byteCount),
              memory.byteCount <= Self.memoryBytes else { throw MangoReaderExtensionRuntimeError.invalidPackage }
    }
}
