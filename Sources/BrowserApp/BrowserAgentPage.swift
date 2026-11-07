import Foundation

struct BrowserAgentPage {
    let url: String
    let title: String
    let text: String
    let elements: [BrowserAgentElement]
    let canGoBack: Bool
    let canScrollUp: Bool
    let canScrollDown: Bool
    let windowID: UUID
    let generation: Int
    let observationID: UUID
    let websiteRevision: Int?

    var compatibilityMode: Bool { websiteRevision != nil }

    func approvalDescription(for action: BrowserAgentPageAction) -> String? {
        let site = URL(string: url)?.host ?? "this page"
        switch action {
        case .click(let id):
            guard let element = elements.first(where: { $0.id == id }), element.kind == .button else { return nil }
            return "Click “\(element.label)” on \(site)?"
        case .type(let id, let value):
            guard let element = elements.first(where: { $0.id == id }), element.kind == .input else { return nil }
            return "Enter this text into “\(element.label)” on \(site)?\n\n\(value)"
        default:
            return nil
        }
    }
}

struct BrowserAgentElement: Decodable {
    enum Kind: String, Decodable {
        case link, button, input
    }

    let id: Int
    let kind: Kind
    let label: String
    let url: String?
}

enum BrowserAgentPageAction {
    case navigate(URL)
    case click(Int)
    case type(Int, String)
    case back
    case scroll(Int)
    case enableCompatibility
}

enum BrowserAgentPageError: LocalizedError {
    case stillLoading
    case changed
    case unavailable
    case unsupportedAddress
    case invalidAction
    case approvalRequired

    var errorDescription: String? {
        switch self {
        case .stillLoading: return "The page is still loading. Try again after it finishes."
        case .changed: return "The page changed. Read it again before trying another action."
        case .unavailable: return "The browser couldn’t read this page."
        case .unsupportedAddress: return "The agent can only navigate to HTTP and HTTPS addresses."
        case .invalidAction: return "That action is unavailable on this page."
        case .approvalRequired: return "Approve this website action before it runs."
        }
    }
}
