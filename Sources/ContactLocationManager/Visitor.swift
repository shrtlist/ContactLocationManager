//
//  Visitor.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 10/8/26.
//

// Source - https://stackoverflow.com/a/75860924
// Posted by AnderCover, modified by community. See post 'Timeline' for change history
// Retrieved 2026-10-08, License - CC BY-SA 4.0

@preconcurrency import Contacts

/// Collects change history events synchronously. Not `Sendable`; create it, fill it and read it within a single call.
final class Visitor: NSObject, CNChangeHistoryEventVisitor {
    private(set) var changes: [ContactHistoryChange] = []

    func visit(_ event: CNChangeHistoryDropEverythingEvent) {
        changes.append(.removeAll)
    }
    
    func visit(_ event: CNChangeHistoryAddContactEvent) {
        changes.append(.insert(event.contact))
    }
    
    func visit(_ event: CNChangeHistoryUpdateContactEvent) {
        changes.append(.update(event.contact))
    }
    
    func visit(_ event: CNChangeHistoryDeleteContactEvent) {
        changes.append(.delete(contactIdentifier: event.contactIdentifier))
    }
}
