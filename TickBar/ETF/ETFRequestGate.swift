import Foundation

/// Spaces request starts for one provider and observes its rate-limit cooldown.
actor ETFRequestGate {
    private let spacing: TimeInterval
    private var nextStart = Date.distantPast
    private var cooldownUntil = Date.distantPast
    private var consecutiveFailures = 0

    init(spacing: TimeInterval = 0.25) { self.spacing = spacing }

    func wait() async throws {
        let now = Date()
        guard cooldownUntil <= now else { throw HTTPError.rateLimited(cooldownUntil.timeIntervalSince(now)) }
        let slot = max(now, nextStart)
        nextStart = slot.addingTimeInterval(spacing)
        let delay = slot.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
        guard cooldownUntil <= Date() else { throw HTTPError.rateLimited(cooldownUntil.timeIntervalSinceNow) }
    }

    func rateLimited(for delay: TimeInterval?) {
        let seconds = max(delay ?? 30, 1)
        cooldownUntil = max(cooldownUntil, Date().addingTimeInterval(seconds))
    }

    func succeeded() { consecutiveFailures = 0 }

    func failed() {
        consecutiveFailures += 1
        guard consecutiveFailures >= 3 else { return }
        let seconds = min(60.0, 5.0 * pow(2.0, Double(min(consecutiveFailures - 3, 4))))
        cooldownUntil = max(cooldownUntil, Date().addingTimeInterval(seconds))
    }
}

func etfRequest<T>(gate: ETFRequestGate, _ request: () async throws -> T) async throws -> T {
    try await gate.wait()
    do {
        let result = try await request()
        await gate.succeeded()
        return result
    } catch HTTPError.rateLimited(let delay) {
        await gate.rateLimited(for: delay)
        throw HTTPError.rateLimited(delay)
    } catch {
        if !Task.isCancelled {
            switch error {
            case HTTPError.transport: await gate.failed()
            case HTTPError.badStatus(let status) where status >= 500: await gate.failed()
            default: break
            }
        }
        throw error
    }
}

/// Retry transient failures once with jitter. Invalid data and throttling use fallback directly.
func etfAttempt<T>(source: String, operation: String, _ request: () async throws -> T) async -> T? {
    for attempt in 0..<2 {
        guard !Task.isCancelled else { return nil }
        do { return try await request() }
        catch {
            guard !Task.isCancelled else { return nil }
            Log.net.warning("ETF \(source, privacy: .public) \(operation, privacy: .public): \(String(describing: error), privacy: .public)")
            let retryable: Bool
            switch error {
            case HTTPError.transport: retryable = true
            case HTTPError.badStatus(let status): retryable = status >= 500
            default: retryable = false
            }
            guard attempt == 0, retryable else { return nil }
            do { try await Task.sleep(nanoseconds: UInt64.random(in: 400_000_000...900_000_000)) }
            catch { return nil }
        }
    }
    return nil
}
