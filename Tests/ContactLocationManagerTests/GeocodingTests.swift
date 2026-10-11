import Testing
import Foundation
import Contacts
import CoreLocation
@testable import ContactLocationManager

private final class StubGeocoder: Geocoder, @unchecked Sendable {
    enum Outcome { case coordinate(Double), noMatch, failure(GeocodingError) }
    let outcome: Outcome
    private(set) var calls = 0

    init(_ outcome: Outcome) { self.outcome = outcome }

    func coordinate(for address: CNPostalAddress) async throws -> CLLocationCoordinate2D? {
        calls += 1
        switch outcome {
        case .coordinate(let value): return CLLocationCoordinate2D(latitude: value, longitude: value)
        case .noMatch: return nil
        case .failure(let error): throw error
        }
    }
}

private let address = CNPostalAddress()

@Suite struct FailoverGeocoderTests {
    @Test func returnsFirstMatch() async throws {
        let first = StubGeocoder(.coordinate(1)), second = StubGeocoder(.coordinate(2))
        let result = try await FailoverGeocoder(providers: [first, second]).coordinate(for: address)
        #expect(result?.latitude == 1)
        #expect(second.calls == 0)
    }

    @Test func failsOverOnNoMatchAndOnErrors() async throws {
        let providers: [StubGeocoder] = [.init(.noMatch), .init(.failure(.unavailable)), .init(.coordinate(3))]
        let result = try await FailoverGeocoder(providers: providers).coordinate(for: address)
        #expect(result?.latitude == 3)
    }

    @Test func invalidRequestDoesNotFailOver() async {
        let first = StubGeocoder(.failure(.invalidRequest)), second = StubGeocoder(.coordinate(2))
        await #expect(throws: GeocodingError.self) {
            try await FailoverGeocoder(providers: [first, second]).coordinate(for: address)
        }
        #expect(second.calls == 0)
    }

    @Test func allNoMatchReturnsNil() async throws {
        let result = try await FailoverGeocoder(providers: [StubGeocoder(.noMatch), StubGeocoder(.noMatch)])
            .coordinate(for: address)
        #expect(result == nil)
    }

    @Test func rethrowsLastErrorWhenNothingMatches() async {
        let providers: [StubGeocoder] = [.init(.noMatch), .init(.failure(.unauthorized))]
        await #expect(throws: GeocodingError.self) {
            try await FailoverGeocoder(providers: providers).coordinate(for: address)
        }
    }

    @Test func rateLimitedProviderIsSkippedUntilCooldownEnds() async throws {
        let limited = StubGeocoder(.failure(.rateLimited)), backup = StubGeocoder(.coordinate(2))
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let geocoder = FailoverGeocoder(providers: [limited, backup], cooldown: 60, now: { clock.date })

        _ = try await geocoder.coordinate(for: address)
        _ = try await geocoder.coordinate(for: address)
        #expect(limited.calls == 1)

        clock.date = Date(timeIntervalSince1970: 61)
        _ = try await geocoder.coordinate(for: address)
        #expect(limited.calls == 2)
    }
}

private final class Clock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@Suite struct ResponseParsingTests {
    @Test func mapsi() throws {
        let json = #"{"results":[{"coordinates":{"lat":48.8584,"lon":2.2945},"formatted_address":"x"}]}"#
        let c = try MapsiGeocoder.parse(Data(json.utf8))
        #expect(c?.latitude == 48.8584 && c?.longitude == 2.2945)
        #expect(try MapsiGeocoder.parse(Data(#"{"results":[]}"#.utf8)) == nil)
    }

    @Test func googleOK() throws {
        let json = #"{"status":"OK","results":[{"geometry":{"location":{"lat":37.4,"lng":-122.1}}}]}"#
        let c = try GoogleGeocoder.parse(Data(json.utf8))
        #expect(c?.latitude == 37.4 && c?.longitude == -122.1)
    }

    @Test func googleStatuses() throws {
        #expect(try GoogleGeocoder.parse(Data(#"{"status":"ZERO_RESULTS","results":[]}"#.utf8)) == nil)
        for (status, expected) in [("OVER_QUERY_LIMIT", GeocodingError.rateLimited),
                                   ("REQUEST_DENIED", .unauthorized),
                                   ("INVALID_REQUEST", .invalidRequest),
                                   ("UNKNOWN_ERROR", .unavailable)] {
            do {
                _ = try GoogleGeocoder.parse(Data(#"{"status":"\#(status)"}"#.utf8))
                Issue.record("\(status) should throw")
            } catch let error as GeocodingError {
                #expect(error == expected)
            }
        }
    }
}
