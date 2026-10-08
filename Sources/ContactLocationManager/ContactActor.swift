//
//  ContactActor.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 10/8/26.
//

// Source - https://stackoverflow.com/a/75860924
// Posted by AnderCover, modified by community. See post 'Timeline' for change history
// Retrieved 2026-10-08, License - CC BY-SA 4.0

import CoreData
@preconcurrency import Contacts
import MapKit

/// A single change reported by the contact store's change history.
enum ContactHistoryChange: Sendable {
    case removeAll
    case insert(CNContact)
    case update(CNContact)
    case delete(contactIdentifier: String)
}

actor ContactActor {
    static let shared = ContactActor()
    
    func fetchAll() async -> [ContactLocationSnapshot] {
        await SkopelosClient.shared.readAsync { context in
            ContactLocation.SK_all(context).map(ContactLocationSnapshot.init)
        }
    }

    func apply(_ changes: [ContactHistoryChange]) async {
        for change in changes {
            switch change {
            case .removeAll: removeAll()
            case .insert(let contact): await insert(contact)
            case .update(let contact): await update(with: contact)
            case .delete(let identifier): delete(contactIdentifier: identifier)
            }
        }
    }

    func removeAll() {
        SkopelosClient.shared.writeSync { context in
            ContactLocation.SK_removeAll(context)
        }
    }
    
    func insert(_ contact: CNContact) async {
        let coordinates = await geocode(contact)
        SkopelosClient.shared.writeSync { context in
            Self.createLocations(for: contact, coordinates: coordinates, in: context)
        }
    }
    
    func update(with contact: CNContact) async {
        let coordinates = await geocode(contact)

        SkopelosClient.shared.writeSync { context in
            Self.delete(contactIdentifier: contact.identifier, in: context)
        }.writeSync { context in
            Self.createLocations(for: contact, coordinates: coordinates, in: context)
        }
    }
    
    func delete(contactIdentifier: String) {
        SkopelosClient.shared.writeSync { context in
            Self.delete(contactIdentifier: contactIdentifier, in: context)
        }
    }

    /// Geocodes each postal address of the contact, keyed by postal address identifier.
    /// Addresses that can't be geocoded are omitted.
    private func geocode(_ contact: CNContact) async -> [String: CLLocationCoordinate2D] {
        var coordinates: [String: CLLocationCoordinate2D] = [:]
        for address in contact.postalAddresses {
            if let coordinate = await geocode(address.value) {
                coordinates[address.identifier] = coordinate
            }
        }
        return coordinates
    }

    private func geocode(_ address: CNPostalAddress) async -> CLLocationCoordinate2D? {
        var coordinate: CLLocationCoordinate2D?

        let addressString = CNPostalAddressFormatter.string(from: address, style: .mailingAddress)

        guard let request = MKGeocodingRequest(addressString: addressString) else {
            return coordinate
        }

        do {
            let mapItems = try await request.mapItems
            if let item = mapItems.first {
                coordinate = item.location.coordinate
            }
        } catch {
            print("geocoding failure for \(addressString): \(error)")
        }
        
        return coordinate
    }
    
    private static func delete(contactIdentifier: String, in context: NSManagedObjectContext) {
        let contactLocations = ContactLocation.SK_all("contactId", isEqualTo: contactIdentifier, sortTerms: "contactId", ascending: false, context: context)
        
        for contactLocation in contactLocations {
            contactLocation.SK_remove(context)
        }
    }

    private static func createLocations(for contact: CNContact, coordinates: [String: CLLocationCoordinate2D], in context: NSManagedObjectContext) {
        for address in contact.postalAddresses {
            guard let coordinate = coordinates[address.identifier] else { continue }
            let contactLocation = ContactLocation.SK_create(context)
            contactLocation.contactId = contact.identifier
            contactLocation.postalAddressId = address.identifier
            contactLocation.latitude = coordinate.latitude
            contactLocation.longitude = coordinate.longitude
        }
    }
}
