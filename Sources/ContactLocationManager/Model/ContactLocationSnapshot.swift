//
//  ContactLocationSnapshot.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 11/1/26.
//

import CoreLocation

/// A ContactLocation copied out of its managed object, so it can leave the context's queue.
struct ContactLocationSnapshot: Sendable {
    let contactId: String
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees
    let postalAddressId: String
}
