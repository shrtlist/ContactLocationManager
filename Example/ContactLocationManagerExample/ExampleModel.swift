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
    let fetcher: ContactHistoryFetcher

    /// Read from Keys.plist; nil if it's missing or has no such key.
    let mapsiAPIKey: String?
    let googleAPIKey: String?

    /// Random coordinates instead of real geocoding, for when there's no network.
    var usesMockGeocoder: Bool {
        didSet { save(usesMockGeocoder, for: "usesMockGeocoder"); updateGeocoder() }
    }
    var usesMapKit: Bool {
        didSet { save(usesMapKit, for: "usesMapKit"); updateGeocoder() }
    }
    var usesMapsi: Bool {
        didSet { save(usesMapsi, for: "usesMapsi"); updateGeocoder() }
    }
    var usesGoogle: Bool {
        didSet { save(usesGoogle, for: "usesGoogle"); updateGeocoder() }
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

    /// Creates the shared fetcher from the saved settings. Called once, at launch, before `ExampleModel()`.
    static func configureFetcher() {
        let defaults = UserDefaults.standard
        registerDefaults()
        let usesMapsi = defaults.bool(forKey: "usesMapsi")
        let usesGoogle = defaults.bool(forKey: "usesGoogle")
        let activeMapsiKey = usesMapsi ? key("MapsiAPIKey") : nil
        let activeGoogleKey = usesGoogle ? key("GoogleMapsAPIKey") : nil
        let maxRequests = defaults.bool(forKey: "limitsRequests") ? defaults.integer(forKey: "maxRequests") : nil
        if defaults.bool(forKey: "usesMockGeocoder") {
            ContactHistoryFetcher.configure(geocoder: MockGeocoder(), maxRequests: maxRequests)
        } else {
            ContactHistoryFetcher.configure(mapsiAPIKey: activeMapsiKey, googleAPIKey: activeGoogleKey,
                                            includesMapKit: defaults.bool(forKey: "usesMapKit")
                                                || !hasProviderBesidesMapKit(mapsiAPIKey: activeMapsiKey,
                                                                             googleAPIKey: activeGoogleKey),
                                            maxRequests: maxRequests)
        }
    }

    private static func registerDefaults() {
        UserDefaults.standard.register(defaults: ["usesMapKit": true, "usesMapsi": true, "usesGoogle": true, "maxRequests": 20])
    }

    /// `configureFetcher()` must have run first.
    init() {
        let defaults = UserDefaults.standard
        Self.registerDefaults()
        let usesMockGeocoder = defaults.bool(forKey: "usesMockGeocoder")
        let usesMapKit = defaults.bool(forKey: "usesMapKit")
        let usesMapsi = defaults.bool(forKey: "usesMapsi")
        let usesGoogle = defaults.bool(forKey: "usesGoogle")
        let limitsRequests = defaults.bool(forKey: "limitsRequests")
        let maxRequests = defaults.integer(forKey: "maxRequests")
        let mapsiAPIKey = Self.key("MapsiAPIKey")
        let googleAPIKey = Self.key("GoogleMapsAPIKey")
        fetcher = .shared
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
        // Reading contacts before the user has been asked would raise the system prompt by itself.
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status == .limited else { return }
        guard let counts = await Self.countContactsAndAddresses() else { return }
        contactCount = counts.contacts
        addressCount = counts.addresses
    }

    private func updateGeocoder() {
        let fetcher = fetcher, usesMockGeocoder = usesMockGeocoder, includesMapKit = includesMapKit
        let mapsiAPIKey = usesMapsi ? mapsiAPIKey : nil, googleAPIKey = usesGoogle ? googleAPIKey : nil
        Task {
            if usesMockGeocoder {
                await fetcher.setGeocoder(MockGeocoder())
            } else {
                await fetcher.setGeocoder(mapsiAPIKey: mapsiAPIKey, googleAPIKey: googleAPIKey,
                                          includesMapKit: includesMapKit)
            }
        }
    }

    private static func hasProviderBesidesMapKit(mapsiAPIKey: String?, googleAPIKey: String?) -> Bool {
        mapsiAPIKey != nil || googleAPIKey != nil
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
