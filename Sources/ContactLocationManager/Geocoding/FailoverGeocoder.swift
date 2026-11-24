//
//  FailoverGeocoder.swift
//  ContactLocationManager
//

@preconcurrency import Contacts
import CoreLocation

/// How long a provider that reports rate limiting is skipped.
let providerCooldown: Duration = .seconds(60)

/// How many cooldowns one lookup waits out before it gives up.
private let maxCooldownWaits = 1

/// Tries each provider in order and returns the first coordinate found.
///
/// Fails over on no-match and on recoverable errors, but not on `.invalidRequest` or `.offline`.
/// A provider that reports `.rateLimited` is skipped for `cooldown`, measured on `clock`.
/// When every provider is cooling down, waits for the earliest cooldown to end and tries again,
/// and throws `.rateLimited` if they still refuse after `maxCooldownWaits` waits.
/// When only some are, and the others found no match, throws `.unavailable` so the address is asked again later.
/// Stops without trying further providers once the calling task is cancelled.
actor FailoverGeocoder<C: Clock>: Geocoder where C.Duration == Duration {
    private let providers: [any Geocoder]
    private let cooldown: Duration
    private let clock: C
    private var cooldownUntil: [Int: C.Instant] = [:]

    init(providers: [any Geocoder], cooldown: Duration = providerCooldown, clock: C) {
        self.providers = providers
        self.cooldown = cooldown
        self.clock = clock
    }

    func coordinate(for postalAddress: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        var waits = 0

        while true {
            var lastError: GeocodingError?

            for (index, provider) in providers.enumerated() {
                if let until = cooldownUntil[index], until > clock.now { continue }

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

            if let lastError, lastError != .rateLimited { throw lastError }

            let now = clock.now
            let cooldownEnds = cooldownUntil.values.filter { $0 > now }
            guard cooldownEnds.count == providers.count, let earliest = cooldownEnds.min() else {
                if lastError != nil { throw .unavailable }
                return nil
            }

            guard waits < maxCooldownWaits else { throw .rateLimited }
            waits += 1

            do {
                try await clock.sleep(until: earliest, tolerance: nil)
            } catch {
                throw .cancelled
            }
        }
    }
}

extension FailoverGeocoder where C == ContinuousClock {
    init(providers: [any Geocoder], cooldown: Duration = providerCooldown) {
        self.init(providers: providers, cooldown: cooldown, clock: ContinuousClock())
    }
}
