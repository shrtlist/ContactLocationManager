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
    private let store: any RequestCountStore
    private var maxRequests: Int?
    private var state = RequestCount()
    private var isLoaded = false
    /// Changes with every `resetCount()`, so a lookup can tell whether a reset happened while it waited.
    private var generation = 0

    init(geocoder: any Geocoder, maxRequests: Int?, store: any RequestCountStore = CoreDataRequestCountStore()) {
        self.geocoder = geocoder
        self.maxRequests = maxRequests
        self.store = store
    }

    /// True once a request has been refused because of the limit, until the limit is raised.
    var hasRefusedRequests: Bool {
        get async {
            await load()
            return state.refused
        }
    }

    func coordinate(for postalAddress: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        await load()
        if let maxRequests, state.count >= maxRequests {
            state.refused = true
            store.save(state)
            throw .requestLimitReached
        }

        // Reserve before awaiting so overlapping requests can't overshoot the limit.
        state.count += 1
        store.save(state)
        let reservedIn = generation
        do throws(GeocodingError) {
            let coordinate = try await geocoder.coordinate(for: postalAddress)
            if generation != reservedIn {
                // A reset wiped the reservation while this was in flight, but the request was made.
                state.count += 1
                store.save(state)
            }
            return coordinate
        } catch {
            // A request that failed to get an answer doesn't count. After a reset the reservation is already gone.
            if generation == reservedIn {
                state.count -= 1
                store.save(state)
            }
            throw error
        }
    }

    /// Geocodes with another geocoder from the next request on. The count and limit carry over.
    func setGeocoder(_ geocoder: any Geocoder) {
        self.geocoder = geocoder
    }

    func clearRateLimits() async {
        await (geocoder as? any RateLimitClearing)?.clearRateLimits()
    }

    /// Starts counting from zero again.
    func resetCount() {
        generation += 1
        state = RequestCount()
        isLoaded = true
        store.save(state)
    }

    /// Returns true if requests had been refused and the new limit lets them through now,
    /// meaning the refused addresses need geocoding again.
    func setMaxRequests(_ newValue: Int?) async -> Bool {
        await load()
        maxRequests = newValue
        guard state.refused, newValue.map({ state.count < $0 }) ?? true else { return false }
        state.refused = false
        store.save(state)
        return true
    }

    private func load() async {
        guard !isLoaded else { return }
        let loaded = await store.load()
        // `resetCount()` may have run while this waited.
        guard !isLoaded else { return }
        state = loaded
        isLoaded = true
    }
}
