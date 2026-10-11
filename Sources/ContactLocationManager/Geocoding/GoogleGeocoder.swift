//
//  GoogleGeocoder.swift
//  ContactLocationManager
//

@preconcurrency import Contacts
import CoreLocation

/// https://developers.google.com/maps/documentation/geocoding
public struct GoogleGeocoder: Geocoder {
    let apiKey: String
    let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    private struct Response: Decodable {
        struct Result: Decodable {
            struct Geometry: Decodable {
                struct Location: Decodable { let lat: Double; let lng: Double }
                let location: Location
            }
            let geometry: Geometry
        }
        let status: String
        let results: [Result]?
    }

    public func coordinate(for address: CNPostalAddress) async throws -> CLLocationCoordinate2D? {
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/geocode/json")!
        components.queryItems = [
            URLQueryItem(name: "address", value: address.mailingString),
            URLQueryItem(name: "key", value: apiKey),
        ]
        let data = try await session.geocodingData(for: URLRequest(url: components.url!))
        return try Self.parse(data)
    }

    /// Google reports failures inside an HTTP 200 body, so the `status` field decides the outcome.
    static func parse(_ data: Data) throws -> CLLocationCoordinate2D? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw GeocodingError.unavailable
        }
        switch response.status {
        case "OK":
            return response.results?.first.map {
                CLLocationCoordinate2D(latitude: $0.geometry.location.lat, longitude: $0.geometry.location.lng)
            }
        case "ZERO_RESULTS": return nil
        case "OVER_QUERY_LIMIT", "OVER_DAILY_LIMIT": throw GeocodingError.rateLimited
        case "REQUEST_DENIED": throw GeocodingError.unauthorized
        case "INVALID_REQUEST": throw GeocodingError.invalidRequest
        default: throw GeocodingError.unavailable
        }
    }
}
