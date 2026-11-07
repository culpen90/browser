import WebKit

/// Reads and operates on the main document in a separate WebKit content world.
/// Website scripts cannot see the snapshot tokens or replace the action helpers.
@MainActor
enum WebsiteAgentDOM {
    struct Snapshot: Decodable {
        let url: String
        let title: String
        let text: String
        let elements: [BrowserAgentElement]
        let canScrollUp: Bool
        let canScrollDown: Bool
    }

    private static let world = WKContentWorld.world(name: "BrowserAgent")

    static func snapshot(in view: WKWebView, token: String) async throws -> Snapshot {
        let result = try await evaluate(in: view, operation: "snapshot", token: token)
        guard let json = result as? String else { throw BrowserAgentPageError.unavailable }
        return try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    static func click(_ id: Int, in view: WKWebView, token: String) async throws {
        try await perform(in: view, operation: "click", token: token, id: id)
    }

    static func type(_ text: String, into id: Int, in view: WKWebView, token: String) async throws {
        try await perform(in: view, operation: "type", token: token, id: id, text: text)
    }

    static func scroll(_ pages: Int, in view: WKWebView, token: String) async throws {
        try await perform(in: view, operation: "scroll", token: token, id: pages)
    }

    private static func perform(in view: WKWebView, operation: String, token: String, id: Int,
                                text: String = "") async throws {
        let result = try await evaluate(in: view, operation: operation, token: token, id: id, text: text)
        guard result as? Bool == true else { throw BrowserAgentPageError.changed }
    }

    private static func evaluate(in view: WKWebView, operation: String, token: String, id: Int = 0,
                                 text: String = "") async throws -> Any? {
        try Task.checkCancellation()
        return try await view.callAsyncJavaScript(script, arguments: [
            "operation": operation, "token": token, "id": id, "text": text
        ], in: nil, contentWorld: world)
    }

    private static let script = #"""
    function bounded(value, limit) {
        return value.slice(0, limit).replace(/[\uD800-\uDBFF]$/, "");
    }

    function clean(value) {
        return bounded(value.replace(/\s+/g, " ").trim(), 160);
    }

    function webAddress(value) {
        if (!value) return null;
        try {
            const url = new URL(value, document.baseURI);
            return ["http:", "https:"].includes(url.protocol) && !url.username && !url.password
                && url.href.length <= 4096 ? url.href : null;
        } catch {
            return null;
        }
    }

    function describe(node, id) {
        if (!(node instanceof HTMLElement) || !node.isConnected || node.matches(":disabled") ||
            node.closest("[inert], [aria-hidden=true], [aria-disabled=true]")) return null;
        const rect = node.getBoundingClientRect();
        if (!rect.width || !rect.height) return null;
        const style = getComputedStyle(node);
        if (style.visibility !== "visible" || style.opacity === "0") return null;
        const tag = node.tagName;
        const role = node.getAttribute("role");
        const inViewport = rect.bottom > 0 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth;
        const isScriptedLink = tag === "A" && node.hasAttribute("onclick") && !node.hasAttribute("download");
        const url = tag === "A" && role !== "button" && !isScriptedLink && !node.hasAttribute("download")
            ? webAddress(node.getAttribute("href")) : null;
        let kind;
        if (url) {
            kind = "link";
        } else if (!inViewport) {
            return null;
        } else if (tag === "BUTTON" || isScriptedLink || role === "button" && tag !== "INPUT" && tag !== "TEXTAREA"
                   || tag === "INPUT" && ["button", "submit"].includes(node.type)) {
            kind = "button";
        } else if ((tag === "TEXTAREA" || tag === "INPUT" && ["text", "search"].includes(node.type))
                   && !node.readOnly && !node.matches("[aria-readonly=true]")
                   && !/(password|passcode|credential|secret|token|credit.?card|card.?num|one-time-code|(^|\W)otp(\W|$)|cc-)/i
                       .test([node.autocomplete, node.name, node.id, node.placeholder,
                              node.getAttribute("aria-label")].join(" "))) {
            kind = "input";
        } else {
            return null;
        }
        if (kind !== "link") {
            const x = (Math.max(0, rect.left) + Math.min(innerWidth, rect.right)) / 2;
            const y = (Math.max(0, rect.top) + Math.min(innerHeight, rect.bottom)) / 2;
            if (!node.contains(document.elementFromPoint(x, y))) return null;
        }
        const label = [node.getAttribute("aria-label"),
            node.labels && Array.from(node.labels, label => label.innerText).join(" "),
            node.innerText, node.querySelector("img[alt]")?.alt,
            kind === "button" && tag === "INPUT" && node.value,
            node.placeholder, node.title, url, kind].find(value => value && value.trim());
        return { id, kind, label: clean(label), url };
    }

    function fingerprint(node, entry) {
        return JSON.stringify([entry.kind, entry.label, entry.url, node.tagName, node.type, node.name,
            node.getAttribute("onclick"), node.getAttribute("formaction"), node.getAttribute("formmethod"),
            node.getAttribute("formtarget"), node.form?.action, node.form?.method]);
    }

    function pageText() {
        if (!document.body) return "";
        if (scrollY < 20) return bounded(document.body.innerText, 8000);
        const visible = [];
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let size = 0;
        for (let i = 0, node; i < 4000 && size < 8000 && (node = walker.nextNode()); i++) {
            if (!node.data.trim() || node.parentElement.closest("script, style, textarea, [aria-hidden=true]")) continue;
            if (getComputedStyle(node.parentElement).visibility !== "visible") continue;
            const range = document.createRange();
            range.selectNodeContents(node);
            const rect = range.getBoundingClientRect();
            if (!rect.width || rect.bottom <= 0 || rect.top >= innerHeight) continue;
            const text = bounded(node.data.trim(), 8000 - size);
            visible.push(text);
            size += text.length + 1;
        }
        return visible.join("\n") || bounded(document.body.innerText, 8000);
    }

    if (operation === "snapshot") {
        const candidates = document.querySelectorAll("a[href], button, input, textarea, [role=button]");
        const nearby = [];
        for (let index = 0; index < Math.min(candidates.length, 6000); index++) {
            const node = candidates[index];
            const entry = describe(node, index + 1);
            if (!entry) continue;
            const rect = node.getBoundingClientRect();
            nearby.push({ node, entry, distance: Math.max(0, -rect.bottom, rect.top - innerHeight) });
        }
        nearby.sort((a, b) => a.distance - b.distance);
        const targets = nearby.slice(0, 64);
        globalThis.agentSnapshot = {
            token, url: location.href,
            targets: new Map(targets.map(({node, entry}) => [entry.id, {node, key: fingerprint(node, entry)}]))
        };
        const scrolling = document.scrollingElement;
        return JSON.stringify({ url: location.href, title: bounded(document.title, 200),
            text: pageText(), elements: targets.map(target => target.entry), canScrollUp: scrollY > 1,
            canScrollDown: !!scrolling && scrolling.scrollHeight - scrolling.clientHeight - scrollY > 1 });
    }

    const snapshot = globalThis.agentSnapshot;
    if (!snapshot || snapshot.token !== token || snapshot.url !== location.href) return false;
    if (operation === "scroll") {
        scrollBy({ top: id * innerHeight * 0.85, behavior: "instant" });
        return true;
    }
    const target = snapshot.targets.get(id);
    if (!target) return false;
    const node = target.node;
    const entry = describe(node, id);
    if (!entry || target.key !== fingerprint(node, entry)) return false;
    if (operation === "click" && entry.kind === "link") {
        location.assign(entry.url);
    } else if (operation === "click" && entry.kind === "button") {
        node.click();
    } else if (operation === "type" && entry.kind === "input") {
        node.focus({ preventScroll: true });
        const focused = describe(node, id);
        if (!focused || target.key !== fingerprint(node, focused)) return false;
        const prototype = node.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(prototype, "value").set.call(node, text);
        node.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
        node.dispatchEvent(new Event("change", { bubbles: true }));
    } else {
        return false;
    }
    delete globalThis.agentSnapshot;
    return true;
    """#
}
