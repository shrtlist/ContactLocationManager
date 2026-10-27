//
//  CNPostalAddress+Extension.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 10/12/26.
//

import Contacts

extension CNPostalAddress {
    var mailingString: String {
        CNPostalAddressFormatter.string(from: self, style: .mailingAddress)
    }
}
