//
//  MockGeocoder.swift
//  ContactLocationManagerExample
//
//  Created by Marco Abundo on 10/16/26.
//

import Contacts
import CoreLocation
import ContactLocationManager

/// Returns a random coordinate for every address, without using the network.
/// An address with an empty street has no match, to try the list of addresses that weren't found.
nonisolated struct MockGeocoder: Geocoder {
    func coordinate(for postalAddress: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        if postalAddress.street.isEmpty { return nil }
        return CLLocationCoordinate2D(latitude: .random(in: -90...90), longitude: .random(in: -180...180))
    }
}
