import Foundation

/// Links carry an opaque recording alias and a bounded source timestamp.
/// Absolute play/pause actions cannot accidentally toggle a newer state.
enum LokalWidgetLink {
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
