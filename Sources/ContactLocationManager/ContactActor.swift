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
import OSLog

/// A single change reported by the contact store's change history.
enum ContactHistoryChange: Sendable {
    case removeAll
    case insert(CNContact)
    case update(CNContact)
    case delete(contactIdentifier: String)
}

/// `CNKeyDescriptor`s are immutable, but aren't marked `Sendable`.
struct ContactKeys: @unchecked Sendable {
    let descriptors: [any CNKeyDescriptor]
    init(_ descriptors: [any CNKeyDescriptor]) { self.descriptors = descriptors }
}

actor ContactActor {
    private let geocoder: any Geocoder
    private let contactKeys: ContactKeys

    init(geocoder: any Geocoder, contactKeys: ContactKeys) {
        self.geocoder = geocoder
        self.contactKeys = contactKeys
    }

    /// Builds an annotation for every stored location, looking up the contacts in one request.
    /// Returns nil if that request fails.
    func fetchAll() async -> [ContactLocationAnnotation]? {
        let contactLocations = await SkopelosClient.shared.read { context in
            ContactLocation.SK_all(context)
        }

        guard !contactLocations.isEmpty else { return [] }

        let fetchRequest = CNContactFetchRequest(keysToFetch: contactKeys.descriptors)

        var contacts = [CNContact]()

        do {
            try CNContactStore().enumerateContacts(with: fetchRequest) { (contact, stopPointer) in
                contacts.append(contact)
            }
        } catch {
            Logger.contacts.error("Contact fetch failed: \(error, privacy: .public)")
            return nil
        }

        return contactLocations.compactMap { contactLocation in
            guard let contact = contacts.first(where: { $0.identifier == contactLocation.contactId }),
                  let labeledAddress = contact.postalAddresses.first(where: { $0.identifier == contactLocation.postalAddressId }) else { return nil }
            return ContactLocationAnnotation(contact: contact, labeledAddress: labeledAddress, latitude: contactLocation.latitude, longitude: contactLocation.longitude)
        }
    }

    /// Throws `.offline` before touching the store for the change that couldn't be geocoded;
    /// changes before it have been applied.
    func apply(_ changes: [ContactHistoryChange]) async throws(GeocodingError) {
        for change in changes {
            switch change {
            case .removeAll: removeAll()
            case .insert(let contact): try await insert(contact)
            case .update(let contact): try await update(with: contact)
            case .delete(let identifier): delete(contactIdentifier: identifier)
            }
        }
    }

    func removeAll() {
        SkopelosClient.shared.writeSync { context in
            ContactLocation.SK_removeAll(context)
        }
    }

    /// Replaces any locations already stored for the contact, so applying a change twice is harmless.
    func insert(_ contact: CNContact) async throws(GeocodingError) {
        try await update(with: contact)
    }

    func update(with contact: CNContact) async throws(GeocodingError) {
        let coordinates = try await geocode(contact)

        SkopelosClient.shared.writeSync { context in
            Self.delete(contactIdentifier: contact.identifier, in: context)
            Self.createLocations(for: contact, coordinates: coordinates, in: context)
        }
    }
    
    func delete(contactIdentifier: String) {
        SkopelosClient.shared.writeSync { context in
            Self.delete(contactIdentifier: contactIdentifier, in: context)
        }
    }
    
    // MARK: - Private API

    /// Geocodes each postal address of the contact, keyed by postal address identifier.
    /// Addresses that can't be geocoded are omitted. Throws `.offline` so the sync can pause.
    private func geocode(_ contact: CNContact) async throws(GeocodingError) -> [String: CLLocationCoordinate2D] {
        var coordinates: [String: CLLocationCoordinate2D] = [:]
        for address in contact.postalAddresses {
            if let coordinate = try await geocode(address.value) {
                coordinates[address.identifier] = coordinate
            }
        }
        return coordinates
    }

    private func geocode(_ address: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        do throws(GeocodingError) {
            return try await geocoder.coordinate(for: address)
        } catch .offline {
            throw .offline
        } catch {
            // The address is personal data, so it stays redacted in the unified log.
            Logger.geocoding.error("Geocoding failure for \(address.mailingString, privacy: .private): \(error, privacy: .public)")
            return nil
        }
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
