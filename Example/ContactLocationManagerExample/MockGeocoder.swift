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
struct MockGeocoder: Geocoder {
    func coordinate(for address: CNPostalAddress) async throws -> CLLocationCoordinate2D? {
        CLLocationCoordinate2D(latitude: .random(in: -90...90), longitude: .random(in: -180...180))
    }
}
