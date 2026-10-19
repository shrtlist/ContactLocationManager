import Testing
import Contacts
import CoreLocation
import MapKit
import Synchronization
@testable import ContactLocationManager

private final class StubGeocoder: Geocoder {
    enum Outcome: Sendable { case coordinate(Double), noMatch, failure(GeocodingError) }
    let outcome: Outcome
    private let callCount = Mutex(0)
    var calls: Int { callCount.withLock { $0 } }

    init(_ outcome: Outcome) { self.outcome = outcome }

    func coordinate(for address: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        callCount.withLock { $0 += 1 }
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
        await #expect(throws: GeocodingError.invalidRequest) {
            try await FailoverGeocoder(providers: [first, second]).coordinate(for: address)
        }
        #expect(second.calls == 0)
    }

    @Test func offlineDoesNotFailOver() async {
        let first = StubGeocoder(.failure(.offline)), second = StubGeocoder(.coordinate(2))
        await #expect(throws: GeocodingError.offline) {
            try await FailoverGeocoder(providers: [first, second]).coordinate(for: address)
        }
        #expect(second.calls == 0)
    }

    @Test func recognizesOfflineURLErrors() {
        #expect(isOfflineError(URLError(.notConnectedToInternet)))
        #expect(isOfflineError(URLError(.networkConnectionLost)))
        #expect(!isOfflineError(URLError(.timedOut)))
        let wrapped = NSError(domain: MKErrorDomain, code: 4,
                              userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)])
        #expect(isOfflineError(wrapped))
    }

    @Test func allNoMatchReturnsNil() async throws {
        let result = try await FailoverGeocoder(providers: [StubGeocoder(.noMatch), StubGeocoder(.noMatch)])
            .coordinate(for: address)
        #expect(result == nil)
    }

    @Test func rethrowsLastErrorWhenNothingMatches() async {
        let providers: [StubGeocoder] = [.init(.noMatch), .init(.failure(.unauthorized))]
        await #expect(throws: GeocodingError.unauthorized) {
            try await FailoverGeocoder(providers: providers).coordinate(for: address)
        }
    }

    @Test func rateLimitedProviderIsSkippedUntilCooldownEnds() async throws {
        let limited = StubGeocoder(.failure(.rateLimited)), backup = StubGeocoder(.coordinate(2))
        let clock = ManualClock()
        let geocoder = FailoverGeocoder(providers: [limited, backup], cooldown: .seconds(60), clock: clock)

        _ = try await geocoder.coordinate(for: address)
        _ = try await geocoder.coordinate(for: address)
        #expect(limited.calls == 1)

        clock.advance(by: .seconds(61))
        _ = try await geocoder.coordinate(for: address)
        #expect(limited.calls == 2)
    }
}

private struct ManualInstant: InstantProtocol {
    var offset: Duration

    func advanced(by duration: Duration) -> ManualInstant { ManualInstant(offset: offset + duration) }
    func duration(to other: ManualInstant) -> Duration { other.offset - offset }
    static func < (lhs: ManualInstant, rhs: ManualInstant) -> Bool { lhs.offset < rhs.offset }
}

private final class ManualClock: Clock, Sendable {
    typealias Duration = Swift.Duration
    private let elapsed = Mutex(Duration.zero)

    var now: ManualInstant { ManualInstant(offset: elapsed.withLock { $0 }) }
    var minimumResolution: Duration { .zero }

    func advance(by duration: Duration) { elapsed.withLock { $0 += duration } }

    func sleep(until deadline: ManualInstant, tolerance: Duration?) async throws {}
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

    @Test func googleZeroResultsIsNoMatch() throws {
        #expect(try GoogleGeocoder.parse(Data(#"{"status":"ZERO_RESULTS","results":[]}"#.utf8)) == nil)
    }

    @Test(arguments: [
        ("OVER_QUERY_LIMIT", GeocodingError.rateLimited),
        ("REQUEST_DENIED", .unauthorized),
        ("INVALID_REQUEST", .invalidRequest),
        ("UNKNOWN_ERROR", .unavailable),
    ])
    func googleErrorStatuses(status: String, expected: GeocodingError) {
        #expect(throws: expected) {
            try GoogleGeocoder.parse(Data(#"{"status":"\#(status)"}"#.utf8))
        }
    }
}

private struct CancelledSecondProviderGeocoder: Geocoder {
    func coordinate(for address: CNPostalAddress) async throws(GeocodingError) -> CLLocationCoordinate2D? {
        // Like URLSession and MapKit, report cancellation as an ordinary failure.
        do { try await Task.sleep(for: .seconds(60)) } catch { throw .unavailable }
        return nil
    }
}

@Suite struct FailoverCancellationTests {
    @Test func cancelledTaskDoesNotReachTheNextProvider() async {
        let backup = StubGeocoder(.coordinate(2))
        let geocoder = FailoverGeocoder(providers: [CancelledSecondProviderGeocoder(), backup])
        let task = Task { try await geocoder.coordinate(for: address) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        await #expect(throws: GeocodingError.cancelled) { try await task.value }
        #expect(backup.calls == 0)
    }
}

@Suite struct RequestLimitedGeocoderTests {
    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return defaults
    }

    @Test func refusesOnceTheLimitIsReached() async throws {
        let base = StubGeocoder(.coordinate(1))
        let geocoder = RequestLimitedGeocoder(base: base, maxRequests: 2, defaults: makeDefaults())
        _ = try await geocoder.coordinate(for: address)
        _ = try await geocoder.coordinate(for: address)
        await #expect(throws: GeocodingError.rateLimited) { try await geocoder.coordinate(for: address) }
        #expect(base.calls == 2)
        #expect(await geocoder.didRefuse)
    }

    @Test func noLimitMeansNoRefusals() async throws {
        let geocoder = RequestLimitedGeocoder(base: StubGeocoder(.coordinate(1)), maxRequests: nil, defaults: makeDefaults())
        for _ in 0..<50 { _ = try await geocoder.coordinate(for: address) }
        #expect(await !geocoder.didRefuse)
    }

    @Test func failedRequestsDontCount() async throws {
        let geocoder = RequestLimitedGeocoder(base: StubGeocoder(.failure(.unavailable)), maxRequests: 1, defaults: makeDefaults())
        for _ in 0..<3 {
            await #expect(throws: GeocodingError.unavailable) { try await geocoder.coordinate(for: address) }
        }
        #expect(await !geocoder.didRefuse)
    }

    @Test func raisingTheLimitAfterARefusalAsksForAResync() async throws {
        let geocoder = RequestLimitedGeocoder(base: StubGeocoder(.coordinate(1)), maxRequests: 1, defaults: makeDefaults())
        _ = try await geocoder.coordinate(for: address)
        _ = try? await geocoder.coordinate(for: address)

        let needsResync = await geocoder.setMaxRequests(nil)
        #expect(needsResync)
        #expect(await !geocoder.didRefuse)
        _ = try await geocoder.coordinate(for: address)
    }

    @Test func resetCountAllowsRequestsAgain() async throws {
        let geocoder = RequestLimitedGeocoder(base: StubGeocoder(.coordinate(1)), maxRequests: 1, defaults: makeDefaults())
        _ = try await geocoder.coordinate(for: address)
        _ = try? await geocoder.coordinate(for: address)

        await geocoder.resetCount()
        #expect(await !geocoder.didRefuse)
        _ = try await geocoder.coordinate(for: address)
    }

    @Test func raisingTheLimitWithoutARefusalNeedsNoResync() async throws {
        let geocoder = RequestLimitedGeocoder(base: StubGeocoder(.coordinate(1)), maxRequests: 5, defaults: makeDefaults())
        _ = try await geocoder.coordinate(for: address)
        #expect(await !geocoder.setMaxRequests(nil))
    }
}

@Suite struct AnnotationTextTests {
    private func annotation(givenName: String = "", familyName: String = "", organization: String = "", street: String = "1 Main St", city: String = "Springfield") -> ContactLocationAnnotation {
        let contact = CNMutableContact()
        contact.givenName = givenName
        contact.familyName = familyName
        contact.organizationName = organization

        let address = CNMutablePostalAddress()
        address.street = street
        address.city = city
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address as CNPostalAddress)]

        return ContactLocationAnnotation(contact: contact, labeledAddress: contact.postalAddresses[0],
                                         latitude: 1, longitude: 2)
    }

    @Test func titleIsThePersonsName() {
        #expect(annotation(givenName: "Ada", familyName: "Lovelace").title == "Ada Lovelace")
    }

    @Test func titleFallsBackToTheOrganization() {
        #expect(annotation(organization: "Acme").title == "Acme")
    }

    @Test func titleIsNilWithoutAName() {
        #expect(annotation().title == nil)
    }

    /// MapKit reads `title` and `subtitle` through Objective-C, so they must be visible there.
    @Test func conformsToMKAnnotationForMapKit() {
        let annotation = annotation(givenName: "Ada", familyName: "Lovelace")
        let object: NSObject = annotation
        #expect(annotation is MKAnnotation)
        #expect(object.responds(to: #selector(getter: MKAnnotation.coordinate)))
        #expect(object.responds(to: #selector(getter: MKAnnotation.title)))
        #expect(object.responds(to: #selector(getter: MKAnnotation.subtitle)))
        #expect(object.value(forKey: "title") as? String == "Ada Lovelace")
    }

    @Test func subtitleIsTheMailingAddress() {
        let subtitle = annotation().subtitle
        #expect(subtitle?.contains("1 Main St") == true)
        #expect(subtitle?.contains("Springfield") == true)
    }
}
