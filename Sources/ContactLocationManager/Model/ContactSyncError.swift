//
//  ContactSyncError.swift
//  ContactLocationManager
//

/// A problem with the sync that the fetcher can't solve by itself, for the host to show or log.
public enum ContactSyncError: Error, Sendable {
    /// Contacts couldn't be asked for its changes. `underlying` is the error Contacts gave, usually a `CNError`.
    case contactsUnreadable(underlying: any Error)
}
