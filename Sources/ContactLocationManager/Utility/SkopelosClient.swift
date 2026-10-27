//
//  SkopelosClient.swift
//  Skopelos
//
//  Created by Alberto DeBortoli on 31/07/2016.
//  Copyright © 2016 Alberto De Bortoli. All rights reserved.
//

import CoreData
import OSLog
import Skopelos

extension Skopelos {
    /// Bridges a synchronous `read` onto async/await.
    func read<T>(_ block: @escaping (NSManagedObjectContext) -> T) async -> T {
        await withCheckedContinuation { continuation in
            read { context in
                continuation.resume(returning: block(context))
            }
        }
    }
}

// Skopelos serializes access to its contexts itself, so sharing one client across actors is safe.
final class SkopelosClient: Skopelos, @unchecked Sendable {
    private static let modelURL: URL = {
        guard let modelURL = Bundle.module.url(forResource: "ContactLocationManager", withExtension: "momd") else {
            fatalError("ContactLocationManager.momd is missing from the package bundle")
        }
        return modelURL
    }()

    static let shared = SkopelosClient(sqliteStack: modelURL, allowsConcurrentWritings: false)
    override func handleError(_ error: NSError) {
        // clients should do the right thing here
        Logger.persistence.error("Skopelos error: \(error.localizedDescription, privacy: .public)")
    }
}
