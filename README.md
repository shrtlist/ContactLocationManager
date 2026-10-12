# ContactLocationManager

A Swift package that turns your users' contacts into map coordinates. It watches the Contacts database, geocodes each postal address, stores the results, and publishes them as an observable array your app can show on a map.

- Syncs incrementally using Contacts change history, so only added, updated and deleted contacts are processed.
- Geocodes with MapKit first, then Mapsi, then Google if a provider finds no match or fails.
- Keeps results in a local Core Data store (via [Skopelos](https://github.com/albertodebortoli/Skopelos)).
- Exposes plain `@Observable` properties, so UIKit and SwiftUI hosts react to changes the same way.
- Lets the host cap the number of geocoding requests, for example for a free tier.

## Requirements

- iOS 26
- Swift 6.3 / Xcode 26

## Installation

Add the package in Xcode (File > Add Package Dependencies) with the URL

```
https://github.com/shrtlist/ContactLocationManager
```

or in `Package.swift`:

```swift
.package(url: "https://github.com/shrtlist/ContactLocationManager", branch: "main")
```

then add the `ContactLocationManager` product to your target.

## Host app setup

- Add `NSContactsUsageDescription` to your app's Info.plist. The system shows it in the Contacts prompt.
- API keys for Mapsi and Google are optional and are passed in by your app. The package never reads a plist or the environment. With no keys, MapKit is the only provider.

## Usage

```swift
import ContactLocationManager

let fetcher = ContactHistoryFetcher(mapsiAPIKey: mapsiKey, googleAPIKey: googleKey)

// Show the system prompt when your app is ready for it.
await fetcher.requestAccess()
```

If access has already been granted, the fetcher starts syncing as soon as it is created. Otherwise it starts once `requestAccess()` succeeds.

`ContactHistoryFetcher` is `@MainActor` and `@Observable`. Read these properties and react when they change:

| Property | Meaning |
| --- | --- |
| `contactLocationAnnotations: [ContactLocationAnnotation]` | Every geocoded address, as an `MKAnnotation` with `contact`, `labeledAddress`, `coordinate`, `title` (the contact's name) and `subtitle` (the address). Replaced when a sync pass finishes. Use the `contactKeys:` init parameter to choose which contact fields `contact` has loaded. |
| `authorizationStatus: CNAuthorizationStatus` | The current Contacts permission. |
| `syncProgress: Double?` | 0...1 while contacts are being processed, `nil` when idle. Counts contacts, not addresses. |
| `isRateLimited: Bool` | True when addresses were skipped because the request limit was reached. |

### Observing from UIKit

```swift
Task {
    for await contactLocationAnnotations in Observations({ fetcher.contactLocationAnnotations }) {
        showPins(for: contactLocationAnnotations)
    }
}

Task {
    for await progress in Observations({ fetcher.syncProgress }) {
        progressView.isHidden = progress == nil
        progressView.progress = Float(progress ?? 0)
    }
}
```

On iOS 26, UIKit also tracks properties you read inside `updateProperties()` automatically.

### Limiting requests

Pass `maxRequests` to cap how many addresses the package will ever geocode:

```swift
let fetcher = ContactHistoryFetcher(
    mapsiAPIKey: mapsiKey,
    googleAPIKey: googleKey,
    maxRequests: isSubscribed ? nil : 20
)
```

- The count is saved across launches. One address is one request, even if it falls through several providers. A request that fails with an error is not counted.
- Once the cap is reached the remaining addresses are skipped without calling any provider, and `isRateLimited` becomes true. Showing an alert or a paywall is up to your app.
- Call `await fetcher.setMaxRequests(nil)` (or a larger number) to change the cap, for example when the user subscribes. If addresses had been skipped and the new cap lets them through, the package clears its stored locations and sync token and geocodes everything again.

### Starting over

`await fetcher.reset()` clears the sync token and the stored locations. The next change to the Contacts database, or the next launch, syncs everything again.

### Using the geocoders on their own

`MapKitGeocoder`, `MapsiGeocoder`, `GoogleGeocoder` and `FailoverGeocoder` are public and conform to the `Geocoder` protocol, so you can geocode an address without the rest of the package:

```swift
let geocoder = FailoverGeocoder(providers: [MapKitGeocoder(), MapsiGeocoder(apiKey: key)])
let coordinate = try await geocoder.coordinate(for: postalAddress)  // nil if no match
```

`coordinate(for:)` throws a `GeocodingError` (`rateLimited`, `unavailable`, `unauthorized` or `invalidRequest`). `FailoverGeocoder` fails over on every error except `invalidRequest`, and skips a provider for 60 seconds after it reports `rateLimited`.

## How it works

1. The fetcher listens for `CNContactStoreDidChange` and asks Contacts for the changes since its saved history token.
2. Each added or updated contact has its postal addresses geocoded. Deleted contacts have their locations removed.
3. Results are written to the store, then `contactLocationAnnotations` is refreshed from it. The token is saved when the changes have been fetched.

CNContactStore's change-history enumerator can't be called from Swift, so a small Objective-C target (`ContactsChangeHistory`) wraps it.

## Known limitations

- **Failures are not retried.** An address that fails to geocode (offline, provider error, no match) is logged to the console and skipped. The sync token has already moved past it, so it is only tried again after `reset()` or a change to that contact.
- **Syncing starts at creation.** If access is already granted, the fetcher syncs immediately, even with no network connection. Create it once your app knows the network is up if that matters.
- **Free users can reach paid providers.** The keys you pass apply to every request. If MapKit finds no match or fails, the address goes to Mapsi and Google, and still counts as one request. To keep a tier on MapKit only, don't pass it keys.
- **Changing providers needs a new fetcher.** The provider chain is built once, when the fetcher is created.
- **Overlapping syncs are not coordinated.** A second Contacts change that arrives during a long sync can start another sync while the first is running.
- **Limited Contacts access** (`.limited`) is supported in code but has not been tested.
- **No cache.** Every address is geocoded again after a `reset()`.

## Acknowledgements

The change-history handling is adapted from [this Stack Overflow answer](https://stackoverflow.com/a/75860924) by AnderCover, licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

## License

MIT. See [LICENSE](LICENSE).
