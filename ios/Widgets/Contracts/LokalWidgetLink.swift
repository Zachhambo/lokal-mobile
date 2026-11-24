import Foundation

/// Links carry an opaque recording alias and a bounded source timestamp.
/// Absolute play/pause actions cannot accidentally toggle a newer state.
enum LokalWidgetLink {
  /// A Link URL belongs to a rendered snapshot, not to one tap. Assign the
  /// invocation identity at OS URL ingress; inbox redelivery retains this URL.
  static func invocation(_ url: URL) -> URL? {
    guard url.scheme == "konnekted", url.host == "widget",
          url.absoluteString.utf8.count <= 2048,
          var value = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    var items = (value.queryItems ?? []).filter { $0.name != "command" }
    if items.isEmpty && (value.path.isEmpty || value.path == "/open") {
      items = [URLQueryItem(name: "revision", value: "0"), URLQueryItem(name: "at", value: "0")]
    }
    items.append(URLQueryItem(name: "command", value: UUID().uuidString.lowercased()))
    value.queryItems = items
    return value.url
  }

  static func url(_ action: String = "open", revision: Int = 0,
                  updatedAtMs: Int = 0, track: String? = nil) -> URL {
    var value = URLComponents()
    value.scheme = "konnekted"
    value.host = "widget"
    value.path = "/" + action
    value.queryItems = [
      URLQueryItem(name: "command", value: UUID().uuidString.lowercased()),
      URLQueryItem(name: "revision", value: String(revision)),
      URLQueryItem(name: "at", value: String(updatedAtMs)),
    ]
    if let track { value.queryItems?.append(URLQueryItem(name: "track", value: track)) }
    return value.url!
  }
}
