//
//  FailoverGeocoder.swift
//  ContactLocationManager
//

@preconcurrency import Contacts
import CoreLocation

/// Tries each provider in order and returns the first coordinate found.
///
/// Fails over on no-match and on recoverable errors, but not on `.invalidRequest`.
/// A provider that reports `.rateLimited` is skipped for `cooldown` seconds.
actor FailoverGeocoder: Geocoder {
    private let providers: [any Geocoder]
    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date
    private var cooldownUntil: [Int: Date] = [:]

    init(providers: [any Geocoder], cooldown: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.providers = providers
        self.cooldown = cooldown
        self.now = now
    }

    func coordinate(for address: CNPostalAddress) async throws -> CLLocationCoordinate2D? {
        var lastError: Error?
        for (index, provider) in providers.enumerated() {
            if let until = cooldownUntil[index], until > now() { continue }
            do {
                if let coordinate = try await provider.coordinate(for: address) {
                    return coordinate
                }
            } catch GeocodingError.invalidRequest {
                throw GeocodingError.invalidRequest
            } catch {
                lastError = error
                if case GeocodingError.rateLimited = error {
                    cooldownUntil[index] = now().addingTimeInterval(cooldown)
                }
            }
        }
        if let lastError { throw lastError }
        return nil
    }
}
