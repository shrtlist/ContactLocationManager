//
//  RequestLimitedGeocoder.swift
//  ContactLocationManager
//

@preconcurrency import Contacts
import CoreLocation

/// Allows at most `maxRequests` geocodes in total, counted across launches. Once the limit is
/// reached it throws `.requestLimitReached` without calling the underlying geocoder.
/// A `nil` limit means no limit.
actor RequestLimitedGeocoder: Geocoder {
    private var geocoder: any Geocoder
    private let defaults: UserDefaults
    private var maxRequests: Int?

    private let countKey = "CNGeocodeRequestCount"
    private let refusedKey = "CNGeocodeRequestsRefused"

    init(geocoder: any Geocoder, maxRequests: Int?, defaults: UserDefaults = .standard) {
        self.geocoder = geocoder
        self.maxRequests = maxRequests
        self.defaults = defaults
    }

    /// True once a request has been refused because of the limit, until the limit is raised.
    var hasRefusedRequests: Bool { defaults.bool(forKey: refusedKey) }

    private var count: Int {
        get { defaults.integer(forKey: countKey) }
        set { defaults.set(newValue, forKey: countKey) }
    }

    func coordinate(for postalAddress: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        if let maxRequests, count >= maxRequests {
            defaults.set(true, forKey: refusedKey)
            throw .requestLimitReached
        }

        // Reserve before awaiting so overlapping requests can't overshoot the limit.
        count += 1
        do throws(GeocodingError) {
            return try await geocoder.coordinate(for: postalAddress)
        } catch {
            // A request that failed to get an answer doesn't count.
            count -= 1
            throw error
        }
    }

    /// Geocodes with another geocoder from the next request on. The count and limit carry over.
    func setGeocoder(_ geocoder: any Geocoder) {
        self.geocoder = geocoder
    }

    /// Starts counting from zero again.
    func resetCount() {
        count = 0
        defaults.set(false, forKey: refusedKey)
    }

    /// Returns true if requests had been refused and the new limit lets them through now,
    /// meaning the refused addresses need geocoding again.
    func setMaxRequests(_ newValue: Int?) -> Bool {
        maxRequests = newValue
        guard hasRefusedRequests, newValue.map({ count < $0 }) ?? true else { return false }
        defaults.set(false, forKey: refusedKey)
        return true
    }
}
