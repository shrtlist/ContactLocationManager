import Testing
import Contacts
import CoreLocation
import Synchronization
@testable import ContactLocationManager

/// Answers from a script and counts the lookups, so a test can tell whether an address was asked about.
private final class CountingGeocoder: Geocoder, @unchecked Sendable {
    enum Answer { case latitude(Double), noMatch, failure(GeocodingError) }
    private let state = Mutex<(answer: Answer, calls: Int)>((.latitude(1), 0))

    init(_ answer: Answer) { state.withLock { $0.answer = answer } }

    var calls: Int { state.withLock { $0.calls } }
    var answer: Answer {
        get { state.withLock { $0.answer } }
        set { state.withLock { $0.answer = newValue } }
    }

    func coordinate(for postalAddress: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        let answer = state.withLock { state -> Answer in state.calls += 1; return state.answer }
        switch answer {
        case .latitude(let value): return CLLocationCoordinate2D(latitude: value, longitude: value)
        case .noMatch: return nil
        case .failure(let error): throw error
        }
    }
}

/// Uses the shared store, so each test works on its own contact and removes it afterwards.
@Suite(.serialized) struct ContactActorFingerprintTests {
    private func contact(streets: [String]) -> CNContact {
        let contact = CNMutableContact()
        contact.givenName = "Ada"
        contact.postalAddresses = streets.map { street in
            let address = CNMutablePostalAddress()
            address.street = street
            return CNLabeledValue(label: CNLabelHome, value: address as CNPostalAddress)
        }
        return contact
    }

    /// Same contact and address identifiers, with new street text for the addresses at the given positions.
    private func edited(_ contact: CNContact, streets: [Int: String]) -> CNContact {
        let copy = contact.mutableCopy() as! CNMutableContact
        copy.postalAddresses = contact.postalAddresses.enumerated().map { index, labeled in
            guard let street = streets[index] else { return labeled }
            let address = labeled.value.mutableCopy() as! CNMutablePostalAddress
            address.street = street
            return labeled.settingValue(address as CNPostalAddress)
        }
        return copy
    }

    private func actor(_ geocoder: any Geocoder) -> ContactActor {
        ContactActor(geocoder: geocoder, contactKeys: ContactKeys([]))
    }

    // MARK: - Unchanged addresses

    @Test func anUnchangedAddressIsNotLookedUpAgain() async throws {
        let geocoder = CountingGeocoder(.latitude(7))
        let actor = actor(geocoder)
        let contact = contact(streets: ["1 Main St"])
        try await actor.apply(.insert(contact))

        try await actor.apply(.update(contact))

        #expect(geocoder.calls == 1)
        #expect(await actor.storedLatitudes(forContactId: contact.identifier).values.first == 7)
        await actor.delete(contactIdentifier: contact.identifier)
    }

    @Test func anUnchangedNoMatchIsNotAskedAgain() async throws {
        let geocoder = CountingGeocoder(.noMatch)
        let actor = actor(geocoder)
        let contact = contact(streets: ["Bad St"])
        try await actor.apply(.insert(contact))

        try await actor.apply(.update(contact))

        #expect(geocoder.calls == 1)
        #expect(await actor.storedAddressIds(forContactId: contact.identifier).failed.count == 1)
        await actor.delete(contactIdentifier: contact.identifier)
    }

    /// An outage or the request limit while the user edits something else must not cost the contact its pin.
    @Test(arguments: [GeocodingError.requestLimitReached, .unavailable, .unauthorized, .invalidRequest, .offline, .rateLimited])
    func aFailureWhileAnUnrelatedFieldChangesKeepsThePin(error: GeocodingError) async throws {
        let geocoder = CountingGeocoder(.latitude(7))
        let actor = actor(geocoder)
        let contact = contact(streets: ["1 Main St"])
        try await actor.apply(.insert(contact))

        geocoder.answer = .failure(error)
        try await actor.apply(.update(contact))

        #expect(geocoder.calls == 1)
        #expect(await actor.storedLatitudes(forContactId: contact.identifier).values.first == 7)
        await actor.delete(contactIdentifier: contact.identifier)
    }

    @Test func onlyTheChangedAddressIsLookedUp() async throws {
        let geocoder = CountingGeocoder(.latitude(1))
        let actor = actor(geocoder)
        let contact = contact(streets: ["1 Main St", "2 Main St"])
        try await actor.apply(.insert(contact))
        geocoder.answer = .latitude(9)

        try await actor.apply(.update(edited(contact, streets: [1: "3 Main St"])))

        let ids = contact.postalAddresses.map(\.identifier)
        let latitudes = await actor.storedLatitudes(forContactId: contact.identifier)
        #expect(geocoder.calls == 3)
        #expect(latitudes[ids[0]] == 1)
        #expect(latitudes[ids[1]] == 9)
        await actor.delete(contactIdentifier: contact.identifier)
    }

    // MARK: - Changed addresses

    @Test func aChangedAddressGetsTheNewCoordinate() async throws {
        let geocoder = CountingGeocoder(.latitude(1))
        let actor = actor(geocoder)
        let contact = contact(streets: ["1 Main St"])
        try await actor.apply(.insert(contact))
        geocoder.answer = .latitude(5)

        try await actor.apply(.update(edited(contact, streets: [0: "2 Main St"])))

        #expect(await actor.storedLatitudes(forContactId: contact.identifier).values.first == 5)
        await actor.delete(contactIdentifier: contact.identifier)
    }

    /// The old pin is for the old address, so it must not stay on the map.
    @Test(arguments: [GeocodingError.requestLimitReached, .unavailable, .rateLimited])
    func aChangedAddressThatCouldNotBeAskedLosesItsOldPin(error: GeocodingError) async throws {
        let geocoder = CountingGeocoder(.latitude(1))
        let actor = actor(geocoder)
        let contact = contact(streets: ["1 Main St"])
        try await actor.apply(.insert(contact))
        geocoder.answer = .failure(error)

        // `.rateLimited` pauses the sync, which leaves the store as it was; the others reach the store.
        try? await actor.apply(.update(edited(contact, streets: [0: "2 Main St"])))

        let stored = await actor.storedAddressIds(forContactId: contact.identifier)
        if error == .rateLimited {
            #expect(stored.located.count == 1)
        } else {
            #expect(stored.located.isEmpty)
            #expect(stored.failed.isEmpty)
        }
        await actor.delete(contactIdentifier: contact.identifier)
    }

    @Test func aChangedAddressWithNoMatchMovesFromTheMapToTheFailureList() async throws {
        let geocoder = CountingGeocoder(.latitude(1))
        let actor = actor(geocoder)
        let contact = contact(streets: ["1 Main St"])
        try await actor.apply(.insert(contact))
        geocoder.answer = .noMatch

        try await actor.apply(.update(edited(contact, streets: [0: "Nowhere"])))

        let stored = await actor.storedAddressIds(forContactId: contact.identifier)
        #expect(stored.located.isEmpty)
        #expect(stored.failed.count == 1)
        await actor.delete(contactIdentifier: contact.identifier)
    }

    @Test func aRemovedAddressLosesItsRows() async throws {
        let geocoder = CountingGeocoder(.latitude(1))
        let actor = actor(geocoder)
        let contact = contact(streets: ["1 Main St", "2 Main St"])
        try await actor.apply(.insert(contact))
        let remaining = contact.mutableCopy() as! CNMutableContact
        remaining.postalAddresses = [contact.postalAddresses[0]]

        try await actor.apply(.update(remaining))

        let stored = await actor.storedAddressIds(forContactId: contact.identifier)
        #expect(stored.located == [contact.postalAddresses[0].identifier])
        await actor.delete(contactIdentifier: contact.identifier)
    }
}

@Suite struct AddressFingerprintTests {
    private func address(street: String, city: String = "") -> CNPostalAddress {
        let address = CNMutablePostalAddress()
        address.street = street
        address.city = city
        return address
    }

    @Test func sameTextSameFingerprint() {
        #expect(address(street: "1 Main St").fingerprint == address(street: "1 Main St").fingerprint)
    }

    @Test func differentTextDifferentFingerprint() {
        #expect(address(street: "1 Main St").fingerprint != address(street: "2 Main St").fingerprint)
        #expect(address(street: "1 Main St").fingerprint != address(street: "1 Main St", city: "Springfield").fingerprint)
    }

    @Test func doesNotContainTheAddress() {
        #expect(!address(street: "1 Main St").fingerprint.contains("Main"))
    }
}
