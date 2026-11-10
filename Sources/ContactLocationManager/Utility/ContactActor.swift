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

    /// Throws .offline, .rateLimited or .cancelled before touching the store if the change couldn't be geocoded.
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

    /// Looks up only the addresses whose text changed since they were last answered, so an edit to something
    /// else, or a replay of the same history, costs no requests and can't lose a pin that is still right.
    ///
    /// For each address: an unchanged one is left as it is; a found one is stored; a "no match" is recorded for
    /// the user to correct; one that couldn't be asked loses its old pin, because the address changed and the
    /// old pin belongs to a different one.
    func update(with contact: CNContact) async throws(GeocodingError) {
        let answered = await answeredFingerprints(forContactId: contact.identifier)
        let needsLookup = contact.postalAddresses.filter { answered[$0.identifier] != $0.value.fingerprint }
        let lookups = try await geocode(needsLookup)

        SkopelosClient.shared.writeSync { context in
            Self.store(lookups, for: contact, in: context)
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

    /// Latitude stored for each postal address of the contact, for tests.
    func storedLatitudes(forContactId contactId: String) async -> [String: Double] {
        await SkopelosClient.shared.read { context in
            let rows = ContactLocation.SK_all("contactId", isEqualTo: contactId, sortTerms: "contactId", ascending: false, context: context)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.postalAddressId, $0.latitude) })
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

    private enum Lookup {
        case located(CLLocationCoordinate2D)
        case noMatch
        /// Not looked up, or the lookup failed. Nothing is known about the address, so it isn't reported.
        case skipped
    }

    /// Geocodes the given addresses, keyed by postal address identifier.
    /// Throws `.offline`, `.rateLimited` or `.cancelled` so the sync can pause.
    private func geocode(_ addresses: [CNLabeledValue<CNPostalAddress>]) async throws(GeocodingError) -> [String: Lookup] {
        var lookups: [String: Lookup] = [:]
        for address in addresses {
            lookups[address.identifier] = try await geocode(address.value)
        }
        return lookups
    }

    /// The fingerprint each of the contact's addresses was last answered for (found or no match), keyed by
    /// postal address identifier.
    private func answeredFingerprints(forContactId contactId: String) async -> [String: String] {
        await SkopelosClient.shared.read { context in
            var answered: [String: String] = [:]
            for row in ContactLocation.SK_all("contactId", isEqualTo: contactId, sortTerms: "contactId", ascending: false, context: context) {
                answered[row.postalAddressId] = row.addressFingerprint
            }
            for row in FailedAddress.SK_all("contactId", isEqualTo: contactId, sortTerms: "contactId", ascending: false, context: context) {
                answered[row.postalAddressId] = row.addressFingerprint
            }
            return answered
        }
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
        } catch .rateLimited {
            // Every provider is cooling down. The address is looked up again once they are back, not stored as no match.
            throw .rateLimited
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

    /// Brings the contact's rows in line with its current addresses, in one transaction. An address that
    /// has no entry in `lookups` wasn't looked up because it hasn't changed, and is left alone.
    private static func store(_ lookups: [String: Lookup], for contact: CNContact, in context: NSManagedObjectContext) {
        let locations = ContactLocation.SK_all("contactId", isEqualTo: contact.identifier, sortTerms: "contactId", ascending: false, context: context)
        let failures = FailedAddress.SK_all("contactId", isEqualTo: contact.identifier, sortTerms: "contactId", ascending: false, context: context)
        let currentIds = Set(contact.postalAddresses.map(\.identifier))

        for location in locations where !currentIds.contains(location.postalAddressId) { location.SK_remove(context) }
        for failure in failures where !currentIds.contains(failure.postalAddressId) { failure.SK_remove(context) }

        for address in contact.postalAddresses {
            guard let lookup = lookups[address.identifier] else { continue }
            let fingerprint = address.value.fingerprint
            let location = locations.first { $0.postalAddressId == address.identifier }
            let failure = failures.first { $0.postalAddressId == address.identifier }

            switch lookup {
            case .located(let coordinate):
                failure?.SK_remove(context)
                let row = location ?? ContactLocation.SK_create(context)
                row.contactId = contact.identifier
                row.postalAddressId = address.identifier
                row.latitude = coordinate.latitude
                row.longitude = coordinate.longitude
                row.addressFingerprint = fingerprint
            case .noMatch:
                location?.SK_remove(context)
                let row = failure ?? FailedAddress.SK_create(context)
                row.contactId = contact.identifier
                row.postalAddressId = address.identifier
                row.addressFingerprint = fingerprint
            case .skipped:
                // Only addresses that changed are looked up, so a row here is for the old text.
                location?.SK_remove(context)
                failure?.SK_remove(context)
            }
        }
    }
}
