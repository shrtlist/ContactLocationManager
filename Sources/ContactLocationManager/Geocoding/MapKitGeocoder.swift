//
//  MapKitGeocoder.swift
//  ContactLocationManager
//

@preconcurrency import Contacts
import MapKit

public struct MapKitGeocoder: Geocoder {
    public init() {}

    public func coordinate(for address: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        guard let request = MKGeocodingRequest(addressString: address.mailingString) else { return nil }
        do {
            return try await request.mapItems.first?.location.coordinate
        } catch let error as MKError {
            switch error.code {
            case .placemarkNotFound: return nil
            case .loadingThrottled: throw GeocodingError.rateLimited
            default: throw GeocodingError.unavailable
            }
        } catch {
            throw GeocodingError.unavailable
        }
    }
}
