import Foundation

public struct CaptureAttempt<Value: Sendable>: Sendable {
    public let value: Value
    public let attempts: Int
}

/// Retry only a cold/empty accessibility read, within one explicit user gesture.
/// Revalidate the target after every suspension; never consume a second application's text.
public enum BoundedCapture {
    public static func read<Value: Sendable>(
        delay: Duration = .milliseconds(140),
        targetIsCurrent: @Sendable () async -> Bool,
        capture: @Sendable () async -> Value,
        isUseful: @Sendable (Value) -> Bool
    ) async -> CaptureAttempt<Value>? {
        for attempt in 1...3 {
            if attempt > 1 {
                do { try await Task.sleep(for: delay) } catch { return nil }
            }
            guard !Task.isCancelled, await targetIsCurrent() else { return nil }
            let value = await capture()
            guard !Task.isCancelled, await targetIsCurrent() else { return nil }
            if isUseful(value) || attempt == 3 { return CaptureAttempt(value: value, attempts: attempt) }
        }
        return nil
    }
}
