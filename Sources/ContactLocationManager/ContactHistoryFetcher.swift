//
//  ContactHistoryFetcher.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 10/8/26.
//

// Source - https://stackoverflow.com/a/75860924
// Posted by AnderCover, modified by community. See post 'Timeline' for change history
// Retrieved 2026-10-08, License - CC BY-SA 4.0

@preconcurrency import Contacts
import ContactsChangeHistory
import CoreLocation
import Observation

@MainActor
@Observable
public final class ContactHistoryFetcher {
    public private(set) var contactLocationAnnotations: [ContactLocationAnnotation] = []
    public private(set) var authorizationStatus: CNAuthorizationStatus

    /// 0...1 while contacts are being processed, `nil` when idle.
    public private(set) var syncProgress: Double?

    /// True when contacts were skipped because the request limit was reached.
    /// Cleared by `setMaxRequests(_:)` once the limit is raised.
    public private(set) var isRateLimited = false

    @ObservationIgnored private let savedTokenUserDefaultsKey = "CNContactHistoryChangeHistoryToken"
    @ObservationIgnored private let contactActor: ContactActor
    @ObservationIgnored private let limiter: RequestLimitedGeocoder
    @ObservationIgnored private var changeObserver: Task<Void, Never>?
    @ObservationIgnored private var isFetching = false
    @ObservationIgnored private var needsAnotherFetch = false
    @ObservationIgnored private var startOver = false

    @ObservationIgnored private var savedToken: Data? {
        get {
            UserDefaults.standard.data(forKey: savedTokenUserDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: savedTokenUserDefaultsKey)
        }
    }

    /// Starts loading contacts right away if access has already been granted. Otherwise the host
    /// calls `requestAccess()` when it's ready to show the system prompt.
    /// Geocoding tries MapKit first, then Mapsi, then Google. A provider without a key is left out.
    /// `maxRequests` is the total number of addresses that will ever be geocoded, or `nil` for no
    /// limit. Contacts beyond it are skipped and `isRateLimited` becomes true.
    /// `contactKeys` are the contact properties each annotation's `contact` has loaded, on top of
    /// the postal addresses, which are always loaded. The default is the name, thumbnail and type.
    public convenience init(mapsiAPIKey: String? = nil,
                            googleAPIKey: String? = nil,
                            maxRequests: Int? = nil,
                            contactKeys: [any CNKeyDescriptor] = ContactHistoryFetcher.defaultContactKeys) {
        self.init(geocoder: GeocoderFactory.makeDefault(mapsiAPIKey: mapsiAPIKey, googleAPIKey: googleAPIKey),
                  maxRequests: maxRequests,
                  contactKeys: contactKeys)
    }

    /// Like `init(mapsiAPIKey:googleAPIKey:maxRequests:contactKeys:)`, but geocodes with the given
    /// geocoder instead of the MapKit, Mapsi and Google chain, for example a mock for testing.
    public init(geocoder: any Geocoder,
                maxRequests: Int? = nil,
                contactKeys: [any CNKeyDescriptor] = ContactHistoryFetcher.defaultContactKeys) {
        limiter = RequestLimitedGeocoder(base: geocoder, maxRequests: maxRequests)
        let keys = ContactKeys(contactKeys + [CNContactPostalAddressesKey as CNKeyDescriptor])
        contactActor = ContactActor(geocoder: limiter, contactKeys: keys)
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        startIfAuthorized()
    }

    public static var defaultContactKeys: [any CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactTypeKey as CNKeyDescriptor,
        ]
    }

    /// Shows the system permission prompt if the user hasn't been asked yet, then starts loading
    /// contacts if access was granted. Does nothing for any other status.
    public func requestAccess() async {
        guard authorizationStatus == .notDetermined else { return }
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        startIfAuthorized()
    }

    private func startIfAuthorized() {
        guard authorizationStatus == .authorized || authorizationStatus == .limited,
              changeObserver == nil else { return }
        observeContactStore()
        Task { await fetchChanges() }
    }

    /// Responds to `CNContactStoreDidChange`, for example if a contact has been changed on another device.
    /// The task ends once the fetcher is deallocated.
    private func observeContactStore() {
        changeObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CNContactStoreDidChange) {
                guard let self else { break }
                await self.fetchChanges()
            }
        }
    }

    /// Forgets every stored location, starts the request count from zero and geocodes every
    /// contact again. If a sync is running, it stops after the contact it is on and the new one
    /// starts then, which may be after this returns.
    public func reset() async {
        await limiter.resetCount()
        isRateLimited = false
        startOver = true
        await fetchChanges()
    }

    /// Changes the request limit, for example when the user subscribes. If contacts were skipped
    /// under the old limit and the new one lets them through, everything is geocoded again.
    /// If a sync is running, it stops after the contact it is on and the new one starts then,
    /// which may be after this returns.
    public func setMaxRequests(_ maxRequests: Int?) async {
        guard await limiter.setMaxRequests(maxRequests) else { return }
        isRateLimited = false
        startOver = true
        await fetchChanges()
    }

    private func fetchChanges() async {
        needsAnotherFetch = true
        await runSync()
    }

    /// One sync at a time. The token is only saved once a sync's changes are applied, so a sync
    /// that started meanwhile would read the same changes again. A change that arrives during a
    /// sync is picked up by another pass straight afterwards.
    /// Clearing also happens here, between passes, so it can't interleave with a running pass.
    private func runSync() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        while startOver || needsAnotherFetch {
            if startOver {
                startOver = false
                savedToken = nil
                await contactActor.removeAll()
                contactLocationAnnotations = []
                continue
            }
            needsAnotherFetch = false
            await fetchChangesOnce()
        }
    }

    /// Stops early, without saving the token or publishing, once a clear has been asked for.
    private func fetchChangesOnce() async {
        // At first launch, the token will be nil and all contacts will be retrieved as additions
        guard let (token, changes) = try? await Self.fetchHistory(startingToken: savedToken), !startOver else { return }
        defer { syncProgress = nil }
        for (index, change) in changes.enumerated() {
            syncProgress = Double(index) / Double(changes.count)
            await contactActor.apply([change])
            guard !startOver else { return }
        }
        // Saved after applying: if the app is killed mid-sync, the next launch reads these changes again.
        savedToken = token
        syncProgress = nil
        // If the contacts couldn't be read, keep what is on the map rather than blanking it.
        if let annotations = await contactActor.fetchAll(), !startOver {
            contactLocationAnnotations = annotations
        }
        isRateLimited = await limiter.didRefuse
    }

    @concurrent
    private static func fetchHistory(startingToken: Data?) async throws -> (Data?, [ContactHistoryChange]) {
        let fetchHistoryRequest = CNChangeHistoryFetchRequest()
        fetchHistoryRequest.startingToken = startingToken
        // Geocoding needs the postal addresses; the full name is for the host's convenience.
        fetchHistoryRequest.additionalContactKeyDescriptors = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPostalAddressesKey as CNKeyDescriptor,
        ]
        let wrapper = ContactStoreWrapper(store: CNContactStore())
        let result = try wrapper.changeHistoryFetchResult(fetchHistoryRequest)
        let visitor = Visitor()
        let enumerator = result.value
        while let event = enumerator.nextObject() as? CNChangeHistoryEvent {
            // The appropriate `visit(_:)` method will be called right away
            event.accept(visitor)
        }
        // Save the result's token as stated in the CNContactStore documentation:
        // when fetching change history events, use the token on CNFetchResult.
        return (result.currentHistoryToken, visitor.changes)
    }
}
