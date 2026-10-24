import Foundation

/// Local history of shares created by this installation. Capped and stored in
/// UserDefaults — no server needed for the "Recent links" menu.
public final class LinkStore {
    private let d: UserDefaults
    private let key = "cliplink.history"
    private static let capacity = 50

    public private(set) var links: [StoredLink] = []

    public init(defaults: UserDefaults = .standard) {
        self.d = defaults
        load()
    }

    public func add(_ link: StoredLink) {
        links.removeAll { $0.token == link.token }
        links.insert(link, at: 0)
        if links.count > Self.capacity {
            links = Array(links.prefix(Self.capacity))
        }
        save()
    }

    public func removeAll() {
        links = []
        save()
    }

    private func load() {
        guard let data = d.data(forKey: key) else { return }
        if let decoded = try? JSONDecoder().decode([StoredLink].self, from: data) {
            links = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(links) else { return }
        d.set(data, forKey: key)
    }
}
