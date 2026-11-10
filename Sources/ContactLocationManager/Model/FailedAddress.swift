//
//  FailedAddress.swift
//  ContactLocationManager
//

import CoreData

/// A postal address that a provider answered with "no match", so the user can correct it.
///
/// Named explicitly: Core Data can't resolve a module-relative class name from a package's resource bundle.
@objc(FailedAddress)
final class FailedAddress: NSManagedObject {
    @NSManaged var contactId: String
    @NSManaged var postalAddressId: String
    @NSManaged var addressFingerprint: String
}
