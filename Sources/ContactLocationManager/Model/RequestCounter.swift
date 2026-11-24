//
//  RequestCounter.swift
//  ContactLocationManager
//

import CoreData

/// How many addresses have been geocoded, kept beside the locations it paid for. One row.
@objc(RequestCounter)
final class RequestCounter: NSManagedObject {
    @NSManaged var count: Int64
    @NSManaged var refused: Bool
}
