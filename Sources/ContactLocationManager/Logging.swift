//
//  Logging.swift
//  ContactLocationManager
//

import OSLog

extension Logger {
    private static let subsystem = "com.shrtlist.ContactLocationManager"

    /// Geocoder selection and failures.
    static let geocoding = Logger(subsystem: subsystem, category: "Geocoding")
    /// Reading contacts from the contact store.
    static let contacts = Logger(subsystem: subsystem, category: "Contacts")
    /// The Core Data store of geocoded locations.
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
}
