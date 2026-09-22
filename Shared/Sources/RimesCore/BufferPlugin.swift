import Foundation

public struct BufferPluginDescriptor: Equatable {
    public let id: String
    public let title: String
    public let realtime: Bool
    public init(id: String, title: String, realtime: Bool) { self.id = id; self.title = title; self.realtime = realtime }
}
public enum BufferPluginAvailability: Equatable { case ready, unavailable(String) }
public struct BufferPluginRequest {
    public let source: String
    public let revision: UUID
    public var options: [String: String]
    public init(source: String, revision: UUID, options: [String: String] = [:]) {
        self.source = source; self.revision = revision; self.options = options
    }
}
public struct BufferPluginResult {
    public let text: String
    public let revision: UUID
    public init(text: String, revision: UUID) { self.text = text; self.revision = revision }
}
@MainActor public protocol BufferPlugin: AnyObject {
    var descriptor: BufferPluginDescriptor { get }
    func availability(for request: BufferPluginRequest) async -> BufferPluginAvailability
    func execute(_ request: BufferPluginRequest, preview: @escaping @MainActor (String) -> Void) async throws -> BufferPluginResult
    func cancel()
}

/// A single worker awaits even non-cooperative cancellations before starting the latest request.
@MainActor public final class BufferPluginRunner {
    private struct Job {
        let id: UUID, plugin: any BufferPlugin, request: BufferPluginRequest
        let deadline: ContinuousClock.Instant
        let preview: @MainActor (String) -> Void
        let completion: @MainActor (Result<BufferPluginResult, Error>) -> Void
    }
    private var pending: Job?
    private var current: UUID?
    private var worker: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var operation: Task<BufferPluginResult, Error>?
    private var activePlugin: (any BufferPlugin)?
    public init() {}
    public func cancel() {
        current = nil; pending = nil; debounce?.cancel(); operation?.cancel(); activePlugin?.cancel()
    }
    public func submit(plugin: any BufferPlugin, request: BufferPluginRequest, delayNanoseconds: UInt64 = 400_000_000,
                       preview: @escaping @MainActor (String) -> Void,
                       completion: @escaping @MainActor (Result<BufferPluginResult, Error>) -> Void) {
        cancel()
        let id = UUID(); current = id
        pending = Job(id: id, plugin: plugin, request: request, deadline: .now.advanced(by: .nanoseconds(Int64(min(delayNanoseconds, UInt64(Int64.max))))), preview: preview, completion: completion)
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }
    private func drain() async {
        while let job = pending {
            pending = nil
            let timer = Task<Void, Never> { try? await Task.sleep(until: job.deadline, clock: .continuous) }
            debounce = timer
            await timer.value
            debounce = nil
            guard current == job.id else { continue }
            activePlugin = job.plugin
            let task = Task { @MainActor [weak self] in
                guard job.request.source.utf8.count <= 64 * 1024 else { throw CoreError.tooLarge }
                let state = await job.plugin.availability(for: job.request)
                try Task.checkCancellation()
                if case let .unavailable(reason) = state { throw BufferPluginError.unavailable(reason) }
                return try await job.plugin.execute(job.request) { text in
                    guard self?.current == job.id else { return }; job.preview(text)
                }
            }
            operation = task
            let result = await task.result
            operation = nil; activePlugin = nil
            if current == job.id { job.completion(result) }
        }
        worker = nil
    }
}
public enum BufferPluginError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { if case let .unavailable(reason) = self { return reason }; return nil }
}
