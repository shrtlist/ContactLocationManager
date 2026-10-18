//
//  GeocoderFactory.swift
//  ContactLocationManager
//

import Foundation
import OSLog

enum GeocoderFactory {
    /// MapKit, then Mapsi, then Google. Providers without a key are left out, so with no
    /// keys at all the chain is MapKit only.
    static func makeDefault(
        mapsiAPIKey: String?,
        googleAPIKey: String?,
        session: URLSession = .shared
    ) -> any Geocoder {
        var providers: [any Geocoder] = [MapKitGeocoder()]

        if let key = mapsiAPIKey, !key.isEmpty {
            providers.append(MapsiGeocoder(apiKey: key, session: session))
        } else {
            Logger.geocoding.info("No Mapsi API key, skipping Mapsi")
        }
        if let key = googleAPIKey, !key.isEmpty {
            providers.append(GoogleGeocoder(apiKey: key, session: session))
        } else {
            Logger.geocoding.info("No Google API key, skipping Google")
        }

        return FailoverGeocoder(providers: providers)
    }
}
