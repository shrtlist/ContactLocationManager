//
//  ContentView.swift
//  ContactLocationManagerExample
//
//  Created by Marco Abundo on 10/13/26.
//

import SwiftUI
import Contacts
import ContactLocationManager

struct ContentView: View {
    @Bindable var model: ExampleModel

    private var fetcher: ContactHistoryFetcher { model.fetcher }
    private var isSyncing: Bool { fetcher.syncProgress != nil }

    var body: some View {
        NavigationStack {
            List {
                Section("Contacts") {
                    LabeledContent("Access", value: description(of: fetcher.authorizationStatus))
                    if fetcher.authorizationStatus == .notDetermined {
                        Button("Request Contacts Access") {
                            Task { await fetcher.requestAccess() }
                        }
                    }
                    LabeledContent("Contacts", value: model.contactCount.map(String.init) ?? "–")
                    LabeledContent("Addresses", value: model.addressCount.map(String.init) ?? "–")
                }

                Section {
                    LabeledContent("MapKit", value: "Always first")
                    // Shown off when there's no key, whatever the saved setting.
                    Toggle("Mapsi", isOn: Binding(get: { model.usesMapsi && model.mapsiAPIKey != nil },
                                                  set: { model.usesMapsi = $0 }))
                        .disabled(model.mapsiAPIKey == nil || isSyncing)
                    Toggle("Google", isOn: Binding(get: { model.usesGoogle && model.googleAPIKey != nil },
                                                   set: { model.usesGoogle = $0 }))
                        .disabled(model.googleAPIKey == nil || isSyncing)
                    Toggle("Limit requests", isOn: $model.limitsRequests)
                    if model.limitsRequests {
                        Stepper("Max requests: \(model.maxRequests)", value: $model.maxRequests, in: 0...10_000)
                    }
                    if fetcher.isRateLimited {
                        Text("Request limit reached")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Geocoding")
                } footer: {
                    Text("Mapsi and Google need keys in Keys.plist. Providers can't be switched during a sync, and only affect addresses geocoded from then on; reset to geocode everything again.")
                }

                Section("Sync") {
                    if let progress = fetcher.syncProgress {
                        ProgressView(value: progress)
                    }
                    LabeledContent("Locations", value: "\(fetcher.contactLocationAnnotations.count)")
                    Button("Reset and Geocode Again", role: .destructive) {
                        Task { await fetcher.reset() }
                    }
                }

                Section("Locations") {
                    ForEach(fetcher.contactLocationAnnotations, id: \.self) { annotation in
                        VStack(alignment: .leading) {
                            Text(annotation.title ?? "No name")
                            Text(annotation.subtitle ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(annotation.coordinate.latitude), \(annotation.coordinate.longitude)")
                                .font(.caption2)
                        }
                    }
                }
            }
            .navigationTitle("Example")
            .task(id: fetcher.authorizationStatus) {
                await model.refreshCounts()
            }
            .task {
                for await _ in NotificationCenter.default.notifications(named: .CNContactStoreDidChange) {
                    await model.refreshCounts()
                }
            }
        }
    }

    private func description(of status: CNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "Not determined"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorized: "Authorized"
        case .limited: "Limited"
        @unknown default: "Unknown"
        }
    }
}
