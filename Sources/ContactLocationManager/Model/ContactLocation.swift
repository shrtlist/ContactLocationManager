//
//  ContactLocation.swift
//  Sidewalk
//
//  Created by Marco Abundo on 12/12/2021.
//  Copyright 2017 shrtlist.com. All rights reserved.
//

import CoreData
import CoreLocation

// Named explicitly: Core Data can't resolve a module-relative class name from a package's resource bundle.
@objc(ContactLocation)
final class ContactLocation: NSManagedObject {
    @NSManaged var contactId: String
    @NSManaged var latitude: CLLocationDegrees
    @NSManaged var longitude: CLLocationDegrees
    @NSManaged var postalAddressId: String
}
