import Foundation

/// Resolve only an OS-authorized container belonging to Lokal's widget group.
/// A sideload signer may suffix the group ID; its embedded profile carries
/// that mapping. Never substitute the app's private Documents directory.
enum LokalWidgetGroup {
  static func identifier(bundle: Bundle = .main) -> String? {
    guard let configured = bundle.object(forInfoDictionaryKey: "LokalWidgetAppGroup") as? String,
          valid(configured) else { return nil }
    var candidates = [configured]
    if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
       let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024,
       let start = data.range(of: Data("<?xml".utf8)),
       let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
       let profile = try? PropertyListSerialization.propertyList(
         from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
       let entitlements = profile["Entitlements"] as? [String: Any],
       let groups = entitlements["com.apple.security.application-groups"] as? [String] {
      candidates += groups.filter { valid($0) &&
        ($0.hasPrefix(configured + ".") || $0.hasSuffix("." + configured.dropFirst(6))) }.sorted()
    }
    return candidates.first {
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    }
  }

  private static func valid(_ name: String) -> Bool {
    name.utf8.count <= 255 && name.range(
      of: "^group\\.[A-Za-z0-9][A-Za-z0-9.-]+$", options: .regularExpression) != nil
  }
}
