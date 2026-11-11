//
//  Logging.swift
//  ContactLocationManager
//

import Foundation
import OSLog

/// An error's domain and code, for the log. A Contacts error's `userInfo` can name the contacts involved,
/// so the whole error isn't logged.
func logDescription(of error: any Error) -> String {
    let error = error as NSError
    return "\(error.domain) \(error.code)"
}

extension Logger {
    private static let subsystem = "com.shrtlist.ContactLocationManager"

    /// Geocoder selection and failures.
    static let geocoding = Logger(subsystem: subsystem, category: "Geocoding")
    /// Reading contacts from the contact store.
    static let contacts = Logger(subsystem: subsystem, category: "Contacts")
    /// The Core Data store of geocoded locations.
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
}
