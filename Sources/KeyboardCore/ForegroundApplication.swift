// SPDX-License-Identifier: MIT

/// A worker-owned executable cache; the native owner validates the process lifetime before consuming it.
public struct ForegroundApplication: Sendable {
    private var processID: UInt32 = 0
    private var retryAt: UInt64 = 0
    public private(set) var application: String?

    /// Creates an unresolved foreground context.
    public init() {}

    /// Reads an already resolved name without invoking a lookup. A different process fails closed.
    public func consume(processID: UInt32) -> String? {
        processID != 0 && processID == self.processID ? application : nil
    }

    /// Resolves on a worker; failures retry after one second using a monotonic millisecond clock.
    @discardableResult public mutating func resolve(
        processID: UInt32, windowID: UInt, time: UInt64, lookup: (UInt32) -> String?
    ) -> String? {
        guard processID != 0, windowID != 0 else {
            self.processID = processID
            application = nil
            retryAt = 0
            return nil
        }
        if processID != self.processID {
            self.processID = processID
            application = nil
            retryAt = 0
        }
        guard application == nil, time >= retryAt else { return application }
        application = lookup(processID)
        if application?.isEmpty == true { application = nil }
        retryAt = application == nil ? time &+ 1000 : 0
        return application
    }
}
