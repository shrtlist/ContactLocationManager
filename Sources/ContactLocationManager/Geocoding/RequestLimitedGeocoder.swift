//
//  RequestLimitedGeocoder.swift
//  ContactLocationManager
//

@preconcurrency import Contacts
import CoreLocation

/// Allows at most `maxRequests` geocodes in total, counted across launches. Once the limit is
/// reached it throws `.rateLimited` without calling the underlying geocoder.
/// A `nil` limit means no limit.
actor RequestLimitedGeocoder: Geocoder {
    private let base: any Geocoder
    private let defaults: UserDefaults
    private var maxRequests: Int?

    private let countKey = "CNGeocodeRequestCount"
    private let refusedKey = "CNGeocodeRequestsRefused"

    init(base: any Geocoder, maxRequests: Int?, defaults: UserDefaults = .standard) {
        self.base = base
        self.maxRequests = maxRequests
        self.defaults = defaults
    }

    /// True once a request has been refused because of the limit, until the limit is raised.
    var didRefuse: Bool { defaults.bool(forKey: refusedKey) }

    private var count: Int {
        get { defaults.integer(forKey: countKey) }
        set { defaults.set(newValue, forKey: countKey) }
    }

    func coordinate(for address: CNPostalAddress) async throws -> CLLocationCoordinate2D? {
        if let maxRequests, count >= maxRequests {
            defaults.set(true, forKey: refusedKey)
            throw GeocodingError.rateLimited
        }

        // Reserve before awaiting so overlapping requests can't overshoot the limit.
        count += 1
        do {
            return try await base.coordinate(for: address)
        } catch {
            // A request that failed to get an answer doesn't count.
            count -= 1
            throw error
        }
    }

    /// Returns true if requests had been refused and the new limit lets them through now,
    /// meaning the refused addresses need geocoding again.
    func setMaxRequests(_ newValue: Int?) -> Bool {
        maxRequests = newValue
        guard didRefuse, newValue.map({ count < $0 }) ?? true else { return false }
        defaults.set(false, forKey: refusedKey)
        return true
    }
}
