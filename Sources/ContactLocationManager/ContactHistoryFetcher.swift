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
import Observation

@MainActor
@Observable
public final class ContactHistoryFetcher {
    public private(set) var contactLocations: [ContactLocationSnapshot] = []
    public private(set) var authorizationStatus: CNAuthorizationStatus

    @ObservationIgnored private let savedTokenUserDefaultsKey = "CNContactHistoryChangeHistoryToken"
    @ObservationIgnored private let contactActor: ContactActor
    @ObservationIgnored private var changeObserver: Task<Void, Never>?

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
    public init(mapsiAPIKey: String? = nil, googleAPIKey: String? = nil) {
        let geocoder = GeocoderFactory.makeDefault(mapsiAPIKey: mapsiAPIKey, googleAPIKey: googleAPIKey)
        contactActor = ContactActor(geocoder: geocoder)
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        startIfAuthorized()
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

    public func reset() async {
        savedToken = nil
        await contactActor.removeAll()
        contactLocations = []
    }

    private func fetchChanges() async {
        // At first launch, the token will be nil and all contacts will be retrieved as additions
        guard let (token, changes) = try? await Self.fetchHistory(startingToken: savedToken) else { return }
        savedToken = token
        await contactActor.apply(changes)
        contactLocations = await contactActor.fetchAll()
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
