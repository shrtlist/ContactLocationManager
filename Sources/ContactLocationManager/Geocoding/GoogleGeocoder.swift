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
    let bundleIdentifier: String?

    /// - Parameter bundleIdentifier: Sent as `X-Ios-Bundle-Identifier` so a key restricted to iOS apps in the
    ///   Google Cloud console is accepted. Defaults to the host app's bundle identifier.
    public init(apiKey: String, session: URLSession = .shared, bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.apiKey = apiKey
        self.session = session
        self.bundleIdentifier = bundleIdentifier
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

    public func coordinate(for address: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        let data = try await session.geocodingData(for: makeRequest(for: address))
        return try Self.parse(data)
    }

    func makeRequest(for address: CNPostalAddress) -> URLRequest {
        let endpoint = URL(string: "https://maps.googleapis.com/maps/api/geocode/json")!
        let url = endpoint.appending(queryItems: [
            URLQueryItem(name: "address", value: address.mailingString),
            URLQueryItem(name: "key", value: apiKey),
        ])
        var request = URLRequest(url: url)
        // Without this header Google rejects requests made with an iOS-app-restricted key (REQUEST_DENIED).
        if let bundleIdentifier {
            request.setValue(bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        return request
    }

    /// Google reports failures inside an HTTP 200 body, so the `status` field decides the outcome.
    static func parse(_ data: Data) throws(GeocodingError) -> CLLocationCoordinate2D? {
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
