//
//  FailoverGeocoder.swift
//  ContactLocationManager
//

@preconcurrency import Contacts
import CoreLocation

/// Tries each provider in order and returns the first coordinate found.
///
/// Fails over on no-match and on recoverable errors, but not on `.invalidRequest`.
/// A provider that reports `.rateLimited` is skipped for `cooldown`, measured on `clock`.
/// Stops without trying further providers once the calling task is cancelled.
public actor FailoverGeocoder<C: Clock>: Geocoder where C.Duration == Duration {
    private let providers: [any Geocoder]
    private let cooldown: Duration
    private let clock: C
    private var cooldownUntil: [Int: C.Instant] = [:]

    public init(providers: [any Geocoder], cooldown: Duration = .seconds(60), clock: C) {
        self.providers = providers
        self.cooldown = cooldown
        self.clock = clock
    }

    public func coordinate(for address: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        var lastError: GeocodingError?
        for (index, provider) in providers.enumerated() {
            if let until = cooldownUntil[index], until > clock.now { continue }
            do throws(GeocodingError) {
                if let coordinate = try await provider.coordinate(for: address) {
                    return coordinate
                }
            } catch .invalidRequest {
                throw .invalidRequest
            } catch {
                // Providers report a cancelled request as an ordinary failure, so ask the task
                // itself. Otherwise a torn-down sync would carry on to the next, possibly billed, provider.
                if Task.isCancelled { throw .cancelled }
                lastError = error
                if error == .rateLimited {
                    cooldownUntil[index] = clock.now.advanced(by: cooldown)
                }
            }
        }
        if let lastError { throw lastError }
        return nil
    }
}

public extension FailoverGeocoder where C == ContinuousClock {
    init(providers: [any Geocoder], cooldown: Duration = .seconds(60)) {
        self.init(providers: providers, cooldown: cooldown, clock: ContinuousClock())
    }
}
