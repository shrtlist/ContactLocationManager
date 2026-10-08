//
//  SkopelosClient.swift
//  Skopelos
//
//  Created by Alberto DeBortoli on 31/07/2016.
//  Copyright © 2016 Alberto De Bortoli. All rights reserved.
//

import CoreData
import Skopelos

extension Skopelos {
    /// Bridges a synchronous `read` onto async/await.
    func readAsync<T>(_ block: @escaping (NSManagedObjectContext) -> T) async -> T {
        await withCheckedContinuation { continuation in
            read { context in
                continuation.resume(returning: block(context))
            }
        }
    }
}

final class SkopelosClient: Skopelos {

    nonisolated(unsafe) static let shared: SkopelosClient = {
        guard let modelURL = Bundle(for: SkopelosClient.self).url(forResource: "ContactLocationManager", withExtension: "momd") else {
            fatalError("ContactLocationManager.momd is missing from the app bundle")
        }

        return SkopelosClient(sqliteStack: modelURL, allowsConcurrentWritings: false)
    }()

    override func handleError(_ error: NSError) {
        // clients should do the right thing here
        NSLog("\(#function) \(error.localizedDescription)")
    }
}
