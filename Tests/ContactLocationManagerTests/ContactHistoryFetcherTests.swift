import Testing
import Contacts
import CoreLocation
@testable import ContactLocationManager

/// Never called: these tests seed annotations directly instead of syncing the contact store.
private struct NoopGeocoder: Geocoder {
    func coordinate(for address: CNPostalAddress) async throws -> CLLocationCoordinate2D? { nil }
}

@MainActor
@Suite struct ContactHistoryFetcherFetchByTests {
    private let ada: CNContact
    private let bob: CNContact
    private let adaHome: ContactLocationAnnotation
    private let adaWork: ContactLocationAnnotation
    private let bobHome: ContactLocationAnnotation
    private let fetcher: ContactHistoryFetcher

    init() {
        ada = Self.contact(named: "Ada", addressLabels: [CNLabelHome, CNLabelWork])
        bob = Self.contact(named: "Bob", addressLabels: [CNLabelHome])
        adaHome = ContactLocationAnnotation(contact: ada, labeledAddress: ada.postalAddresses[0], latitude: 1, longitude: 1)
        adaWork = ContactLocationAnnotation(contact: ada, labeledAddress: ada.postalAddresses[1], latitude: 2, longitude: 2)
        bobHome = ContactLocationAnnotation(contact: bob, labeledAddress: bob.postalAddresses[0], latitude: 3, longitude: 3)
        fetcher = ContactHistoryFetcher(geocoder: NoopGeocoder())
        fetcher.contactLocationAnnotations = [adaHome, adaWork, bobHome]
    }

    @Test func returnsTheAnnotationForThatContactAndAddress() {
        #expect(fetcher.fetchBy(ada.postalAddresses[0], contact: ada) === adaHome)
        #expect(fetcher.fetchBy(ada.postalAddresses[1], contact: ada) === adaWork)
        #expect(fetcher.fetchBy(bob.postalAddresses[0], contact: bob) === bobHome)
    }

    /// Hosts usually pass a contact they fetched themselves, not the very instance in the annotation.
    @Test func matchesAnEqualContactThatIsNotTheSameInstance() {
        let copy = ada.copy() as! CNContact
        #expect(copy !== ada)
        #expect(fetcher.fetchBy(copy.postalAddresses[1], contact: copy) === adaWork)
    }

    @Test func returnsNilWhenTheAddressBelongsToAnotherContact() {
        #expect(fetcher.fetchBy(ada.postalAddresses[0], contact: bob) == nil)
    }

    @Test func returnsNilForAnAddressThatWasNeverGeocoded() {
        let unknown = Self.contact(named: "Ada", addressLabels: [CNLabelOther])
        #expect(fetcher.fetchBy(unknown.postalAddresses[0], contact: ada) == nil)
    }

    @Test func returnsNilWhenNothingIsLoaded() {
        fetcher.contactLocationAnnotations = []
        #expect(fetcher.fetchBy(ada.postalAddresses[0], contact: ada) == nil)
    }

    // MARK: - Helpers

    private static func contact(named name: String, addressLabels: [String]) -> CNContact {
        let contact = CNMutableContact()
        contact.givenName = name
        contact.postalAddresses = addressLabels.map { label in
            let address = CNMutablePostalAddress()
            address.street = "1 \(label) St"
            return CNLabeledValue(label: label, value: address as CNPostalAddress)
        }
        return contact
    }
}
