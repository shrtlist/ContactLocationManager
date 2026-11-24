import Foundation
@testable import ContactLocationManager

extension ContactActor {
    /// Postal address identifiers stored for the contact.
    /// `failed` are the no-match addresses, `pending` the ones waiting for `retryPending()`.
    func storedAddressIds(forContactId contactId: String) async -> (located: Set<String>, failed: Set<String>, pending: Set<String>) {
        await SkopelosClient.shared.read { context in
            let located = ContactLocation.rows(forContactId: contactId, in: context)
            let rows = FailedAddress.rows(forContactId: contactId, in: context)
            return (Set(located.map(\.postalAddressId)),
                    Set(rows.filter { !$0.needsRetry }.map(\.postalAddressId)),
                    Set(rows.filter(\.needsRetry).map(\.postalAddressId)))
        }
    }

    /// Latitude stored for each postal address of the contact.
    func storedLatitudes(forContactId contactId: String) async -> [String: Double] {
        await SkopelosClient.shared.read { context in
            let rows = ContactLocation.rows(forContactId: contactId, in: context)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.postalAddressId, $0.latitude) })
        }
    }
}
