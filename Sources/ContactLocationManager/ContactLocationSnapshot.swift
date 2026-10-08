//
//  ContactLocationSnapshot.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 10/8/26.
//

import CoreLocation

/// An immutable, thread-safe copy of a `ContactLocation`, safe to hand across actors.
struct ContactLocationSnapshot: Sendable {
    let contactId: String
    let postalAddressId: String
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(_ contactLocation: ContactLocation) {
        contactId = contactLocation.contactId
        postalAddressId = contactLocation.postalAddressId
        latitude = contactLocation.latitude
        longitude = contactLocation.longitude
    }
}
