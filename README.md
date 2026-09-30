# VersoConnect for iOS

Lets your users connect their ChatGPT account to [Verso](https://tryverso.ai)
from inside your app. The provider's login opens in a sheet that behaves like
Safari (native keyboard, autofill, password managers, Google sign-in), and the
captured session goes straight to Verso. No hosted browser is involved.

Requirements: iOS 15+, Swift 5.9+, Xcode 15+.

Documentation: [docs.tryverso.ai/guides/mobile-apps](https://docs.tryverso.ai/guides/mobile-apps).

## Install

Swift Package Manager. In Xcode: File › Add Package Dependencies, enter
`https://github.com/vrsoai/verso-connect-ios`, dependency rule "Up to Next
Major Version" from `0.1.0`.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/vrsoai/verso-connect-ios", from: "0.1.0"),
],
targets: [
    .target(name: "YourApp", dependencies: ["VersoConnect"]),
]
```

## Use

Your backend signs a connect link with `signLink()` from `@versoai/core` and
returns its `url` to the app. The app secret never ships in the app.

```swift
import VersoConnect

// From a UIViewController, after fetching `link` from your backend
do {
    let connection = try await VersoConnect.present(link: link, from: self)
    // connection.connectionId; your backend also receives connection.created
} catch VersoConnectError.cancelled {
    // the user closed the sheet
} catch {
    // see Errors below
}
```

A completion-handler form exists for code that is not async:

```swift
VersoConnect.present(link: link, from: self) { result in
    switch result {
    case .success(let connection): print(connection.connectionId)
    case .failure(let error): print(error)
    }
}
```

`present` opens the sheet, waits for the login, captures the session and
dismisses the sheet itself in every case. The link is single use and valid
15 minutes: fetch a fresh one each time the user taps your button. The login
itself must complete within one hour.

## Errors

| `VersoConnectError` | Meaning |
|---|---|
| `invalidLink` | The URL carries no token. |
| `cancelled` | The user closed the sheet. |
| `rejected(status:message:)` | Verso refused: an expired link (401), a link already used (403), or a ChatGPT account already connected by another user of your app (409). Sign a new link. |
| `timedOut` | The provider session never became usable. |
| `network(Error)` | The request to Verso failed. Retry with a new link. |

## What happens

1. The SDK sends the link's token to Verso, which verifies and consumes it
   and answers with the provider's login URL and what to watch for.
2. The login opens in a `WKWebView` with a non-persistent data store and the
   Mobile Safari user agent. Nothing is left on the device afterwards.
3. When the provider's session cookie is present and the session is usable,
   the SDK sends it to Verso, once, over TLS. Verso encrypts it with a key that
   exists only for this connection, creates the connection, sends
   `connection.created` to your backend and starts the first sync.

The SDK never sees your app secret or API key.

## License

MIT.
