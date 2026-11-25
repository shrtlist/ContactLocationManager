import Contacts
import Testing
import CoreLocation
import Synchronization
@testable import ContactLocationManager

/// The suites that read or write the shared on-disk store. They run one after another, because
/// some of them wipe or count what the others are using. A suite that touches the store goes in here.
@Suite(.serialized) enum SharedStoreTests {}

extension ContactActor {
    /// Postal address identifiers stored for the contact.
    /// `failed` are the no-match addresses, `pending` the ones waiting for `retryPending()`.
    func storedAddressIds(forContactId contactId: String) async -> (located: Set<String>, failed: Set<String>, pending: Set<String>) {
        await SkopelosClient.shared.read { context in
            let located = ContactLocation.SK_all("contactId", isEqualTo: contactId, sortTerms: "contactId", ascending: false, context: context)
            let rows = FailedAddress.SK_all("contactId", isEqualTo: contactId, sortTerms: "contactId", ascending: false, context: context)
            return (Set(located.map(\.postalAddressId)),
                    Set(rows.filter { !$0.needsRetry }.map(\.postalAddressId)),
                    Set(rows.filter(\.needsRetry).map(\.postalAddressId)))
        }
    }

    /// Latitude stored for each postal address of the contact.
    func storedLatitudes(forContactId contactId: String) async -> [String: Double] {
        await SkopelosClient.shared.read { context in
            let rows = ContactLocation.SK_all("contactId", isEqualTo: contactId, sortTerms: "contactId", ascending: false, context: context)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.postalAddressId, $0.latitude) })
        }
    }
}

/// Answers from a script and counts the lookups, so a test can change the answer between lookups
/// and tell whether an address was asked about.
final class ScriptedGeocoder: Geocoder {
    enum Answer { case latitude(Double), noMatch, failure(GeocodingError) }
    private let state: Mutex<(answer: Answer, calls: Int)>

    init(_ answer: Answer) { state = Mutex((answer, 0)) }

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

/// Finds nothing. For tests that never geocode.
struct NoopGeocoder: Geocoder {
    func coordinate(for postalAddress: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? { nil }
}

/// A contact with one home address per street.
func makeContact(streets: [String]) -> CNContact {
    let contact = CNMutableContact()
    contact.givenName = "Ada"
    contact.postalAddresses = streets.map { street in
        let address = CNMutablePostalAddress()
        address.street = street
        return CNLabeledValue(label: CNLabelHome, value: address as CNPostalAddress)
    }
    return contact
}

/// The same contact and address identifiers, with new street text for the addresses at the given
/// positions, as after the user edits them.
func edited(_ contact: CNContact, streets: [Int: String]) -> CNContact {
    let copy = contact.mutableCopy() as! CNMutableContact
    copy.postalAddresses = contact.postalAddresses.enumerated().map { index, labeled in
        guard let street = streets[index] else { return labeled }
        let address = labeled.value.mutableCopy() as! CNMutablePostalAddress
        address.street = street
        return labeled.settingValue(address as CNPostalAddress)
    }
    return copy
}

/// Keeps the count in memory, so a test doesn't touch the shared store.
final class InMemoryRequestCountStore: RequestCountStore {
    private let stored = Mutex(RequestCount())
    func load() async -> RequestCount { stored.withLock { $0 } }
    func save(_ requestCount: RequestCount) { stored.withLock { $0 = requestCount } }
}
