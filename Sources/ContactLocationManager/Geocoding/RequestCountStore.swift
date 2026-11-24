//
//  RequestCountStore.swift
//  ContactLocationManager
//

import Foundation

struct RequestCount: Sendable {
    var count = 0
    /// True once a request has been refused because of the limit, until the limit is raised.
    var refused = false
}

protocol RequestCountStore: Sendable {
    func load() async -> RequestCount
    func save(_ requestCount: RequestCount)
}

/// Keeps the count in the Core Data store with the locations, so a rebuilt store starts counting again too.
struct CoreDataRequestCountStore: RequestCountStore {
    func load() async -> RequestCount {
        let stored = await SkopelosClient.shared.read { context in
            RequestCounter.SK_all(context).first.map { RequestCount(count: Int($0.count), refused: $0.refused) }
        }
        if let stored { return stored }

        // First launch with the store: carry over the count earlier versions kept in UserDefaults.
        let defaults = UserDefaults.standard
        let legacy = RequestCount(count: defaults.integer(forKey: "CNGeocodeRequestCount"),
                                  refused: defaults.bool(forKey: "CNGeocodeRequestsRefused"))
        save(legacy)
        defaults.removeObject(forKey: "CNGeocodeRequestCount")
        defaults.removeObject(forKey: "CNGeocodeRequestsRefused")
        return legacy
    }

    func save(_ requestCount: RequestCount) {
        SkopelosClient.shared.writeSync { context in
            let row = RequestCounter.SK_all(context).first ?? RequestCounter.SK_create(context)
            row.count = Int64(requestCount.count)
            row.refused = requestCount.refused
        }
    }
}
