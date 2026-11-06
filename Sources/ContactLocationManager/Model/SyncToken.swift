//
//  SyncToken.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 11/5/26.
//

import CoreData

/// The contact store's change history token, kept beside the locations it covers.
@objc(SyncToken)
final class SyncToken: NSManagedObject {
    @NSManaged var data: Data
}
