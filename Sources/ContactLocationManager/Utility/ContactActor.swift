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

    /// Builds an annotation for every ContactLocation, looking up only their contacts in one request.
    func fetchAll() async throws -> [ContactLocationAnnotation] {
        let contactLocationSnapshots = await SkopelosClient.shared.read { context in
            ContactLocation.SK_all(context).map {
                ContactLocationSnapshot(contactId: $0.contactId, latitude: $0.latitude, longitude: $0.longitude, postalAddressId: $0.postalAddressId, )
            }
        }

        guard !contactLocationSnapshots.isEmpty else { return [] }

        let fetchRequest = CNContactFetchRequest(keysToFetch: contactKeys.descriptors)
        fetchRequest.predicate = CNContact.predicateForContacts(withIdentifiers: contactLocationSnapshots.map(\.contactId))

        var contactsById = [String: CNContact]()

        try CNContactStore().enumerateContacts(with: fetchRequest) { (contact, stopPointer) in
            contactsById[contact.identifier] = contact
        }

        return contactLocationSnapshots.compactMap { contactLocationSnapshot in
            guard let contact = contactsById[contactLocationSnapshot.contactId],
                  let labeledAddress = contact.postalAddresses.first(where: { $0.identifier == contactLocationSnapshot.postalAddressId }) else { return nil }
            return ContactLocationAnnotation(contact: contact, labeledAddress: labeledAddress, latitude: contactLocationSnapshot.latitude, longitude: contactLocationSnapshot.longitude)
        }
    }

    /// The addresses a provider found no match for, with their contacts looked up in one request.
    /// With the right `extraKeys` the contacts carry what `CNContactViewController(for:)` needs, so the host can show them as given.
    /// `extraKeys` come from the caller because `CNContactViewController`'s descriptor is main-actor isolated.
    func fetchFailedAddresses(extraKeys: ContactKeys) async throws -> [UngeocodedAddress] {
        let failures = await SkopelosClient.shared.read { context in
            FailedAddress.SK_all(context).map { (contactId: $0.contactId, postalAddressId: $0.postalAddressId) }
        }

        guard !failures.isEmpty else { return [] }

        let fetchRequest = CNContactFetchRequest(keysToFetch: contactKeys.descriptors + extraKeys.descriptors)
        fetchRequest.predicate = CNContact.predicateForContacts(withIdentifiers: failures.map(\.contactId))

        var contactsById = [String: CNContact]()

        try CNContactStore().enumerateContacts(with: fetchRequest) { (contact, stopPointer) in
            contactsById[contact.identifier] = contact
        }

        return failures.compactMap { failure in
            guard let contact = contactsById[failure.contactId],
                  let labeledAddress = contact.postalAddresses.first(where: { $0.identifier == failure.postalAddressId }) else { return nil }
            return UngeocodedAddress(contact: contact, labeledAddress: labeledAddress)
        }
    }

    /// Throws .offline or .cancelled before touching the store if the change couldn't be geocoded.
    func apply(_ change: ContactHistoryChange) async throws(GeocodingError) {
        switch change {
        case .removeAll: removeAll()
        case .insert(let contact): try await insert(contact)
        case .update(let contact): try await update(with: contact)
        case .delete(let identifier): delete(contactIdentifier: identifier)
        }
    }

    func removeAll() {
        SkopelosClient.shared.writeSync { context in
            ContactLocation.SK_removeAll(context)
            FailedAddress.SK_removeAll(context)
        }
    }

    /// Replaces any locations already stored for the contact, so applying a change twice is harmless.
    func insert(_ contact: CNContact) async throws(GeocodingError) {
        try await update(with: contact)
    }

    func update(with contact: CNContact) async throws(GeocodingError) {
        let result = try await geocode(contact)

        SkopelosClient.shared.writeSync { context in
            Self.delete(contactIdentifier: contact.identifier, in: context)
            Self.createLocations(for: contact, coordinates: result.coordinates, in: context)
            Self.createFailedAddresses(for: contact, addressIds: result.noMatchAddressIds, in: context)
        }
    }
    
    func delete(contactIdentifier: String) {
        SkopelosClient.shared.writeSync { context in
            Self.delete(contactIdentifier: contactIdentifier, in: context)
        }
    }

    /// Postal address identifiers stored for the contact, for tests.
    func storedAddressIds(forContactId contactId: String) async -> (located: Set<String>, failed: Set<String>) {
        await SkopelosClient.shared.read { context in
            let located = ContactLocation.SK_all("contactId", isEqualTo: contactId, sortTerms: "contactId", ascending: false, context: context)
            let failed = FailedAddress.SK_all("contactId", isEqualTo: contactId, sortTerms: "contactId", ascending: false, context: context)
            return (Set(located.map(\.postalAddressId)), Set(failed.map(\.postalAddressId)))
        }
    }

    func savedToken() async -> Data? {
        await SkopelosClient.shared.read { context in
            SyncToken.SK_all(context).first?.data
        }
    }

    func saveToken(_ token: Data?) {
        SkopelosClient.shared.writeSync { context in
            SyncToken.SK_removeAll(context)
            if let token { SyncToken.SK_create(context).data = token }
        }
    }
    
    // MARK: - Private API

    private struct GeocodeResult {
        /// Keyed by postal address identifier.
        var coordinates: [String: CLLocationCoordinate2D] = [:]
        /// Addresses a provider answered with "no match", for the user to correct.
        var noMatchAddressIds: [String] = []
    }

    private enum Lookup {
        case located(CLLocationCoordinate2D)
        case noMatch
        /// Not looked up, or the lookup failed. Nothing is known about the address, so it isn't reported.
        case skipped
    }

    /// Geocodes each postal address of the contact. Throws `.offline` or `.cancelled` so the sync can pause.
    private func geocode(_ contact: CNContact) async throws(GeocodingError) -> GeocodeResult {
        var result = GeocodeResult()
        for address in contact.postalAddresses {
            switch try await geocode(address.value) {
            case .located(let coordinate): result.coordinates[address.identifier] = coordinate
            case .noMatch: result.noMatchAddressIds.append(address.identifier)
            case .skipped: break
            }
        }
        return result
    }

    private func geocode(_ address: CNPostalAddress) async throws(GeocodingError) -> Lookup {
        do throws(GeocodingError) {
            guard let coordinate = try await geocoder.coordinate(for: address) else {
                // The address is personal data, so it stays redacted in the unified log.
                Logger.geocoding.notice("No match for \(address.addressString, privacy: .private)")
                return .noMatch
            }
            return .located(coordinate)
        } catch .offline {
            throw .offline
        } catch .cancelled {
            throw .cancelled
        } catch .requestLimitReached {
            // Expected once the host's limit is used up, and every remaining address hits it, so it isn't
            // logged per address. The fetcher logs it once when the pass ends.
            return .skipped
        } catch {
            // A single provider reports a cancelled request as an ordinary failure, so ask the task itself.
            // Storing "no match" here would lose the address for good once the token moves on.
            if Task.isCancelled { throw .cancelled }
            // The address is personal data, so it stays redacted in the unified log.
            Logger.geocoding.error("Geocoding failure for \(address.addressString, privacy: .private): \(error, privacy: .public)")
            return .skipped
        }
    }

    private static func delete(contactIdentifier: String, in context: NSManagedObjectContext) {
        let contactLocations = ContactLocation.SK_all("contactId", isEqualTo: contactIdentifier, sortTerms: "contactId", ascending: false, context: context)
        
        for contactLocation in contactLocations {
            contactLocation.SK_remove(context)
        }

        let failedAddresses = FailedAddress.SK_all("contactId", isEqualTo: contactIdentifier, sortTerms: "contactId", ascending: false, context: context)

        for failedAddress in failedAddresses {
            failedAddress.SK_remove(context)
        }
    }

    private static func createFailedAddresses(for contact: CNContact, addressIds: [String], in context: NSManagedObjectContext) {
        for addressId in addressIds {
            let failedAddress = FailedAddress.SK_create(context)
            failedAddress.contactId = contact.identifier
            failedAddress.postalAddressId = addressId
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
