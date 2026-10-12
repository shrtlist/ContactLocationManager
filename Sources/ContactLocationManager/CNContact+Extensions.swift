//
//  CNContact+Extensions.swift
//  ContactLocationManager
//

@preconcurrency import Contacts

extension CNContact {
    /// The person's name, or their organization if they have no person name. `nil` if they have
    /// neither. Needs the name keys (`givenName`, `familyName`, `organizationName`) to be loaded.
    var name: String? {
        if !givenName.isEmpty || !familyName.isEmpty {
            let components = PersonNameComponents(givenName: givenName, familyName: familyName)
            return PersonNameComponentsFormatter().string(from: components)
        }
        return organizationName.isEmpty ? nil : organizationName
    }
}
