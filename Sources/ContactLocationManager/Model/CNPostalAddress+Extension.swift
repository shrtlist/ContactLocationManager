//
//  CNPostalAddress+Extension.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 10/12/26.
//

import Contacts

extension CNPostalAddress {
    var addressString: String {
        CNPostalAddressFormatter.string(from: self, style: .mailingAddress)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Address text for display only. Omits the country line; the stored address is unchanged.
    var displayAddressString: String {
        let mutableAddress = mutableCopy() as? CNMutablePostalAddress
        mutableAddress?.country = ""
        return CNPostalAddressFormatter.string(from: mutableAddress ?? self, style: .mailingAddress)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
