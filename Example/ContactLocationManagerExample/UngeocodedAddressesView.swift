//
//  UngeocodedAddressesView.swift
//  ContactLocationManagerExample
//

import SwiftUI
import ContactLocationManager

/// The addresses no provider could find. Tapping one opens its contact, so the address can be corrected.
/// Saving the contact makes the fetcher look the address up again, and it leaves the list if it now matches.
struct UngeocodedAddressesView: View {
    let fetcher: ContactHistoryFetcher
    @Environment(\.dismiss) private var dismiss
    @State private var editing: UngeocodedAddress?

    var body: some View {
        NavigationStack {
            List(fetcher.ungeocodedAddresses) { address in
                Button {
                    editing = address
                } label: {
                    VStack(alignment: .leading) {
                        Text(address.title ?? "No name")
                        Text(address.subtitle ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
            .overlay {
                if fetcher.ungeocodedAddresses.isEmpty {
                    ContentUnavailableView("All addresses found", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("Addresses Not Found")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
            .sheet(item: $editing) { address in
                ContactEditor(contact: address.contact) { editing = nil }
            }
        }
    }
}
