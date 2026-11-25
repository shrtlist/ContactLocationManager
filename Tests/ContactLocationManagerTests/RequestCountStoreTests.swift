import Testing
@testable import ContactLocationManager

extension SharedStoreTests {
    /// Uses the shared store, so it puts the count back to zero afterwards.
    @Suite struct RequestCountStoreTests {
        @Test func theCountIsKeptInTheStore() async {
            let store = CoreDataRequestCountStore()

            store.save(RequestCount(count: 3, refused: true))
            let loaded = await store.load()
            store.save(RequestCount())

            #expect(loaded.count == 3)
            #expect(loaded.refused)
        }
    }
}
