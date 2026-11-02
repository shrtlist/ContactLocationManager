//
//  ContactLocation.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 12/12/2021.
//

import CoreData
import CoreLocation

/// A geocoded postal address of a contact.
///
/// Named explicitly: Core Data can't resolve a module-relative class name from a package's resource bundle.
@objc(ContactLocation)
final class ContactLocation: NSManagedObject {
    @NSManaged var contactId: String
    @NSManaged var latitude: CLLocationDegrees
    @NSManaged var longitude: CLLocationDegrees
    @NSManaged var postalAddressId: String
}
