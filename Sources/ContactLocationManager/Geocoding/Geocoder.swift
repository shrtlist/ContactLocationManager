//
//  Geocoder.swift
//  ContactLocationManager
//

@preconcurrency import Contacts
import CoreLocation

/// Provider-independent failure modes, so failover logic doesn't need to know any service's details.
enum GeocodingError: Error, Sendable {
    /// Quota or throttling hit. The provider should be skipped for a while.
    case rateLimited
    /// Network failure or server error.
    case unavailable
    /// Bad or missing credentials. A configuration bug, but another provider may still work.
    case unauthorized
    /// The address itself is malformed. Every provider would reject it, so don't fail over.
    case invalidRequest
}

protocol Geocoder: Sendable {
    /// Returns nil when the address has no match. Throws `GeocodingError` on service failure.
    func coordinate(for address: CNPostalAddress) async throws -> CLLocationCoordinate2D?
}

extension CNPostalAddress {
    var mailingString: String {
        CNPostalAddressFormatter.string(from: self, style: .mailingAddress)
    }
}

extension URLSession {
    /// Performs `request`, mapping transport and HTTP-level failures onto `GeocodingError`.
    func geocodingData(for request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.data(for: request)
        } catch {
            throw GeocodingError.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw GeocodingError.unavailable }
        switch http.statusCode {
        case 200..<300: return data
        case 400, 422: throw GeocodingError.invalidRequest
        case 401, 403: throw GeocodingError.unauthorized
        case 429: throw GeocodingError.rateLimited
        default: throw GeocodingError.unavailable
        }
    }
}
