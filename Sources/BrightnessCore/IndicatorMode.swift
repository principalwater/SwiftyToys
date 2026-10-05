// SPDX-License-Identifier: MIT

/// Chooses SwiftyToys's indicator or leaves an existing system indicator alone.
public enum IndicatorMode: String, Sendable, CaseIterable {
    case custom
    case system
}
