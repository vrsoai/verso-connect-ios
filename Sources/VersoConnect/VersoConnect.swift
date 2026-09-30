import Foundation
import UIKit

/// Verso Connect for iOS.
///
/// Presents the provider's login (ChatGPT) inside the app, in a WebView that
/// behaves like Safari — native keyboard, autofill, provider sign-in buttons —
/// then hands the captured session to Verso. Your backend signs the link with
/// `signLink()` from `@versoai/core`; the app only presents it.
///
/// ```swift
/// let result = try await VersoConnect.present(link: url, from: self)
/// print(result.connectionId)
/// ```
public enum VersoConnect {

    /// Verso API base. Override only for testing against another environment.
    public static var baseURL = URL(string: "https://connect.tryverso.ai")!

    public static let version = "0.1.0"

    /// Presents the connect flow modally over `presenter`.
    ///
    /// - Parameters:
    ///   - link: the URL returned by `signLink()` (its `token` query parameter is used),
    ///     or a URL whose last path component is the token.
    ///   - presenter: the view controller to present from.
    ///   - completion: called on the main thread once, after the sheet is dismissed.
    @MainActor
    public static func present(
        link: URL,
        from presenter: UIViewController,
        completion: @escaping (Result<VersoConnection, VersoConnectError>) -> Void
    ) {
        guard let token = token(from: link) else {
            completion(.failure(.invalidLink))
            return
        }
        let controller = VersoConnectViewController(token: token, api: VersoAPI(baseURL: baseURL), completion: completion)
        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = .fullScreen
        presenter.present(nav, animated: true)
    }

    /// Async variant of `present(link:from:completion:)`.
    @MainActor
    public static func present(link: URL, from presenter: UIViewController) async throws -> VersoConnection {
        try await withCheckedThrowingContinuation { continuation in
            present(link: link, from: presenter) { result in
                continuation.resume(with: result)
            }
        }
    }

    static func token(from link: URL) -> String? {
        if let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
           let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
           !token.isEmpty {
            return token
        }
        let last = link.lastPathComponent
        return last.split(separator: ".").count == 3 ? last : nil
    }
}

/// A connection created by the flow. Your backend also receives the
/// `connection.created` webhook with the same id and your `userRef`.
public struct VersoConnection: Equatable {
    public let connectionId: String
}

public enum VersoConnectError: Error, LocalizedError {
    /// The link carries no token.
    case invalidLink
    /// The user closed the sheet before finishing.
    case cancelled
    /// Verso refused the link or the session; `message` is the server's error string
    /// (for example "This link has already been used" or the duplicate-account message).
    case rejected(status: Int, message: String)
    /// The session was never usable within the allowed time.
    case timedOut
    /// A network problem talking to Verso.
    case network(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidLink: return "The connect link carries no token."
        case .cancelled: return "The user cancelled."
        case .rejected(_, let message): return message
        case .timedOut: return "The provider session was not ready in time."
        case .network(let error): return error.localizedDescription
        }
    }
}
