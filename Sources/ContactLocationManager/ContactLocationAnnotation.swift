//
//  ContactLocationAnnotation.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 10/8/26.
//

@preconcurrency import Contacts
import MapKit

/// A geocoded postal address of a contact, ready to put on a map.
///
/// `@unchecked Sendable`: the compiler can't verify an `NSObject` subclass, but every stored
/// property is an immutable `let`, so an instance is safe to hand across actors. Keep it that way.
public final class ContactLocationAnnotation: NSObject, MKAnnotation, @unchecked Sendable {
    public let contact: CNContact
    public let labeledAddress: CNLabeledValue<CNPostalAddress>

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The contact's name, or their organization if they have no person name. `nil` if they have
    /// neither. Needs the name keys (`givenName`, `familyName`, `organizationName`) to be loaded.
    public let title: String?

    /// The address, formatted as it would appear on a mailing label.
    public let subtitle: String?
    
    private let latitude: CLLocationDegrees
    private let longitude: CLLocationDegrees

    public init(contact: CNContact, labeledAddress: CNLabeledValue<CNPostalAddress>, latitude: CLLocationDegrees, longitude: CLLocationDegrees) {
        self.contact = contact
        self.labeledAddress = labeledAddress
        self.latitude = latitude
        self.longitude = longitude
        title = contact.name
        subtitle = CNPostalAddressFormatter.string(from: labeledAddress.value, style: .mailingAddress)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        super.init()
    }
}
