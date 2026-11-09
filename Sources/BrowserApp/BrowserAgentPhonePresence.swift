import Foundation

/// A phone's authenticated outbound heartbeat lets this Mac select it even when
/// the phone cannot accept incoming internet connections. Nothing leaves these peers.
@MainActor
final class BrowserAgentPhonePresence {
    static let shared = BrowserAgentPhonePresence()

    struct Phone: Identifiable {
        let id: String
        var name: String
        var lastSeen: Date
    }

    var onChange: (() -> Void)?

    private struct Attachment {
        let token: String
        let assignedAt: Date
    }
    private struct Entry {
        var phone: Phone
        var attachment: Attachment?
    }

    private let now: () -> Date
    private var entries: [String: Entry] = [:]
    private static let presenceLifetime: TimeInterval = 30
    private static let attachmentLifetime: TimeInterval = 90
    private static let maximumPhones = 64

    init(now: @escaping () -> Date = { Date() }) { self.now = now }

    var phones: [Phone] {
        let date = now()
        prune(at: date)
        return entries.values.map(\.phone).filter { isActive($0, at: date) }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// The model-sharing endpoint authenticates the message before calling this.
    /// A token remains pending for 90 seconds so a reconnecting phone can receive it.
    func heartbeat(id: String, name: String) throws -> String? {
        let identity = try Self.validID(id)
        let name = try Self.validName(name)
        let date = now()
        prune(at: date)
        let old = entries[identity]
        if old == nil, entries.count >= Self.maximumPhones {
            // A disappeared phone may retain a pending token; an active phone wins
            // that bounded slot instead of allowing unbounded stale state to grow.
            if let expired = entries.values.filter({ !isActive($0.phone, at: date) })
                .min(by: { $0.phone.lastSeen < $1.phone.lastSeen }) {
                entries.removeValue(forKey: expired.phone.id)
            } else { throw PresenceError.full }
        }
        let changed = old == nil || old?.phone.name != name || old.map { !isActive($0.phone, at: date) } == true
        var entry = old ?? Entry(phone: Phone(id: identity, name: name, lastSeen: date))
        entry.phone.name = name
        entry.phone.lastSeen = date
        entries[identity] = entry
        if changed { onChange?() }
        return entry.attachment?.token
    }

    func attach(_ id: String) throws {
        let identity = try Self.validID(id)
        let date = now()
        prune(at: date)
        guard var entry = entries[identity], isActive(entry.phone, at: date) else { throw PresenceError.offline }
        entry.attachment = Attachment(token: UUID().uuidString.lowercased(), assignedAt: date)
        entries[identity] = entry
        onChange?()
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        onChange?()
    }

    private func isActive(_ phone: Phone, at date: Date) -> Bool {
        max(0, date.timeIntervalSince(phone.lastSeen)) < Self.presenceLifetime
    }

    private func prune(at date: Date) {
        for (id, var entry) in entries {
            if let attachment = entry.attachment,
               max(0, date.timeIntervalSince(attachment.assignedAt)) >= Self.attachmentLifetime {
                entry.attachment = nil
            }
            if !isActive(entry.phone, at: date), entry.attachment == nil { entries.removeValue(forKey: id) }
            else { entries[id] = entry }
        }
    }

    private static func validID(_ value: String) throws -> String {
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value) else { throw PresenceError.invalidPhone }
        return uuid.uuidString.lowercased()
    }

    private static func validName(_ value: String) throws -> String {
        guard value.utf8.count <= 200,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }) else { throw PresenceError.invalidPhone }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PresenceError.invalidPhone }
        return name
    }

    private enum PresenceError: LocalizedError {
        case invalidPhone, offline, full
        var errorDescription: String? {
            switch self {
            case .invalidPhone: return "The phone sent an invalid device identity."
            case .offline: return "This phone is offline. Open Browser on the phone and try again."
            case .full: return "Too many phones are currently connected. Try again after a phone disconnects."
            }
        }
    }
}
