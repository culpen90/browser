package com.culpen.browser.engine;

import java.net.URI;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/** Bounded HTML tree builder. It never invokes a platform HTML renderer. */
public final class Html {
    private Html() {}

    public static final class Node {
        /** null for document and text nodes. */
        public final String tag;
        /** Non-null only on text nodes. */
        public final String text;
        public final Map<String, String> attributes;
        public final List<Node> children = new ArrayList<>();
        public Node parent;

        public Node(String tag, String text, Map<String, String> attributes) {
            this.tag = tag;
            this.text = text;
            this.attributes = attributes == null ? new LinkedHashMap<>() : attributes;
        }

        public String textContent() {
            StringBuilder output = new StringBuilder();
            Deque<Node> pending = new ArrayDeque<>();
            pending.push(this);
            while (!pending.isEmpty()) {
                Node node = pending.pop();
                if (node.text != null) output.append(node.text);
                for (int i = node.children.size() - 1; i >= 0; i--) pending.push(node.children.get(i));
            }
            return output.toString();
        }

        public List<Node> descendants(String name) {
            String wanted = name.toLowerCase(Locale.ROOT);
            List<Node> found = new ArrayList<>();
            Deque<Node> pending = new ArrayDeque<>();
            for (int i = children.size() - 1; i >= 0; i--) pending.push(children.get(i));
            while (!pending.isEmpty()) {
                Node node = pending.pop();
                if (wanted.equals(node.tag)) found.add(node);
                for (int i = node.children.size() - 1; i >= 0; i--) pending.push(node.children.get(i));
            }
            return found;
        }
    }

    public static final class Document {
        public final Node root;
        public Document(Node root) { this.root = root; }
        public String title() {
            List<Node> nodes = root.descendants("title");
            return nodes.isEmpty() ? "" : nodes.get(0).textContent().trim().replaceAll("\\s+", " ");
        }
        public Node body() {
            List<Node> nodes = root.descendants("body");
            return nodes.isEmpty() ? root : nodes.get(0);
        }
        public String embeddedStyles() {
            StringBuilder output = new StringBuilder();
            for (Node node : root.descendants("style")) output.append(node.textContent()).append('\n');
            return output.toString();
        }
        public URI baseUrl(URI url) {
            List<Node> nodes = root.descendants("base");
            if (!nodes.isEmpty()) {
                String href = nodes.get(0).attributes.get("href");
                if (href != null) {
                    try {
                        URI result = url.resolve(href);
                        if (set("http", "https", "file").contains(lower(result.getScheme()))) return result;
                    } catch (IllegalArgumentException ignored) { }
                }
            }
            return url;
        }
    }

    public static Document parse(String source) { return new Scanner(source == null ? "" : source).parse(); }

    private static final Set<String> VOID_TAGS = set("area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr");
    private static final Set<String> PARAGRAPH_CLOSERS = set("address", "article", "aside", "blockquote", "div", "dl", "fieldset", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "nav", "ol", "p", "pre", "section", "table", "ul");
    private static final Set<String> HEADINGS = set("h1", "h2", "h3", "h4", "h5", "h6");
    private static final Set<String> RAW_TAGS = set("script", "style", "title", "textarea");
    private static final Set<String> DEFINITION_TAGS = set("dt", "dd");
    private static final Set<String> CELL_TAGS = set("td", "th");
    private static final Set<String> OPTIONAL_SEMICOLON = set("amp", "lt", "gt", "quot", "nbsp");

    private static final class Scanner {
        final String input;
        int index;
        int nodeCount = 1;
        final Node root = new Node(null, null, null);
        final List<Node> stack = new ArrayList<>();
        Scanner(String source) {
            input = source.substring(0, Math.min(4_000_000, source.length()));
            stack.add(root);
        }
        Document parse() {
            while (index < input.length() && nodeCount < 80_000) {
                if (input.charAt(index) != '<') {
                    int start = index;
                    while (index < input.length() && input.charAt(index) != '<') index++;
                    appendText(decodeEntities(input.substring(start, index)));
                } else if (matches("<!--", false)) {
                    int end = input.indexOf("-->", index + 4);
                    index = end < 0 ? input.length() : end + 3;
                } else if (matches("<!", false) || matches("<?", false)) {
                    skipTag();
                } else if (matches("</", false)) {
                    index += 2;
                    skipWhitespace();
                    String name = lower(readName());
                    while (index < input.length() && input.charAt(index) != '>') index++;
                    if (index < input.length()) index++;
                    for (int i = stack.size() - 1; i > 0; i--) {
                        if (name.equals(stack.get(i).tag)) { stack.subList(i, stack.size()).clear(); break; }
                    }
                } else if (index + 1 < input.length() && asciiLetter(input.charAt(index + 1))) {
                    parseStartTag();
                } else {
                    appendText("<");
                    index++;
                }
            }
            return new Document(root);
        }
        void parseStartTag() {
            index++;
            String name = lower(readName());
            Map<String, String> attributes = new LinkedHashMap<>();
            boolean selfClosing = false;
            while (index < input.length()) {
                skipWhitespace();
                if (index >= input.length()) break;
                char ch = input.charAt(index);
                if (ch == '>') { index++; break; }
                if (ch == '/' && index + 1 < input.length() && input.charAt(index + 1) == '>') {
                    selfClosing = true; index += 2; break;
                }
                int start = index;
                while (index < input.length() && !Character.isWhitespace(input.charAt(index)) && "=>/".indexOf(input.charAt(index)) < 0) index++;
                if (start == index) { index++; continue; }
                String key = lower(input.substring(start, index));
                skipWhitespace();
                String value = "";
                if (index < input.length() && input.charAt(index) == '=') {
                    index++; skipWhitespace();
                    if (index < input.length() && (input.charAt(index) == '"' || input.charAt(index) == '\'')) {
                        char quote = input.charAt(index++);
                        int valueStart = index;
                        while (index < input.length() && input.charAt(index) != quote) index++;
                        value = input.substring(valueStart, index);
                        if (index < input.length()) index++;
                    } else {
                        int valueStart = index;
                        while (index < input.length() && !Character.isWhitespace(input.charAt(index)) && input.charAt(index) != '>') index++;
                        value = input.substring(valueStart, index);
                    }
                }
                if (!attributes.containsKey(key)) attributes.put(key, decodeEntities(value));
            }
            closeImplicitElements(name);
            Node element = new Node(name, null, attributes);
            append(element);
            if (RAW_TAGS.contains(name)) {
                int start = index;
                while (index < input.length()) {
                    if (matches("</" + name, true)) {
                        int following = index + name.length() + 2;
                        if (following >= input.length() || Character.isWhitespace(input.charAt(following)) || input.charAt(following) == '>') break;
                    }
                    index++;
                }
                String raw = input.substring(start, index);
                String text = name.equals("title") || name.equals("textarea") ? decodeEntities(raw) : raw;
                if (!text.isEmpty() && nodeCount < 80_000) {
                    Node child = new Node(null, text, null);
                    child.parent = element;
                    element.children.add(child);
                    nodeCount++;
                }
                if (index < input.length()) skipTag();
            } else if (!VOID_TAGS.contains(name) && !selfClosing && stack.size() < 256) {
                stack.add(element);
            }
        }
        void closeImplicitElements(String tag) {
            if (PARAGRAPH_CLOSERS.contains(tag)) {
                for (int i = stack.size() - 1; i > 0; i--) {
                    if ("p".equals(stack.get(i).tag)) { stack.subList(i, stack.size()).clear(); break; }
                }
            }
            if (tag.equals("li")) {
                for (int i = stack.size() - 1; i > 0; i--) {
                    String current = stack.get(i).tag;
                    if ("li".equals(current)) { stack.subList(i, stack.size()).clear(); break; }
                    if ("ul".equals(current) || "ol".equals(current)) break;
                }
            }
            String last = stack.get(stack.size() - 1).tag;
            if ((HEADINGS.contains(tag) && HEADINGS.contains(last))
                    || (DEFINITION_TAGS.contains(tag) && DEFINITION_TAGS.contains(last))
                    || (tag.equals("tr") && "tr".equals(last))
                    || (CELL_TAGS.contains(tag) && CELL_TAGS.contains(last))) stack.remove(stack.size() - 1);
        }
        void append(Node node) {
            Node parent = stack.get(stack.size() - 1);
            node.parent = parent;
            parent.children.add(node);
            nodeCount++;
        }
        void appendText(String text) { if (!text.isEmpty()) append(new Node(null, text, null)); }
        void skipTag() {
            char quote = 0;
            while (index < input.length()) {
                char ch = input.charAt(index++);
                if (quote != 0) { if (ch == quote) quote = 0; }
                else if (ch == '"' || ch == '\'') quote = ch;
                else if (ch == '>') return;
            }
        }
        void skipWhitespace() { while (index < input.length() && Character.isWhitespace(input.charAt(index))) index++; }
        String readName() {
            int start = index;
            while (index < input.length()) {
                char ch = input.charAt(index);
                if (!asciiLetter(ch) && !Character.isDigit(ch) && "-:_".indexOf(ch) < 0) break;
                index++;
            }
            return input.substring(start, index);
        }
        boolean matches(String value, boolean ignoreCase) { return input.regionMatches(ignoreCase, index, value, 0, value.length()); }
    }

    private static final Map<String, String> ENTITIES = new HashMap<>();
    static {
        String[] names = {"amp", "AMP", "lt", "LT", "gt", "GT", "quot", "QUOT", "apos", "nbsp", "copy", "reg", "trade", "mdash", "ndash", "hellip", "laquo", "raquo", "lsquo", "rsquo", "ldquo", "rdquo", "bull", "middot", "times", "divide", "plusmn", "deg", "euro", "pound", "yen", "cent", "sect", "para", "micro", "acute", "auml", "ouml", "uuml", "Auml", "Ouml", "Uuml", "szlig", "eacute", "Eacute", "agrave", "aacute", "acirc", "ecirc", "egrave", "ntilde", "ccedil", "aring", "oslash", "rarr", "larr", "uarr", "darr", "ne", "le", "ge", "infin"};
        String[] values = {"&", "&", "<", "<", ">", ">", "\"", "\"", "'", "\u00a0", "©", "®", "™", "—", "–", "…", "«", "»", "‘", "’", "“", "”", "•", "·", "×", "÷", "±", "°", "€", "£", "¥", "¢", "§", "¶", "µ", "´", "ä", "ö", "ü", "Ä", "Ö", "Ü", "ß", "é", "É", "à", "á", "â", "ê", "è", "ñ", "ç", "å", "ø", "→", "←", "↑", "↓", "≠", "≤", "≥", "∞"};
        for (int i = 0; i < names.length; i++) ENTITIES.put(names[i], values[i]);
    }
    private static final int[] WINDOWS_1252 = {0x20ac,0x81,0x201a,0x0192,0x201e,0x2026,0x2020,0x2021,0x02c6,0x2030,0x0160,0x2039,0x0152,0x8d,0x017d,0x8f,0x90,0x2018,0x2019,0x201c,0x201d,0x2022,0x2013,0x2014,0x02dc,0x2122,0x0161,0x203a,0x0153,0x9d,0x017e,0x0178};

    public static String decodeEntities(String text) {
        if (text.indexOf('&') < 0) return text;
        StringBuilder output = new StringBuilder(text.length());
        int cursor = 0;
        while (cursor < text.length()) {
            if (text.charAt(cursor) != '&') { output.append(text.charAt(cursor++)); continue; }
            int end = cursor + 1;
            while (end < text.length() && end - cursor <= 32 && (Character.isLetterOrDigit(text.charAt(end)) || text.charAt(end) == '#')) end++;
            boolean semicolon = end < text.length() && text.charAt(end) == ';';
            String key = text.substring(cursor + 1, end);
            String replacement = null;
            if (key.startsWith("#")) {
                boolean hex = key.startsWith("#x") || key.startsWith("#X");
                try {
                    long number = Long.parseLong(key.substring(hex ? 2 : 1), hex ? 16 : 10);
                    if (number >= 0 && number <= 0xffffffffL) {
                        if (number >= 0x80 && number <= 0x9f) number = WINDOWS_1252[(int)number - 0x80];
                        replacement = number == 0 || number > 0x10ffff || (number >= 0xd800 && number <= 0xdfff) ? "\ufffd" : new String(Character.toChars((int)number));
                    }
                } catch (NumberFormatException ignored) { }
            } else if (semicolon || OPTIONAL_SEMICOLON.contains(key)) {
                replacement = ENTITIES.get(key);
            }
            if (replacement != null) { output.append(replacement); cursor = end + (semicolon ? 1 : 0); }
            else { output.append('&'); cursor++; }
        }
        return output.toString();
    }

    static Set<String> set(String... values) { return new HashSet<>(Arrays.asList(values)); }
    static String lower(String value) { return value == null ? "" : value.toLowerCase(Locale.ROOT); }
    private static boolean asciiLetter(char ch) { return ch >= 'A' && ch <= 'Z' || ch >= 'a' && ch <= 'z'; }
}
