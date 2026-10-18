//
//  MapsiGeocoder.swift
//  ContactLocationManager
//

@preconcurrency import Contacts
import CoreLocation

/// https://mapsi.dev/docs
public struct MapsiGeocoder: Geocoder {
    let apiKey: String
    let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    private struct Response: Decodable {
        struct Result: Decodable {
            struct Coordinates: Decodable { let lat: Double; let lon: Double }
            let coordinates: Coordinates
        }
        let results: [Result]
    }

    public func coordinate(for address: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        let endpoint = URL(string: "https://mapsi.dev/v1/geocode")!
        let url = endpoint.appending(queryItems: [
            URLQueryItem(name: "q", value: address.mailingString),
            URLQueryItem(name: "limit", value: "1"),
        ])
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        let data = try await session.geocodingData(for: request)
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws(GeocodingError) -> CLLocationCoordinate2D? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw GeocodingError.unavailable
        }
        return response.results.first.map {
            CLLocationCoordinate2D(latitude: $0.coordinates.lat, longitude: $0.coordinates.lon)
        }
    }
}
