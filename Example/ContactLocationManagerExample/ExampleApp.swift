//
//  ExampleApp.swift
//  ContactLocationManagerExample
//
//  Created by Marco Abundo on 10/13/26.
//

import SwiftUI

/// Requests Contacts access and runs the sync, to try the package without a host app.
@main
struct ExampleApp: App {
    @State private var model: ExampleModel

    init() {
        // Once, before anything reads `ContactHistoryFetcher.shared`.
        ExampleModel.configureFetcher()
        _model = State(initialValue: ExampleModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
