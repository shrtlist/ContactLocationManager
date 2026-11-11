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
import ContactsUI
import CoreLocation
import Network
import Observation
import OSLog
import UIKit

/// Create one per process and keep it for the life of the app; change its geocoder with
/// `setGeocoder` rather than making another. Every fetcher shares the same
/// store and history token, so two fetchers syncing at once would duplicate geocoding requests and
/// could wipe each other's locations.
@MainActor
@Observable
public final class ContactHistoryFetcher {
    // `internal(set)` so tests can seed annotations without a contact store.
    public internal(set) var contactLocationAnnotations: [ContactLocationAnnotation] = []
    public internal(set) var ungeocodedAddresses: [UngeocodedAddress] = []
    public private(set) var authorizationStatus: CNAuthorizationStatus

    /// 0...1 while contacts are being processed, `nil` when idle.
    public private(set) var syncProgress: Double?

    /// True when contacts were skipped because the request limit was reached.
    /// Cleared by `setMaxRequests(_:)` once the limit is raised.
    public private(set) var hasReachedRequestLimit = false

    /// Why the fetcher couldn't read Contacts the last time it asked for changes, or `nil` if it could.
    public private(set) var syncError: ContactSyncError?

    @ObservationIgnored private let contactActor: ContactActor
    @ObservationIgnored private let limiter: RequestLimitedGeocoder
    @ObservationIgnored private var isFetching = false
    @ObservationIgnored private var contactChangeObservation: Task<Void, Never>?
    @ObservationIgnored private var foregroundObservation: Task<Void, Never>?
    /// Waits out a provider's cooldown, then syncs again. At most one is pending.
    @ObservationIgnored private var cooldownRetry: Task<Void, Never>?
    /// True when the last pass stopped early, so the next time the app becomes active it syncs again.
    @ObservationIgnored private var retryWhenActive = false
    @ObservationIgnored private var needsAnotherFetch = false
    /// Addresses that couldn't be asked earlier are looked up again after the next history pass.
    @ObservationIgnored private var needsRetryPass = false
    @ObservationIgnored private var startOver = false
    @ObservationIgnored private var isStarted = false

    /// Doesn't sync by itself: the host calls `start()` when it's ready, for example once it knows the
    /// request limit. If access has already been granted, the locations stored by earlier syncs are
    /// published right away. Otherwise `start()` shows the system prompt, or the host calls `requestAccess()`
    /// to show it earlier.
    /// Geocoding tries MapKit first, then Mapsi, then Google. A provider without a key is left out,
    /// and MapKit is left out when `includesMapKit` is false, for example to test another provider alone.
    /// `maxRequests` is the total number of addresses that will ever be geocoded, or `nil` for no
    /// limit. Contacts beyond it are skipped and `hasReachedRequestLimit` becomes true.
    /// `contactKeys` are the contact properties each annotation's `contact` has loaded, on top of
    /// the postal addresses, which are always loaded. The default is the name, thumbnail and type.
    public convenience init(mapsiAPIKey: String? = nil,
                            googleAPIKey: String? = nil,
                            includesMapKit: Bool = true,
                            maxRequests: Int? = nil,
                            contactKeys: [any CNKeyDescriptor] = ContactHistoryFetcher.defaultContactKeys) {
        self.init(geocoder: GeocoderFactory.makeDefault(mapsiAPIKey: mapsiAPIKey,
                                                        googleAPIKey: googleAPIKey,
                                                        includesMapKit: includesMapKit),
                  maxRequests: maxRequests,
                  contactKeys: contactKeys)
    }

    /// Like `init(mapsiAPIKey:googleAPIKey:includesMapKit:maxRequests:contactKeys:)`, but geocodes with the given
    /// geocoder instead of the MapKit, Mapsi and Google chain, for example a mock for testing.
    public init(geocoder: any Geocoder,
                maxRequests: Int? = nil,
                contactKeys: [any CNKeyDescriptor] = ContactHistoryFetcher.defaultContactKeys) {
        limiter = RequestLimitedGeocoder(geocoder: geocoder, maxRequests: maxRequests)
        let keys = ContactKeys(contactKeys + [CNContactPostalAddressesKey as CNKeyDescriptor])
        contactActor = ContactActor(geocoder: limiter, contactKeys: keys)
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        if hasAccess {
            Task { await loadContactLocationAnnotations() }
        }
    }

    public static var defaultContactKeys: [any CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactTypeKey as CNKeyDescriptor,
        ]
    }

    /// Shows the system permission prompt if the user hasn't been asked yet, and returns once they have
    /// answered. Returns at once for any other status. `start()` does this itself, so call it only to show
    /// the prompt before the host is ready to sync. It doesn't sync: `start()` does.
    public func requestAccess() async {
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        guard authorizationStatus == .notDetermined else { return }
        // The answer is read from the status, which says more than the granted flag: it tells limited
        // from full access.
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    }

    /// Asks for Contacts access if the user hasn't been asked yet, then syncs now, and again whenever the
    /// contact store changes. Call it once the host is ready to show the system prompt and to sync, for
    /// example once the request limit is set. Calling it again just syncs again.
    ///
    /// It waits for the user's answer before the first sync. If something else in the app already raised
    /// the prompt, for example another `CNContactStore` reading contacts, it waits for that same answer.
    /// If access is denied, nothing syncs.
    ///
    /// The fetcher listens for `CNContactStoreDidChange` from here on. The system delivers a change made
    /// while the app was away once the app is active again, so the host needs no foreground handling.
    /// Each time the app becomes active, addresses that couldn't be looked up earlier (a provider error, or
    /// the request limit) are looked up again, and a sync that stopped early syncs again.
    public func start() async {
        isStarted = true
        // Listening starts before the first sync, so a change arriving in between isn't missed.
        if contactChangeObservation == nil {
            contactChangeObservation = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .CNContactStoreDidChange) {
                    guard let self else { return }
                    await fetchChanges()
                }
            }
        }
        if foregroundObservation == nil {
            foregroundObservation = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                    guard let self else { return }
                    await syncOnActivation()
                }
            }
        }
        await requestAccess()
        await fetchChanges()
    }

    /// Asks Contacts for the changes since the last sync and applies them. Does nothing until
    /// access has been granted. `start()` already does this on every contact change; call it directly
    /// only to sync at another moment.
    ///
    /// If the network goes down mid-sync, the sync stops without saving the history token, so the next
    /// sync reads the same changes again. A sync that stopped early, for example offline, tries again by itself
    /// the next time the app becomes active, and one that stopped because every provider was rate limited tries
    /// again when the providers' cooldown is over. Both need `start()` to have been called.
    /// Calls that overlap are folded together: a call made during a sync returns at once, and the
    /// running sync reads the changes again straight afterwards.
    public func fetchChanges() async {
        // Access can be granted through another CNContactStore, which this fetcher wouldn't otherwise see.
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        guard hasAccess else { return }
        await requestSync()
    }

    public func fetchBy(_ postalAddress: CNLabeledValue<CNPostalAddress>, contact: CNContact) -> ContactLocationAnnotation? {
        contactLocationAnnotations.first(where: { $0.contact == contact && $0.labeledAddress == postalAddress })
    }

    /// Geocodes with the given geocoder from the next address on, including in a sync that is
    /// running. Locations already stored are kept, and the request count carries over.
    public func setGeocoder(_ geocoder: any Geocoder) async {
        await limiter.setGeocoder(geocoder)
    }

    /// Like `setGeocoder(_:)`, with the MapKit, Mapsi and Google chain the matching init builds.
    public func setGeocoder(mapsiAPIKey: String? = nil,
                            googleAPIKey: String? = nil,
                            includesMapKit: Bool = true) async {
        await setGeocoder(GeocoderFactory.makeDefault(mapsiAPIKey: mapsiAPIKey,
                                                      googleAPIKey: googleAPIKey,
                                                      includesMapKit: includesMapKit))
    }

    /// Forgets every stored location, starts the request count from zero and geocodes every
    /// contact again. If a sync is running, it stops after the contact it is on and the new one
    /// starts then, which may be after this returns.
    /// Until `start()` has been called and access has been granted, nothing is cleared or geocoded:
    /// the reset waits for the first sync.
    public func reset() async {
        await limiter.resetCount()
        hasReachedRequestLimit = false
        startOver = true
        await syncIfReady()
    }

    /// Changes the request limit, for example when the user subscribes. Addresses skipped under the old
    /// limit are looked up now if the new one lets them through; addresses that already have an answer
    /// are not looked up again, and nothing stored is cleared.
    /// Until `start()` has been called and access has been granted, nothing is geocoded: the skipped
    /// addresses are looked up from the first sync.
    public func setMaxRequests(_ maxRequests: Int?) async {
        guard await limiter.setMaxRequests(maxRequests) else { return }
        hasReachedRequestLimit = false
        needsRetryPass = true
        await syncIfReady()
    }

    // MARK: - Private API

    private var hasAccess: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    /// For calls that aren't asking for a sync themselves, so they can't start one before the host is ready.
    private func syncIfReady() async {
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        guard isStarted, hasAccess else { return }
        await requestSync()
    }

    /// Looks up again the addresses that couldn't be asked, and syncs if the last pass stopped early or
    /// access has been granted since the fetcher last looked, for example by a prompt that just closed.
    private func syncOnActivation() async {
        let hadAccess = hasAccess
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        guard hasAccess else { return }
        needsRetryPass = true
        if retryWhenActive || !hadAccess { needsAnotherFetch = true }
        await runSync()
    }

    private func requestSync() async {
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

        while startOver || needsAnotherFetch || needsRetryPass {
            if startOver {
                startOver = false
                await contactActor.saveToken(nil)
                await contactActor.removeAll()
                contactLocationAnnotations = []
                ungeocodedAddresses = []
                continue
            }
            if needsAnotherFetch {
                needsAnotherFetch = false
                await fetchChangesOnce()
                continue
            }
            needsRetryPass = false
            await retryPendingOnce()
        }
    }

    /// Stops after the current contact once a clear has been asked for, so no more geocoding
    /// requests are spent on work the clear will throw away.
    private func fetchChangesOnce() async {
        // This pass replaces any retry that is still waiting.
        cooldownRetry?.cancel()
        cooldownRetry = nil
        retryWhenActive = false

        let startingToken = await contactActor.savedToken()
        let token: Data?
        let changes: [ContactHistoryChange]

        do {
            (token, changes) = try await Self.fetchHistory(startingToken: startingToken)
        } catch {
            Logger.contacts.error("Contacts history fetch failed: \(logDescription(of: error), privacy: .public)")
            if startingToken != nil {
                await contactActor.saveToken(nil)
                needsAnotherFetch = true
            } else {
                syncError = .contactsUnreadable(underlying: error)
                retryWhenActive = true
            }
            return
        }
        syncError = nil

        defer { syncProgress = nil }

        // Changes are idempotent, so after a pause the same history is simply applied again.
        for (index, change) in changes.enumerated() {
            do {
                try await contactActor.apply(change)
            } catch {
                pause(after: error)
                await loadContactLocationAnnotations()
                return
            }
            syncProgress = Double(index + 1) / Double(changes.count)
            guard !startOver else { return }
        }

        await contactActor.saveToken(token)

        // When nothing has been published yet, the stored list is published.
        if !changes.isEmpty || contactLocationAnnotations.isEmpty {
            await loadContactLocationAnnotations()
        }
        let hasRefusedRequests = await limiter.hasRefusedRequests
        if hasRefusedRequests, !hasReachedRequestLimit {
            Logger.geocoding.info("Request limit reached, skipping addresses until it is raised")
        }
        hasReachedRequestLimit = hasRefusedRequests
    }

    /// Looks up again the addresses that couldn't be asked earlier. Stops, like a history pass, when the
    /// device is offline, the providers are rate limited or the task is cancelled.
    private func retryPendingOnce() async {
        do {
            if try await contactActor.retryPending() {
                await loadContactLocationAnnotations()
            }
        } catch {
            pause(after: error)
            return
        }
        hasReachedRequestLimit = await limiter.hasRefusedRequests
    }

    /// A pass that stopped early syncs again the next time the app becomes active, and after the providers'
    /// cooldown if they were rate limited.
    private func pause(after error: GeocodingError) {
        retryWhenActive = true
        if error == .rateLimited { retryAfterCooldown() }
    }

    /// Every provider is rate limited and skipped for `providerCooldown`, so asking sooner would only be refused.
    private func retryAfterCooldown() {
        cooldownRetry?.cancel()
        cooldownRetry = Task { [weak self] in
            do { try await Task.sleep(for: providerCooldown) } catch { return }
            guard let self else { return }
            // Cleared first: the sync below must not cancel the task it is running on.
            cooldownRetry = nil
            needsRetryPass = true
            await fetchChanges()
        }
    }

    /// If the contacts can't be read, keeps what is on the map rather than blanking it.
    private func loadContactLocationAnnotations() async {
        do {
            contactLocationAnnotations = try await contactActor.fetchAll()
        } catch {
            Logger.contacts.error("Contact fetch failed: \(logDescription(of: error), privacy: .public)")
        }
        do {
            ungeocodedAddresses = try await contactActor.fetchFailedAddresses(extraKeys: ContactKeys([CNContactViewController.descriptorForRequiredKeys()]))
        } catch {
            Logger.contacts.error("Ungeocoded address fetch failed: \(logDescription(of: error), privacy: .public)")
        }
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
            event.accept(visitor)
        }

        // Save the result's token as stated in the CNContactStore documentation:
        // when fetching change history events, use the token on CNFetchResult.
        return (result.currentHistoryToken, visitor.changes)
    }
}
