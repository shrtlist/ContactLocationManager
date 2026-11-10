import Testing
import Contacts
import CoreLocation
@testable import ContactLocationManager

private struct NoopGeocoder: Geocoder {
    func coordinate(for postalAddress: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? { nil }
}

/// Uses the shared store, so each test works on its own contact and removes it afterwards.
@MainActor
@Suite(.serialized) struct ContactHistoryFetcherSyncTests {
    private let contactId = UUID().uuidString
    private let postalAddressId = UUID().uuidString
    private let actor = ContactActor(geocoder: NoopGeocoder(), contactKeys: ContactKeys([]))

    /// Off the main actor: Skopelos's `writeSync` blocks its caller, and the other suites write from background threads.
    @concurrent
    private func seedLocation() async {
        SkopelosClient.shared.writeSync { [contactId, postalAddressId] context in
            let location = ContactLocation.SK_create(context)
            location.contactId = contactId
            location.postalAddressId = postalAddressId
            location.latitude = 1
            location.longitude = 2
            location.addressFingerprint = "fingerprint"
        }
    }

    private func storedLocations() async -> Set<String> {
        await actor.storedAddressIds(forContactId: contactId).located
    }

    /// Until the host calls `start()`, nothing may touch the store, whether or not access was granted.
    @Test func resetDoesNotWipeTheStoreBeforeStart() async {
        await seedLocation()
        let fetcher = ContactHistoryFetcher(geocoder: NoopGeocoder())

        await fetcher.reset()

        #expect(await storedLocations() == [postalAddressId])
        await actor.delete(contactIdentifier: contactId)
    }

    @Test func raisingTheLimitDoesNotWipeTheStoreBeforeStart() async {
        await seedLocation()
        // The limiter asks for a resync only if addresses were refused under the old limit.
        UserDefaults.standard.set(true, forKey: "CNGeocodeRequestsRefused")
        defer { UserDefaults.standard.removeObject(forKey: "CNGeocodeRequestsRefused") }
        let fetcher = ContactHistoryFetcher(geocoder: NoopGeocoder(), maxRequests: 0)

        await fetcher.setMaxRequests(nil)

        #expect(await storedLocations() == [postalAddressId])
        await actor.delete(contactIdentifier: contactId)
    }
}
