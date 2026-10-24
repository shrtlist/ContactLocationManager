//
//  ExampleModel.swift
//  ContactLocationManagerExample
//
//  Created by Marco Abundo on 10/15/26.
//

import Contacts
import Observation
import ContactLocationManager

/// Owns the fetcher and the settings it's created with. Settings are saved between launches.
@MainActor
@Observable
final class ExampleModel {
    /// Replaced when the geocoders change, since they're fixed at creation.
    private(set) var fetcher: ContactHistoryFetcher

    /// Read from Keys.plist; nil if it's missing or has no such key.
    let mapsiAPIKey: String?
    let googleAPIKey: String?

    /// Random coordinates instead of real geocoding, for when there's no network.
    var usesMockGeocoder: Bool {
        didSet { save(usesMockGeocoder, for: "usesMockGeocoder"); makeFetcher() }
    }
    var usesMapKit: Bool {
        didSet { save(usesMapKit, for: "usesMapKit"); makeFetcher() }
    }
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
        defaults.register(defaults: ["usesMapKit": true, "usesMapsi": true, "usesGoogle": true, "maxRequests": 20])
        let usesMockGeocoder = defaults.bool(forKey: "usesMockGeocoder")
        let usesMapKit = defaults.bool(forKey: "usesMapKit")
        let usesMapsi = defaults.bool(forKey: "usesMapsi")
        let usesGoogle = defaults.bool(forKey: "usesGoogle")
        let limitsRequests = defaults.bool(forKey: "limitsRequests")
        let maxRequests = defaults.integer(forKey: "maxRequests")
        let mapsiAPIKey = Self.key("MapsiAPIKey")
        let googleAPIKey = Self.key("GoogleMapsAPIKey")
        let activeMapsiKey = usesMapsi ? mapsiAPIKey : nil
        let activeGoogleKey = usesGoogle ? googleAPIKey : nil
        fetcher = Self.makeFetcher(usesMockGeocoder: usesMockGeocoder,
                                   includesMapKit: usesMapKit || !Self.hasProviderBesidesMapKit(mapsiAPIKey: activeMapsiKey,
                                                                                               googleAPIKey: activeGoogleKey),
                                   mapsiAPIKey: activeMapsiKey,
                                   googleAPIKey: activeGoogleKey,
                                   maxRequests: limitsRequests ? maxRequests : nil)
        self.usesMockGeocoder = usesMockGeocoder
        self.usesMapKit = usesMapKit
        self.usesMapsi = usesMapsi
        self.usesGoogle = usesGoogle
        self.limitsRequests = limitsRequests
        self.maxRequests = maxRequests
        self.mapsiAPIKey = mapsiAPIKey
        self.googleAPIKey = googleAPIKey
    }

    /// Mapsi and Google count as on only when they have a key.
    var isMapsiOn: Bool { usesMapsi && mapsiAPIKey != nil }
    var isGoogleOn: Bool { usesGoogle && googleAPIKey != nil }

    /// Whether a provider other than MapKit is on, so MapKit can be switched off without leaving
    /// the chain empty.
    var hasProviderBesidesMapKit: Bool { isMapsiOn || isGoogleOn }

    /// MapKit as it's actually used: a saved "off" is ignored when nothing else could geocode.
    var includesMapKit: Bool { usesMapKit || !hasProviderBesidesMapKit }

    var requestLimit: Int? { limitsRequests ? maxRequests : nil }

    func refreshCounts() async {
        guard let counts = await Self.countContactsAndAddresses() else { return }
        contactCount = counts.contacts
        addressCount = counts.addresses
    }

    /// The old fetcher should be idle; the view only allows switching providers between syncs.
    private func makeFetcher() {
        fetcher = Self.makeFetcher(usesMockGeocoder: usesMockGeocoder,
                                   includesMapKit: includesMapKit,
                                   mapsiAPIKey: usesMapsi ? mapsiAPIKey : nil,
                                   googleAPIKey: usesGoogle ? googleAPIKey : nil,
                                   maxRequests: requestLimit)
    }

    private static func hasProviderBesidesMapKit(mapsiAPIKey: String?, googleAPIKey: String?) -> Bool {
        mapsiAPIKey != nil || googleAPIKey != nil
    }

    private static func makeFetcher(usesMockGeocoder: Bool, includesMapKit: Bool, mapsiAPIKey: String?,
                                    googleAPIKey: String?, maxRequests: Int?) -> ContactHistoryFetcher {
        if usesMockGeocoder {
            return ContactHistoryFetcher(geocoder: MockGeocoder(), maxRequests: maxRequests)
        }
        return ContactHistoryFetcher(mapsiAPIKey: mapsiAPIKey, googleAPIKey: googleAPIKey,
                                      includesMapKit: includesMapKit, maxRequests: maxRequests)
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
