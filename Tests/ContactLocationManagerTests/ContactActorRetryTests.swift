import Testing
import Contacts
import CoreLocation
@testable import ContactLocationManager

/// The contacts the actor's retry pass can find, standing in for the contact store.
private final class ContactBook: @unchecked Sendable {
    private let lock = NSLock()
    private var contacts: [String: CNContact] = [:]

    func set(_ contact: CNContact?, id: String) {
        lock.lock(); defer { lock.unlock() }
        contacts[id] = contact
    }

    func find(_ ids: Set<String>) -> [String: CNContact] {
        lock.lock(); defer { lock.unlock() }
        return contacts.filter { ids.contains($0.key) }
    }
}

extension SharedStoreTests {
    /// Uses the shared store, so each test works on its own contact and removes it afterwards.
    @Suite struct ContactActorRetryTests {
        private let book = ContactBook()

        private func actor(_ geocoder: any Geocoder) -> ContactActor {
            let book = book
            return ContactActor(geocoder: geocoder, contactKeys: ContactKeys([]), loadContacts: { ids, _ in book.find(ids) })
        }

        /// A contact whose first lookup failed with `error`, so it is waiting for a retry.
        private func pendingContact(_ geocoder: ScriptedGeocoder, _ actor: ContactActor, failingWith error: GeocodingError) async throws -> CNContact {
            let contact = makeContact(streets: ["1 Main St"])
            book.set(contact, id: contact.identifier)
            geocoder.answer = .failure(error)
            try await actor.apply(.insert(contact))
            return contact
        }

        @Test(arguments: [GeocodingError.unavailable, .unauthorized, .requestLimitReached, .rateLimited])
        func aRetryStoresTheLocationOnceTheAddressCanBeAsked(error: GeocodingError) async throws {
            let geocoder = ScriptedGeocoder(.latitude(3))
            let actor = actor(geocoder)
            let contact = try await pendingContact(geocoder, actor, failingWith: error)

            geocoder.answer = .latitude(3)
            let answered = try await actor.retryPending()

            let stored = await actor.storedAddressIds(forContactId: contact.identifier)
            #expect(answered)
            #expect(stored.located == Set(contact.postalAddresses.map(\.identifier)))
            #expect(stored.pending.isEmpty)
            await actor.delete(contactIdentifier: contact.identifier)
        }

        @Test func pendingAddressesAreCounted() async throws {
            let geocoder = ScriptedGeocoder(.latitude(3))
            let actor = actor(geocoder)
            let before = await actor.pendingCount()
            let contact = makeContact(streets: ["1 Main St", "2 Main St"])
            book.set(contact, id: contact.identifier)
            geocoder.answer = .failure(.unavailable)
            try await actor.apply(.insert(contact))
            #expect(await actor.pendingCount() == before + 2)

            geocoder.answer = .latitude(3)
            _ = try await actor.retryPending()

            #expect(await actor.pendingCount() == before)
            await actor.delete(contactIdentifier: contact.identifier)
        }

        @Test func anAddressThatStillCannotBeAskedStaysPending() async throws {
            let geocoder = ScriptedGeocoder(.latitude(1))
            let actor = actor(geocoder)
            let contact = try await pendingContact(geocoder, actor, failingWith: .unavailable)

            let answered = try await actor.retryPending()

            let stored = await actor.storedAddressIds(forContactId: contact.identifier)
            #expect(!answered)
            #expect(stored.pending.count == 1)
            await actor.delete(contactIdentifier: contact.identifier)
        }

        @Test func aRetryThatFindsNoMatchMovesTheAddressToTheUsersList() async throws {
            let geocoder = ScriptedGeocoder(.latitude(1))
            let actor = actor(geocoder)
            let contact = try await pendingContact(geocoder, actor, failingWith: .unavailable)

            geocoder.answer = .noMatch
            let answered = try await actor.retryPending()

            let stored = await actor.storedAddressIds(forContactId: contact.identifier)
            #expect(answered)
            #expect(stored.failed.count == 1)
            #expect(stored.pending.isEmpty)
            await actor.delete(contactIdentifier: contact.identifier)
        }

        /// A pending address isn't answered, so an unrelated edit of its contact asks again too.
        @Test func aPendingAddressIsLookedUpAgainWhenItsContactIsUpdated() async throws {
            let geocoder = ScriptedGeocoder(.latitude(1))
            let actor = actor(geocoder)
            let contact = try await pendingContact(geocoder, actor, failingWith: .unavailable)

            geocoder.answer = .latitude(6)
            try await actor.apply(.update(contact))

            let stored = await actor.storedAddressIds(forContactId: contact.identifier)
            #expect(stored.located.count == 1)
            #expect(stored.pending.isEmpty)
            await actor.delete(contactIdentifier: contact.identifier)
        }

        /// The history pass sees the new text, so the retry leaves it alone rather than asking about stale text.
        @Test func aRetryLeavesAnAddressWhoseTextChanged() async throws {
            let geocoder = ScriptedGeocoder(.latitude(1))
            let actor = actor(geocoder)
            let contact = try await pendingContact(geocoder, actor, failingWith: .unavailable)
            book.set(edited(contact, streets: [0: "2 Main St"]), id: contact.identifier)
            let callsBefore = geocoder.calls

            geocoder.answer = .latitude(8)
            let answered = try await actor.retryPending()

            #expect(!answered)
            #expect(geocoder.calls == callsBefore)
            #expect(await actor.storedAddressIds(forContactId: contact.identifier).pending.count == 1)
            await actor.delete(contactIdentifier: contact.identifier)
        }

        @Test func aRetryDropsTheRowsOfAContactThatNoLongerExists() async throws {
            let geocoder = ScriptedGeocoder(.latitude(1))
            let actor = actor(geocoder)
            let contact = try await pendingContact(geocoder, actor, failingWith: .unavailable)
            book.set(nil, id: contact.identifier)

            _ = try await actor.retryPending()

            #expect(await actor.storedAddressIds(forContactId: contact.identifier).pending.isEmpty)
            await actor.delete(contactIdentifier: contact.identifier)
        }

        @Test(arguments: [GeocodingError.offline, .cancelled])
        func aRetryPausesWithoutLosingTheRow(error: GeocodingError) async throws {
            let geocoder = ScriptedGeocoder(.latitude(1))
            let actor = actor(geocoder)
            let contact = try await pendingContact(geocoder, actor, failingWith: .unavailable)

            geocoder.answer = .failure(error)
            await #expect(throws: error) { _ = try await actor.retryPending() }

            #expect(await actor.storedAddressIds(forContactId: contact.identifier).pending.count == 1)
            await actor.delete(contactIdentifier: contact.identifier)
        }

        @Test func deletingTheContactClearsItsPendingRows() async throws {
            let geocoder = ScriptedGeocoder(.latitude(1))
            let actor = actor(geocoder)
            let contact = try await pendingContact(geocoder, actor, failingWith: .unavailable)

            try await actor.apply(.delete(contactIdentifier: contact.identifier))

            #expect(await actor.storedAddressIds(forContactId: contact.identifier).pending.isEmpty)
        }
    }
}
