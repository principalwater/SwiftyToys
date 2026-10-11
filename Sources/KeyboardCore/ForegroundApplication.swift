// SPDX-License-Identifier: MIT

/// A thread-owned executable cache; unresolved contexts never inherit the previous application's rules.
public struct ForegroundApplication {
    private var processID: UInt32 = 0
    private var windowID: UInt = 0
    private var retryAt: UInt64 = 0
    public private(set) var application: String?

    /// Creates an unresolved foreground context.
    public init() {}

    /// Resolves before input processing; failures retry after one second using a monotonic millisecond clock.
    @discardableResult public mutating func resolve(
        processID: UInt32, windowID: UInt, time: UInt64, lookup: (UInt32) -> String?
    ) -> String? {
        if processID != self.processID || windowID != self.windowID {
            self.processID = processID
            self.windowID = windowID
            application = nil
            retryAt = 0
        }
        guard application == nil, processID != 0, windowID != 0, time >= retryAt else { return application }
        application = lookup(processID)
        if application?.isEmpty == true { application = nil }
        retryAt = application == nil ? time &+ 1000 : 0
        return application
    }
}
