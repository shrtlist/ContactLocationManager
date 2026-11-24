//
//  FailoverGeocoder.swift
//  ContactLocationManager
//

@preconcurrency import Contacts
import CoreLocation

/// A geocoder that stops asking providers which report rate limiting.
protocol RateLimitClearing: Geocoder {
    /// Asks every provider again from the next lookup on.
    func clearRateLimits() async
}

/// Tries each provider in order and returns the first coordinate found.
///
/// Fails over on no-match and on recoverable errors, but not on `.invalidRequest` or `.offline`.
/// A provider that reports `.rateLimited` isn't asked again until `clearRateLimits()`, which the fetcher
/// calls when a sync starts. While one is left out, an address the others can't find throws `.rateLimited`
/// rather than counting as no match, so it is asked again later.
/// Stops without trying further providers once the calling task is cancelled.
actor FailoverGeocoder: RateLimitClearing {
    private let providers: [any Geocoder]
    private var rateLimited: Set<Int> = []

    init(providers: [any Geocoder]) {
        self.providers = providers
    }

    func clearRateLimits() {
        rateLimited = []
    }

    func coordinate(for postalAddress: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        var lastError: GeocodingError?

        for (index, provider) in providers.enumerated() where !rateLimited.contains(index) {
            do throws(GeocodingError) {
                if let coordinate = try await provider.coordinate(for: postalAddress) {
                    return coordinate
                }
            } catch .invalidRequest {
                throw .invalidRequest
            } catch .offline {
                throw .offline
            } catch {
                // Providers report a cancelled request as an ordinary failure, so ask the task
                // itself. Otherwise a torn-down sync would carry on to the next, possibly billed, provider.
                if Task.isCancelled { throw .cancelled }
                lastError = error
                if error == .rateLimited { rateLimited.insert(index) }
            }
        }

        if let lastError { throw lastError }
        if !rateLimited.isEmpty { throw .rateLimited }
        return nil
    }
}
