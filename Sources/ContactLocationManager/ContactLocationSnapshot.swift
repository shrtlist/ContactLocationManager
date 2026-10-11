//
//  ContactLocationSnapshot.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 10/8/26.
//

import CoreLocation

/// An immutable, thread-safe copy of a `ContactLocation`, safe to hand across actors.
public struct ContactLocationSnapshot: Sendable {
    public let contactId: String
    public let postalAddressId: String
    public let latitude: CLLocationDegrees
    public let longitude: CLLocationDegrees

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(_ contactLocation: ContactLocation) {
        contactId = contactLocation.contactId
        postalAddressId = contactLocation.postalAddressId
        latitude = contactLocation.latitude
        longitude = contactLocation.longitude
    }
}
