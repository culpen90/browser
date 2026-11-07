function bounded(value, limit) {
    return String(value || "").slice(0, limit).replace(/[\uD800-\uDBFF]$/, "");
}
function clean(value) { return bounded(String(value || "").replace(/\s+/g, " ").trim(), 160); }
function address(value) {
    try {
        const url = new URL(value, document.baseURI);
        return ["http:", "https:"].includes(url.protocol) && !url.username && !url.password
            && url.href.length <= 4096 ? url.href : null;
    } catch (_) { return null; }
}
function describe(node, id) {
    if (!(node instanceof HTMLElement) || !node.isConnected || node.matches(":disabled")
        || node.closest("[inert], [aria-hidden=true], [aria-disabled=true]")) return null;
    const rect = node.getBoundingClientRect(), style = getComputedStyle(node);
    if (!rect.width || !rect.height || style.visibility !== "visible" || style.opacity === "0") return null;
    const tag = node.tagName, role = node.getAttribute("role");
    const scripted = tag === "A" && node.hasAttribute("onclick") && !node.hasAttribute("download");
    const url = tag === "A" && role !== "button" && !scripted && !node.hasAttribute("download")
        ? address(node.getAttribute("href")) : null;
    const visible = rect.bottom > 0 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth;
    let kind;
    if (url) kind = "link";
    else if (!visible) return null;
    else if (tag === "BUTTON" || scripted || role === "button" && tag !== "INPUT" && tag !== "TEXTAREA"
        || tag === "INPUT" && ["button", "submit"].includes(node.type)) kind = "button";
    else if ((tag === "TEXTAREA" || tag === "INPUT" && ["text", "search"].includes(node.type))
        && !node.readOnly && !node.matches("[aria-readonly=true]")
        && !/(password|passcode|credential|secret|token|credit.?card|card.?num|one-time-code|(^|\W)otp(\W|$)|cc-)/i
            .test([node.autocomplete, node.name, node.id, node.placeholder, node.getAttribute("aria-label")].join(" "))) kind = "input";
    else return null;
    if (kind !== "link") {
        const x = (Math.max(0, rect.left) + Math.min(innerWidth, rect.right)) / 2;
        const y = (Math.max(0, rect.top) + Math.min(innerHeight, rect.bottom)) / 2;
        if (!node.contains(document.elementFromPoint(x, y))) return null;
    }
    const image = node.querySelector("img[alt]");
    const label = [node.getAttribute("aria-label"),
        node.labels && Array.from(node.labels, label => label.innerText).join(" "), node.innerText,
        image && image.alt, kind === "button" && tag === "INPUT" && node.value,
        node.placeholder, node.title, url, kind].find(value => value && String(value).trim());
    return {id, kind, label: clean(label), url};
}
function signature(node, entry) {
    return JSON.stringify([entry.kind, entry.label, entry.url, node.tagName, node.type, node.name,
        node.getAttribute("onclick"), node.getAttribute("formaction"), node.getAttribute("formmethod"),
        node.getAttribute("formtarget"), node.form && node.form.action, node.form && node.form.method]);
}
function selector(node) {
    const parts = [];
    for (let depth = 0; node && depth < 32; depth++, node = node.parentElement) {
        let index = 1;
        for (let sibling = node.previousElementSibling; sibling; sibling = sibling.previousElementSibling)
            if (sibling.tagName === node.tagName) index++;
        parts.unshift(node.tagName.toLowerCase() + ":nth-of-type(" + index + ")");
        if (node === document.documentElement) return parts.join(" > ");
    }
    return null;
}
function pageText() {
    if (!document.body) return "";
    if (scrollY < 20) return bounded(document.body.innerText, 8000);
    const texts = [], walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let size = 0;
    for (let i = 0, node; i < 4000 && size < 8000 && (node = walker.nextNode()); i++) {
        if (!node.data.trim() || node.parentElement.closest("script, style, textarea, [aria-hidden=true]")) continue;
        if (getComputedStyle(node.parentElement).visibility !== "visible") continue;
        const range = document.createRange();
        range.selectNodeContents(node);
        const rect = range.getBoundingClientRect();
        if (!rect.width || rect.bottom <= 0 || rect.top >= innerHeight) continue;
        const text = bounded(node.data.trim(), 8000 - size);
        texts.push(text); size += text.length + 1;
    }
    return texts.join("\n") || bounded(document.body.innerText, 8000);
}
if (operation === "observe") {
    const candidates = document.querySelectorAll("a[href], button, input, textarea, [role=button]"), nearby = [];
    for (let index = 0; index < Math.min(6000, candidates.length); index++) {
        const node = candidates[index], entry = describe(node, index + 1), path = entry && selector(node);
        if (!entry || !path || path.length > 2048) continue;
        entry.selector = path; entry.signature = signature(node, entry);
        const rect = node.getBoundingClientRect();
        nearby.push({entry, distance: Math.max(0, -rect.bottom, rect.top - innerHeight)});
    }
    nearby.sort((a, b) => a.distance - b.distance);
    return JSON.stringify({url: location.href, title: bounded(document.title, 200), text: pageText(),
        elements: nearby.slice(0, 64).map(value => value.entry), canUp: scrollY > 1,
        canDown: Math.ceil(scrollY + innerHeight) < document.documentElement.scrollHeight});
}
if (location.href !== expected.url) return false;
if (operation === "SCROLL") {
    scrollBy({top: expected.id * innerHeight * 0.85, behavior: "instant"});
    return true;
}
const node = document.querySelector(expected.selector), entry = node && describe(node, expected.id);
if (!entry || signature(node, entry) !== expected.signature) return false;
if (operation === "CLICK" && entry.kind === "button") node.click();
else if (operation === "TYPE" && entry.kind === "input") {
    node.focus({preventScroll: true});
    const focused = describe(node, expected.id);
    if (!focused || signature(node, focused) !== expected.signature) return false;
    const prototype = node.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, "value").set.call(node, expected.text);
    node.dispatchEvent(new Event("input", {bubbles: true, composed: true}));
    node.dispatchEvent(new Event("change", {bubbles: true}));
} else return false;
return true;
