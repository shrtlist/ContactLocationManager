//
//  FailoverGeocoder.swift
//  ContactLocationManager
//

@preconcurrency import Contacts
import CoreLocation

/// Tries each provider in order and returns the first coordinate found.
///
/// Fails over on no-match and on recoverable errors, but not on `.invalidRequest` or `.offline`.
/// A provider that reports `.rateLimited` is skipped for `cooldown`, measured on `clock`.
/// When every provider is cooling down, waits for the earliest cooldown to end and tries again,
/// rather than reporting no match for an address nobody looked up.
/// Stops without trying further providers once the calling task is cancelled.
/// How long a provider that reports rate limiting is skipped. The fetcher waits this long before trying again.
@usableFromInline let providerCooldown: Duration = .seconds(60)

public actor FailoverGeocoder<C: Clock>: Geocoder where C.Duration == Duration {
    private let providers: [any Geocoder]
    private let cooldown: Duration
    private let clock: C
    private var cooldownUntil: [Int: C.Instant] = [:]

    public init(providers: [any Geocoder], cooldown: Duration = providerCooldown, clock: C) {
        self.providers = providers
        self.cooldown = cooldown
        self.clock = clock
    }

    public func coordinate(for postalAddress: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        while true {
            var lastError: GeocodingError?
            var skipped = 0
            var earliestCooldownEnd: C.Instant?

            for (index, provider) in providers.enumerated() {
                if let until = cooldownUntil[index], until > clock.now {
                    skipped += 1
                    if earliestCooldownEnd.map({ until < $0 }) ?? true { earliestCooldownEnd = until }
                    continue
                }

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
                    if error == .rateLimited {
                        cooldownUntil[index] = clock.now.advanced(by: cooldown)
                    }
                }
            }

            if let lastError { throw lastError }

            // Every provider was skipped, so none was asked: wait for the first to come back.
            guard skipped == providers.count, let earliestCooldownEnd else { return nil }

            do {
                try await clock.sleep(until: earliestCooldownEnd, tolerance: nil)
            } catch {
                throw .cancelled
            }
        }
    }
}

public extension FailoverGeocoder where C == ContinuousClock {
    init(providers: [any Geocoder], cooldown: Duration = providerCooldown) {
        self.init(providers: providers, cooldown: cooldown, clock: ContinuousClock())
    }
}
