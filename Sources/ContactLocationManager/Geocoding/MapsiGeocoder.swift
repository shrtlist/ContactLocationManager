//
//  MapsiGeocoder.swift
//  ContactLocationManager
//

@preconcurrency import Contacts
import CoreLocation

/// https://mapsi.dev/docs
struct MapsiGeocoder: Geocoder {
    let apiKey: String
    var session: URLSession = .shared

    private struct Response: Decodable {
        struct Result: Decodable {
            struct Coordinates: Decodable { let lat: Double; let lon: Double }
            let coordinates: Coordinates
        }
        let results: [Result]
    }

    func coordinate(for address: CNPostalAddress) async throws -> CLLocationCoordinate2D? {
        var components = URLComponents(string: "https://mapsi.dev/v1/geocode")!
        components.queryItems = [
            URLQueryItem(name: "q", value: address.mailingString),
            URLQueryItem(name: "limit", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        let data = try await session.geocodingData(for: request)
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> CLLocationCoordinate2D? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw GeocodingError.unavailable
        }
        return response.results.first.map {
            CLLocationCoordinate2D(latitude: $0.coordinates.lat, longitude: $0.coordinates.lon)
        }
    }
}
