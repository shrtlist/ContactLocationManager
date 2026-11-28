# ContactLocationManager

A Swift package that turns your users' contacts into map coordinates. It watches the Contacts database, geocodes each postal address, stores the results, and publishes them as an observable array your app can show on a map.

- Syncs incrementally using Contacts change history, so only added, updated and deleted contacts are processed.
- Geocodes with MapKit first, then Google, then Mapsi if a provider finds no match or fails.
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

// Once, at launch.
ContactHistoryFetcher.configure(mapsiAPIKey: mapsiKey, googleAPIKey: googleKey)

// Asks for Contacts access if needed, then syncs.
await ContactHistoryFetcher.shared.start(maxRequests: isSubscribed ? nil : 20)
```

There is one fetcher per process. `configure(...)` creates it, and calling it twice, or reading `shared` before it, is a programmer error. `ContactHistoryFetcher` has no public initialiser, so two fetchers can't sync at once. The snippets below write `fetcher` for `ContactHistoryFetcher.shared`.

The fetcher doesn't sync by itself. Call `start(maxRequests:)` when you're ready to show the system prompt and to sync. It takes the request limit, so the first sync can't run under a limit your app hasn't decided yet. If the user hasn't been asked for Contacts access yet, `start(maxRequests:)` shows the prompt and waits for the answer before the first sync; to show the prompt earlier, call `requestAccess()`. It syncs now and again on every contact change, so the host doesn't listen for `CNContactStoreDidChange`. A sync that stopped early, for example because the device was offline, tries again by itself when the app next becomes active. A provider that reports a rate limit is left out for the rest of that sync, with no waiting: the addresses nobody else could answer are remembered and looked up again later. Addresses that couldn't be looked up because of a provider error, a rate limit or the request limit are remembered too, and looked up again each time the app becomes active. If access has already been granted, the locations stored by earlier syncs are published as soon as `configure(...)` has run.

`ContactHistoryFetcher` is `@MainActor` and `@Observable`. Read these properties and react when they change:

| Property | Meaning |
| --- | --- |
| `contactLocationAnnotations: [ContactLocationAnnotation]` | Every geocoded address, as an `MKAnnotation` with `contact`, `labeledAddress`, `coordinate`, `title` (the contact's name) and `subtitle` (the address). Replaced when a sync pass finishes. Use the `contactKeys:` init parameter to choose which contact fields `contact` has loaded. |
| `ungeocodedAddresses: [UngeocodedAddress]` | Addresses no provider could find (a definite "no match"), each with `contact` (ready for `CNContactViewController(for:)`), `labeledAddress`, `title` and `subtitle`. Addresses skipped for another reason, such as being offline or reaching the request limit, aren't listed. Remembered between launches, and replaced when a sync pass finishes. Show a warning button when it isn't empty, list the addresses, and present the tapped contact in `CNContactViewController` with editing allowed: saving the contact makes the next sync look the address up again, and it leaves the list if it now matches. |
| `pendingAddressCount: Int` | Addresses that couldn't be asked yet, because of a provider error, a rate limit or the request limit. They are in neither `contactLocationAnnotations` nor `ungeocodedAddresses`, and are looked up again by the next sync. Show it, for example, as "Waiting to retry". |
| `authorizationStatus: CNAuthorizationStatus` | The current Contacts permission. |
| `syncProgress: Double?` | 0...1 while contacts are being processed, `nil` when idle. Counts contacts, not addresses. |
| `hasReachedRequestLimit: Bool` | True when addresses were skipped because the request limit was reached. |
| `syncError: ContactSyncError?` | Why the fetcher couldn't read Contacts the last time it asked for changes (`.contactsUnreadable(underlying:)`), or `nil` if it could. Denied access isn't an error: read `authorizationStatus` for that. |

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

Pass `maxRequests` to `start(maxRequests:)` to cap how many addresses the package will ever geocode, or `nil` for no cap:

```swift
await fetcher.start(maxRequests: isSubscribed ? nil : 20)
```

- The count is saved across launches in the same Core Data store as the locations, so a store that has to be rebuilt starts counting again too. Only `reset()` sets it back to zero. One address is one request, even if it falls through several providers. A request that fails with an error is not counted.
- Once the cap is reached the remaining addresses are skipped without calling any provider, and `hasReachedRequestLimit` becomes true. The skipped addresses are remembered, so `setMaxRequests(_:)` with a higher limit (or `nil`) looks up only those; addresses that already have an answer are not looked up again and nothing stored is cleared. Showing an alert or a paywall is up to your app.
- Call `await fetcher.setMaxRequests(nil)` (or a larger number) to change the cap, for example when the user subscribes. If addresses had been skipped and the new cap lets them through, only those are looked up; nothing stored is cleared.

### Starting over

`await fetcher.reset()` clears the sync token and the stored locations, sets the request count back to zero, and geocodes every contact again. Because the count starts over, a user under a cap gets the full allowance again.

### Custom geocoders

The providers (MapKit, Google, Mapsi) and the failover between them are internal. The only public pieces are the `Geocoder` protocol and `GeocodingError`. `coordinate(for:)` returns `nil` for no match and throws a `GeocodingError` (`rateLimited`, `requestLimitReached`, `unavailable`, `unauthorized`, `invalidRequest`, `cancelled` or `offline`), declared as typed throws. Internally, the failover tries every provider on every error except `invalidRequest` and `offline`, and leaves a provider out for the rest of the sync after it reports `rateLimited`. While one is left out, an address the others can't find is kept for a later retry, not recorded as no match. A geocoder of your own that throws `rateLimited` is treated the same way: the address is retried later.

To make the fetcher use your own geocoder instead, for example a mock in tests, pass anything that conforms to `Geocoder` to `configure` instead of keys:

```swift
ContactHistoryFetcher.configure(geocoder: MyGeocoder())
```

To change the geocoder after `configure(...)`, call `await fetcher.setGeocoder(_:)` with your own, or `await fetcher.setGeocoder(mapsiAPIKey:googleAPIKey:includesMapKit:)` for the built-in providers. It applies from the next request on; the request count and limit carry over. Both `configure` and `setGeocoder` take `includesMapKit: false` to leave MapKit out, for example to test another provider alone.

## How it works

1. When the host calls `start(maxRequests:)`, and on every `CNContactStoreDidChange` after that, the fetcher asks Contacts for the changes since its saved history token.
2. Each added or updated contact has its postal addresses geocoded. Deleted contacts have their locations removed.
3. Results are written to the store, then `contactLocationAnnotations` is refreshed from it. The token is saved once the changes have been applied.
4. If the network drops while geocoding (for example `NSURLErrorNotConnectedToInternet`), the sync stops without saving the token. The next sync starts again from the saved token. Changes are idempotent, so ones applied before the pause are applied again without duplicating locations, but their addresses are geocoded again and count towards `maxRequests`.

CNContactStore's change-history enumerator can't be called from Swift, so a small Objective-C target (`ContactsChangeHistory`) wraps it.

## Example app

`Example/ContactLocationManagerExample.xcodeproj` is a small SwiftUI app for trying the package without a host app. It uses the package from this checkout, so local changes are picked up without pushing. It asks for Contacts access, runs the sync, and lists each location's name, address and coordinate. It also shows how many contacts and addresses are in the Contacts database, lists the addresses no provider could find so you can correct them, and lets you:

- turn the MapKit, Mapsi and Google geocoders on and off (MapKit can be turned off only while another provider is on),
- switch to a mock geocoder that returns a random coordinate for each address, for when there's no network,
- set a maximum number of requests,
- reset, which clears the stored locations and geocodes every contact again.

Mapsi and Google need keys. Put them in `Example/ContactLocationManagerExample/Keys.plist`, which git ignores, as strings named `MapsiAPIKey` and `GoogleMapsAPIKey`. Without the file the app still runs, using MapKit only.

To run it on a device, choose your team under Signing & Capabilities.

## Known limitations

- **Syncing starts at `start(maxRequests:)`.** Calling `configure(...)` only publishes the locations stored by earlier syncs. `start(maxRequests:)` syncs right away, even with no network connection (a sync that can't geocode pauses and tries again when the app becomes active). Call it once your app knows the network is up if that matters.
- **Free users can reach paid providers.** The keys you pass apply to every request. If MapKit finds no match or fails, the address goes to Google and Mapsi, and still counts as one request. To keep a tier on MapKit only, don't pass it keys.
- **`reset()` and `setMaxRequests(_:)` can return before they take effect.** If a sync is running, it stops after the contact it is on; the new sync starts then, which may be after the call returns. `reset()` clears the stored locations, the sync token and the request count, in one write, at that point; `setMaxRequests(_:)` clears nothing. Otherwise they return once the new sync has finished.
- **Limited Contacts access** (`.limited`) is supported in code but has not been tested.
- **No cache.** Every address is geocoded again after a `reset()`.

## Acknowledgements

The change-history handling is adapted from [this Stack Overflow answer](https://stackoverflow.com/a/75860924) by AnderCover, licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

## License

MIT. See [LICENSE](LICENSE).
