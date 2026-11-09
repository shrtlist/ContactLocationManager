import Testing
import Contacts
import CoreLocation
@testable import ContactLocationManager

private struct FailingGeocoder: Geocoder {
    let error: GeocodingError
    func coordinate(for postalAddress: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? { throw error }
}

@Suite struct ContactActorCancellationTests {
    private static func contact() -> CNContact {
        let contact = CNMutableContact()
        contact.givenName = "Ada"
        let address = CNMutablePostalAddress()
        address.street = "1 Home St"
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address as CNPostalAddress)]
        return contact
    }

    private func actor(throwing error: GeocodingError) -> ContactActor {
        ContactActor(geocoder: FailingGeocoder(error: error), contactKeys: ContactKeys([]))
    }

    /// Storing "no match" for a cancelled lookup would lose the address once the token moves on.
    @Test func cancelledGeocodingPausesInsteadOfStoringNoMatch() async {
        await #expect(throws: GeocodingError.cancelled) {
            try await actor(throwing: .cancelled).apply(.insert(Self.contact()))
        }
    }

    /// A lone provider reports cancellation as `.unavailable`, so the task's own state decides.
    @Test func failureInACancelledTaskPausesInsteadOfStoringNoMatch() async {
        let actor = actor(throwing: .unavailable)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Result { () async throws(GeocodingError) in try await actor.apply(.update(Self.contact())) }
        }
        let result = await task.value
        #expect({ if case .failure(.cancelled) = result { true } else { false } }())
    }
}
