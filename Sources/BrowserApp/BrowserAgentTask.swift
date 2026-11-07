import Foundation

/// Page content may help answer a question, but cannot supply the user's intent to act.
struct BrowserAgentTask {
    let directReply: String?
    private let hasBrowserRequest: Bool
    private let requestsSearch: Bool
    private let requestsNavigation: Bool
    private let asksQuestion: Bool

    init(_ task: String) {
        let words = task.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        switch words {
        case "hola", "hola amigo", "hola amiga", "hola que tal", "buenas", "buenos dias", "buenas tardes", "buenas noches":
            directReply = "¡Hola! ¿En qué puedo ayudarte?"
        case "hi", "hello", "hey", "hi there", "hello there", "hey there", "hello agent", "hi agent",
             "good morning", "good afternoon", "good evening":
            directReply = "Hello! How can I help?"
        case "how are you", "how are you doing", "how s it going", "what s up", "whats up":
            directReply = "I’m ready to help. What would you like to do?"
        case "que tal", "como estas", "hola como estas":
            directReply = "¡Hola! ¿En qué puedo ayudarte?"
        case "gracias", "muchas gracias":
            directReply = "¡De nada!"
        case "thanks", "thank you", "thanks a lot":
            directReply = "You’re welcome!"
        case "help", "what can you do", "how can you help":
            directReply = "I can summarize the current page, answer questions about it, follow links, or search the web. Tell me what you’d like to do."
        case "ayuda", "que puedes hacer":
            directReply = "Puedo resumir la página, responder preguntas sobre ella, seguir enlaces o buscar en la web. Dime qué te gustaría hacer."
        default:
            directReply = nil
        }

        func contains(_ pattern: String) -> Bool {
            task.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        requestsSearch = contains(#"\b(search|look up|find|research|busca|buscar|investiga)\b"#)
        requestsNavigation = contains(#"\b(follow|click|visit|navigate|sigue|haz clic|visita|abre)\b"#) ||
            contains(#"(?:^\s*|[,;.!?]\s*|\b(?:please|then|and|can you|could you|would you)\s+)(?:open|go to)\b"#)
        asksQuestion = contains(#"^\s*(?:what|when|where|who|which|how|why|qué|que|cuándo|cuando|dónde|donde|cómo|como)\b|\?\s*$"#)
        hasBrowserRequest = requestsSearch || requestsNavigation ||
            contains(#"https?://|\b(page|website|webpage|browser|link|links|url|site|web|página|pagina|sitio|enlace|enlaces|navegador)\b"#) ||
            contains(#"\b(summarize|summarise|scroll|back|forward|reload|refresh|fill|type|submit|sign in|log in|resumir|resume|desplaza)\b"#)
    }

    func allowsBrowsing(from pageURL: String) -> Bool {
        directReply == nil && (hasBrowserRequest || asksQuestion && pageURL != "browser:home")
    }

    func allowsSearch(from pageURL: String) -> Bool {
        requestsSearch || requestsNavigation && pageURL == "browser:home"
    }
}
