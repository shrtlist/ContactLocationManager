import Testing
import Contacts
import CoreLocation
@testable import ContactLocationManager

/// Answers from a script, so one test can look an address up twice with different results.
private final class ScriptedGeocoder: Geocoder, @unchecked Sendable {
    enum Answer { case coordinate, noMatch, failure(GeocodingError) }
    var answer: Answer
    init(_ answer: Answer) { self.answer = answer }

    func coordinate(for postalAddress: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        switch answer {
        case .coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2)
        case .noMatch: nil
        case .failure(let error): throw error
        }
    }
}

/// The geocoder says "no match" for streets that start with "Bad", and finds everything else.
private struct PickyGeocoder: Geocoder {
    func coordinate(for postalAddress: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        postalAddress.street.hasPrefix("Bad") ? nil : CLLocationCoordinate2D(latitude: 1, longitude: 2)
    }
}

/// Uses the shared store, so each test works on its own contact and removes it afterwards.
@Suite(.serialized) struct ContactActorFailedAddressTests {
    private func contact(streets: [String]) -> (CNContact, [String]) {
        let contact = CNMutableContact()
        contact.givenName = "Ada"
        contact.postalAddresses = streets.map { street in
            let address = CNMutablePostalAddress()
            address.street = street
            return CNLabeledValue(label: CNLabelHome, value: address as CNPostalAddress)
        }
        return (contact, contact.postalAddresses.map(\.identifier))
    }

    /// The same contact and address identifiers with other street text, as after the user edits the address.
    private func edited(_ contact: CNContact, street: String) -> CNContact {
        let copy = contact.mutableCopy() as! CNMutableContact
        copy.postalAddresses = contact.postalAddresses.map { labeled in
            let address = labeled.value.mutableCopy() as! CNMutablePostalAddress
            address.street = street
            return labeled.settingValue(address as CNPostalAddress)
        }
        return copy
    }

    private func actor(_ geocoder: any Geocoder) -> ContactActor {
        ContactActor(geocoder: geocoder, contactKeys: ContactKeys([]))
    }

    @Test func recordsAnAddressThatHasNoMatch() async throws {
        let actor = actor(ScriptedGeocoder(.noMatch))
        let (contact, ids) = self.contact(streets: ["Bad St"])

        try await actor.apply(.insert(contact))

        let stored = await actor.storedAddressIds(forContactId: contact.identifier)
        #expect(stored.failed == Set(ids))
        #expect(stored.located.isEmpty)

        await actor.delete(contactIdentifier: contact.identifier)
    }

    @Test func storesALocationAndNoFailureWhenTheAddressMatches() async throws {
        let actor = actor(ScriptedGeocoder(.coordinate))
        let (contact, ids) = self.contact(streets: ["1 Main St"])

        try await actor.apply(.insert(contact))

        let stored = await actor.storedAddressIds(forContactId: contact.identifier)
        #expect(stored.located == Set(ids))
        #expect(stored.failed.isEmpty)

        await actor.delete(contactIdentifier: contact.identifier)
    }

    /// Fixing the address in Contacts makes the next update geocode it, which clears the failure.
    @Test func aCorrectedAddressLeavesTheFailureList() async throws {
        let geocoder = ScriptedGeocoder(.noMatch)
        let actor = actor(geocoder)
        let (contact, ids) = self.contact(streets: ["Bad St"])
        try await actor.apply(.insert(contact))

        geocoder.answer = .coordinate
        try await actor.apply(.update(edited(contact, street: "1 Main St")))

        let stored = await actor.storedAddressIds(forContactId: contact.identifier)
        #expect(stored.failed.isEmpty)
        #expect(stored.located == Set(ids))

        await actor.delete(contactIdentifier: contact.identifier)
    }

    /// Not the user's to fix, so it isn't listed. It waits for `retryPending()` instead.
    @Test(arguments: [GeocodingError.requestLimitReached, .unavailable, .unauthorized])
    func anAddressThatCouldNotBeAskedWaitsForARetry(error: GeocodingError) async throws {
        let actor = actor(ScriptedGeocoder(.failure(error)))
        let (contact, ids) = self.contact(streets: ["1 Main St"])

        try await actor.apply(.insert(contact))

        let stored = await actor.storedAddressIds(forContactId: contact.identifier)
        #expect(stored.failed.isEmpty)
        #expect(stored.located.isEmpty)
        #expect(stored.pending == Set(ids))
        await actor.delete(contactIdentifier: contact.identifier)
    }

    /// Every provider rejects a malformed address, so it needs correcting, like a no match.
    @Test func aMalformedAddressIsListedForTheUserToCorrect() async throws {
        let actor = actor(ScriptedGeocoder(.failure(.invalidRequest)))
        let (contact, ids) = self.contact(streets: ["1 Main St"])

        try await actor.apply(.insert(contact))

        let stored = await actor.storedAddressIds(forContactId: contact.identifier)
        #expect(stored.failed == Set(ids))
        #expect(stored.pending.isEmpty)
        await actor.delete(contactIdentifier: contact.identifier)
    }

    @Test(arguments: [GeocodingError.offline, .rateLimited, .cancelled])
    func leavesTheStoreAloneWhenTheSyncPauses(error: GeocodingError) async throws {
        let geocoder = ScriptedGeocoder(.noMatch)
        let actor = actor(geocoder)
        let (contact, ids) = self.contact(streets: ["Bad St"])
        try await actor.apply(.insert(contact))

        geocoder.answer = .failure(error)
        // Edited, so the address is looked up again; an unchanged one wouldn't be asked.
        await #expect(throws: error) { try await actor.apply(.update(edited(contact, street: "Bad Rd"))) }

        let stored = await actor.storedAddressIds(forContactId: contact.identifier)
        #expect(stored.failed == Set(ids))

        await actor.delete(contactIdentifier: contact.identifier)
    }

    @Test func recordsOnlyTheAddressWithNoMatch() async throws {
        let actor = actor(PickyGeocoder())
        let (contact, ids) = self.contact(streets: ["1 Main St", "Bad St"])

        try await actor.apply(.insert(contact))

        let stored = await actor.storedAddressIds(forContactId: contact.identifier)
        #expect(stored.failed == [ids[1]])
        #expect(stored.located == [ids[0]])

        await actor.delete(contactIdentifier: contact.identifier)
    }

    @Test func deletingTheContactClearsItsFailures() async throws {
        let actor = actor(ScriptedGeocoder(.noMatch))
        let (contact, _) = self.contact(streets: ["Bad St"])
        try await actor.apply(.insert(contact))

        try await actor.apply(.delete(contactIdentifier: contact.identifier))

        let stored = await actor.storedAddressIds(forContactId: contact.identifier)
        #expect(stored.failed.isEmpty)
    }

    @Test func removingEverythingClearsFailures() async throws {
        let actor = actor(ScriptedGeocoder(.noMatch))
        let (contact, _) = self.contact(streets: ["Bad St"])
        try await actor.apply(.insert(contact))

        try await actor.apply(.removeAll)

        let stored = await actor.storedAddressIds(forContactId: contact.identifier)
        #expect(stored.failed.isEmpty)
    }
}
