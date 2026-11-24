import Testing
import Contacts
import CoreLocation
@testable import ContactLocationManager

/// The geocoder says "no match" for streets that start with "Bad", and finds everything else.
private struct PickyGeocoder: Geocoder {
    func coordinate(for postalAddress: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        postalAddress.street.hasPrefix("Bad") ? nil : CLLocationCoordinate2D(latitude: 1, longitude: 2)
    }
}

/// Uses the shared store, so each test works on its own contact and removes it afterwards.
@Suite(.serialized) struct ContactActorFailedAddressTests {
    private func contact(streets: [String]) -> (CNContact, [String]) {
        let contact = makeContact(streets: streets)
        return (contact, contact.postalAddresses.map(\.identifier))
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
        let actor = actor(ScriptedGeocoder(.latitude(1)))
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

        geocoder.answer = .latitude(1)
        try await actor.apply(.update(edited(contact, streets: [0: "1 Main St"])))

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
        await #expect(throws: error) { try await actor.apply(.update(edited(contact, streets: [0: "Bad Rd"]))) }

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
