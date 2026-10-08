//
//  ContactHistoryFetcher.swift
//  ContactLocationManager
//
//  Created by Marco Abundo on 10/8/26.
//

// Source - https://stackoverflow.com/a/75860924
// Posted by AnderCover, modified by community. See post 'Timeline' for change history
// Retrieved 2026-10-08, License - CC BY-SA 4.0

import Combine
@preconcurrency import Contacts
import ContactsChangeHistory

@MainActor
final class ContactHistoryFetcher: ObservableObject {
    @Published private(set) var contactLocations: [ContactLocationSnapshot] = []
    
    private let savedTokenUserDefaultsKey = "CNContactHistoryChangeHistoryToken"
    private let contactActor = ContactActor.shared

    private var savedToken: Data? {
        get {
            UserDefaults.standard.data(forKey: savedTokenUserDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: savedTokenUserDefaultsKey)
        }
    }

    private var cancellables: Set<AnyCancellable> = []

    /// Observes `CNContactStoreDidChange` to respond to changes while the app is running,
    /// for example if a contact has been changed on another device.
    func bind() {
        NotificationCenter.default
            .publisher(for: .CNContactStoreDidChange)
            .sink { [weak self] _ in
                Task { await self?.fetchChanges() }
            }
            .store(in: &cancellables)
    }
    
    func reset() async {
        savedToken = nil
        await contactActor.removeAll()
        contactLocations = []
    }

    func fetchChanges() async {
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
        // We only need the full name for this simple use case
        fetchHistoryRequest.additionalContactKeyDescriptors = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
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
