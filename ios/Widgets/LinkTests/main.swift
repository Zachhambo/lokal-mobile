import Foundation

let rendered = LokalWidgetLink.url("queue", revision: 12, updatedAtMs: 1000)
let first = LokalWidgetLink.invocation(rendered)!
let second = LokalWidgetLink.invocation(rendered)!
precondition(first != second, "Each OS tap needs a distinct invocation")
let firstItems = URLComponents(url: first, resolvingAgainstBaseURL: false)!.queryItems!
let secondItems = URLComponents(url: second, resolvingAgainstBaseURL: false)!.queryItems!
precondition(firstItems.filter { $0.name == "command" }.count == 1)
precondition(firstItems.filter { $0.name != "command" } == secondItems.filter { $0.name != "command" })
// Durable inbox reads retain the assigned identity; do not call invocation again.
let suite = UserDefaults(suiteName: "lokal-widget-invocation-tests")!
suite.set([first.absoluteString], forKey: "pending")
precondition(suite.stringArray(forKey: "pending") == [first.absoluteString])
suite.removePersistentDomain(forName: "lokal-widget-invocation-tests")
let opened = LokalWidgetLink.invocation(URL(string: "konnekted://widget")!)!
let openedItems = URLComponents(url: opened, resolvingAgainstBaseURL: false)!.queryItems!
precondition(openedItems.contains(URLQueryItem(name: "revision", value: "0")))
precondition(LokalWidgetLink.invocation(URL(string: "https://widget/open")!) == nil)
print("Native widget tap identities and retained delivery identities passed")
