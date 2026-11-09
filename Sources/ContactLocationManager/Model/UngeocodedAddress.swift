//
//  UngeocodedAddress.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 11/8/26.
//

@preconcurrency import Contacts

/// A postal address that no geocoding provider could find. Show it to the user so they can correct the
/// address in the contact; saving the contact makes the fetcher look the address up again.
///
/// `contact` has the host's `contactKeys` loaded, plus what `CNContactViewController(for:)` needs.
///
/// `@unchecked Sendable`: every stored property is an immutable `let`. Keep it that way.
public final class UngeocodedAddress: NSObject, Identifiable, @unchecked Sendable {
    public let contact: CNContact
    public let labeledAddress: CNLabeledValue<CNPostalAddress>
    public let title: String?
    public let subtitle: String?

    public var id: String { contact.identifier + "/" + labeledAddress.identifier }

    public init(contact: CNContact, labeledAddress: CNLabeledValue<CNPostalAddress>) {
        self.contact = contact
        self.labeledAddress = labeledAddress
        title = contact.formattedName
        subtitle = labeledAddress.value.displayAddressString
        super.init()
    }
}
