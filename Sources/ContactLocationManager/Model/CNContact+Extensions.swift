//
//  CNContact+Extensions.swift
//  ContactLocationManager
//

@preconcurrency import Contacts

extension CNContact {
    /// The contact's name as the system formats it, including prefix and middle name, or their organization
    /// if they have no person name. `nil` if they have neither. Needs `CNContactFormatter`'s full-name
    /// keys, which the package always loads.
    var formattedName: String? {
        guard let name = CNContactFormatter.string(from: self, style: .fullName), !name.isEmpty else { return nil }
        return name
    }
}
