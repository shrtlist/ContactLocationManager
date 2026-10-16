//
//  ExampleModel.swift
//  ContactLocationManagerExample
//
//  Created by Marco Abundo on 10/15/26.
//

import Foundation
import Contacts
import Observation
import ContactLocationManager

/// Owns the fetcher and the settings it's created with. Settings are saved between launches.
@MainActor
@Observable
final class ExampleModel {
    /// Replaced when a provider is switched on or off, since providers are fixed at creation.
    private(set) var fetcher: ContactHistoryFetcher

    /// Read from Keys.plist; nil if it's missing or has no such key.
    let mapsiAPIKey: String?
    let googleAPIKey: String?

    var usesMapsi: Bool {
        didSet { save(usesMapsi, for: "usesMapsi"); makeFetcher() }
    }
    var usesGoogle: Bool {
        didSet { save(usesGoogle, for: "usesGoogle"); makeFetcher() }
    }
    var limitsRequests: Bool {
        didSet { save(limitsRequests, for: "limitsRequests"); applyRequestLimit() }
    }
    var maxRequests: Int {
        didSet { save(maxRequests, for: "maxRequests"); applyRequestLimit() }
    }

    /// Counts for the whole Contacts database, or nil until they've been read.
    private(set) var contactCount: Int?
    private(set) var addressCount: Int?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["usesMapsi": true, "usesGoogle": true, "maxRequests": 20])
        let usesMapsi = defaults.bool(forKey: "usesMapsi")
        let usesGoogle = defaults.bool(forKey: "usesGoogle")
        let limitsRequests = defaults.bool(forKey: "limitsRequests")
        let maxRequests = defaults.integer(forKey: "maxRequests")
        let mapsiAPIKey = Self.key("MapsiAPIKey")
        let googleAPIKey = Self.key("GoogleMapsAPIKey")
        fetcher = ContactHistoryFetcher(mapsiAPIKey: usesMapsi ? mapsiAPIKey : nil,
                                        googleAPIKey: usesGoogle ? googleAPIKey : nil,
                                        maxRequests: limitsRequests ? maxRequests : nil)
        self.usesMapsi = usesMapsi
        self.usesGoogle = usesGoogle
        self.limitsRequests = limitsRequests
        self.maxRequests = maxRequests
        self.mapsiAPIKey = mapsiAPIKey
        self.googleAPIKey = googleAPIKey
    }

    var requestLimit: Int? { limitsRequests ? maxRequests : nil }

    func refreshCounts() async {
        guard let counts = await Self.countContactsAndAddresses() else { return }
        contactCount = counts.contacts
        addressCount = counts.addresses
    }

    /// The old fetcher should be idle; the view only allows switching providers between syncs.
    private func makeFetcher() {
        fetcher = ContactHistoryFetcher(mapsiAPIKey: usesMapsi ? mapsiAPIKey : nil,
                                        googleAPIKey: usesGoogle ? googleAPIKey : nil,
                                        maxRequests: requestLimit)
    }

    private func applyRequestLimit() {
        let fetcher = fetcher, limit = requestLimit
        Task { await fetcher.setMaxRequests(limit) }
    }

    private func save(_ value: Any, for key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    @concurrent
    private static func countContactsAndAddresses() async -> (contacts: Int, addresses: Int)? {
        let request = CNContactFetchRequest(keysToFetch: [CNContactPostalAddressesKey as CNKeyDescriptor])
        var contacts = 0, addresses = 0
        do {
            try CNContactStore().enumerateContacts(with: request) { contact, _ in
                contacts += 1
                addresses += contact.postalAddresses.count
            }
        } catch {
            return nil
        }
        return (contacts, addresses)
    }

    private static func key(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: "Keys", withExtension: "plist"),
              let plist = NSDictionary(contentsOf: url),
              let value = plist[name] as? String, !value.isEmpty else { return nil }
        return value
    }
}
