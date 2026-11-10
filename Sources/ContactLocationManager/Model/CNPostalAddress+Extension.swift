//
//  CNPostalAddress+Extension.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 10/12/26.
//

import Contacts
import CryptoKit

extension CNPostalAddress {
    var addressString: String {
        CNPostalAddressFormatter.string(from: self, style: .mailingAddress)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Identifies the text sent to the geocoders: it changes exactly when a lookup would. A hash, so the
    /// address isn't stored a second time.
    var fingerprint: String {
        SHA256.hash(data: Data(addressString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Address text for display only. Omits the country line; the stored address is unchanged.
    var displayAddressString: String {
        let mutableAddress = mutableCopy() as? CNMutablePostalAddress
        mutableAddress?.country = ""
        return CNPostalAddressFormatter.string(from: mutableAddress ?? self, style: .mailingAddress)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
