# VersoConnect for iOS

Lets your users connect their ChatGPT account to Verso from inside your app:
the provider's login opens in a WebView that behaves like Safari (native
keyboard, autofill, sign-in buttons), and the captured session goes to Verso.

Requirements: iOS 15+, Swift 5.9+.

## Install

Swift Package Manager: add this package (`sdks/ios/VersoConnect` of the
verso-fetch repository, or the published package URL once it exists).

## Use

Your backend signs a connect link with `signLink()` from `@versoai/core`
and returns it to the app. Then:

```swift
import VersoConnect

// From a UIViewController, after fetching `link` from your backend
do {
    let connection = try await VersoConnect.present(link: link, from: self)
    // connection.connectionId — your backend also receives connection.created
} catch VersoConnectError.cancelled {
    // user closed the sheet
} catch {
    // VersoConnectError.rejected(status:message:) for a used link or a
    // ChatGPT account already connected by another user; .network otherwise
}
```

The sheet is dismissed by the SDK in every case. The link is single use and
valid 15 minutes: fetch a fresh one each time the user taps your button.
