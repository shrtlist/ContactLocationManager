//
//  FailedAddress.swift
//  ContactLocationManager
//

import CoreData

/// A postal address with no location yet. Two kinds:
/// - `needsRetry == false`: a provider answered "no match", so the user can correct the address. Counts as answered.
/// - `needsRetry == true`: the address couldn't be asked (a provider error or the host's request limit), so it is
///   looked up again later. Never shown to the user, and doesn't count as answered.
///
/// Named explicitly: Core Data can't resolve a module-relative class name from a package's resource bundle.
@objc(FailedAddress)
final class FailedAddress: NSManagedObject {
    @NSManaged var contactId: String
    @NSManaged var postalAddressId: String
    @NSManaged var addressFingerprint: String
    @NSManaged var needsRetry: Bool
}
