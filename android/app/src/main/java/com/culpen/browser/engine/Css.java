package com.culpen.browser.engine;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/** The independent engine's supported CSS subset and cascade. */
public final class Css {
    private Css() {}

    public static final class Style {
        public String display = "inline";
        public double fontSize = 16;
        public boolean bold;
        public boolean italic;
        public boolean monospace;
        public String color = "#202124";
        public String backgroundColor;
        public double marginTop;
        public double marginBottom;
        public double padding;
        public boolean preformatted;
        public boolean underline;
    }

    public static final class StyleSheet {
        public static final int MAX_LAYOUT_WORK = 1_000_000;
        private final List<Rule> rules;
        private final List<Rule> universal = new ArrayList<>();
        private final Map<String, List<Rule>> tags = new LinkedHashMap<>();
        private final Map<String, List<Rule>> ids = new LinkedHashMap<>();
        private final Map<String, List<Rule>> classes = new LinkedHashMap<>();
        private final WorkBudget budget = new WorkBudget();

        public StyleSheet(String css) {
            rules = readRules(css == null ? "" : css);
            // Each rule belongs to exactly one bucket for its rightmost compound.
            for (Rule rule : rules) {
                Compound last = rule.selector.compounds.get(rule.selector.compounds.size() - 1);
                if (!last.ids.isEmpty()) index(ids, last.ids.get(0), rule);
                else if (!last.classes.isEmpty()) index(classes, last.classes.get(0), rule);
                else if (last.tag != null) index(tags, last.tag, rule);
                else universal.add(rule);
            }
        }
        private static void index(Map<String, List<Rule>> buckets, String key, Rule rule) {
            List<Rule> values = buckets.get(key);
            if (values == null) { values = new ArrayList<>(); buckets.put(key, values); }
            values.add(rule);
        }
        /** Reset once before each document layout, including a resize or font-scale reflow. */
        public void beginLayout() { budget.reset(); }
        /** True when custom styles were bounded; native defaults and inline styles still apply. */
        public boolean isLayoutLimited() { return budget.limited; }

        public Style style(Html.Node node, Style parent) {
            Style style = new Style();
            if (parent != null) {
                style.fontSize = parent.fontSize;
                style.bold = parent.bold;
                style.italic = parent.italic;
                style.monospace = parent.monospace;
                style.color = parent.color;
                style.preformatted = parent.preformatted;
                style.underline = parent.underline;
            }
            applyDefaults(style, node);
            if (node.tag == null) return style;
            List<Rule> matched = new ArrayList<>();
            if (!budget.limited) {
                List<List<Rule>> candidates = new ArrayList<>();
                candidates.add(universal);
                if (tags.containsKey(node.tag)) candidates.add(tags.get(node.tag));
                String id = node.attributes.get("id");
                if (ids.containsKey(id)) candidates.add(ids.get(id));
                if (!classes.isEmpty() && node.attributes.containsKey("class")) {
                    Set<String> names = budget.classes(node);
                    if (!budget.limited) for (String name : names) if (classes.containsKey(name)) candidates.add(classes.get(name));
                }
                outer: for (List<Rule> bucket : candidates) {
                    for (Rule rule : bucket) {
                        if (rule.selector.matches(node, budget)) matched.add(rule);
                        if (budget.limited) break outer;
                    }
                }
                // A partially evaluated cascade is discarded for this node.
                if (budget.limited) matched.clear();
            }
            Collections.sort(matched, (a, b) -> {
                int result = a.selector.specificity.compareTo(b.selector.specificity);
                return result == 0 ? Integer.compare(a.order, b.order) : result;
            });
            List<Declaration> inline = declarations(node.attributes.getOrDefault("style", ""));
            long declarationWork = 0;
            for (Rule rule : matched) declarationWork += rule.declarationWork;
            if (!budget.spend(declarationWork)) matched.clear();
            double parentSize = parent == null ? 16 : parent.fontSize;
            for (boolean important : new boolean[]{false, true}) {
                for (Rule rule : matched) {
                    for (Declaration declaration : rule.declarations) if (declaration.important == important) apply(declaration, style, parentSize);
                }
                for (Declaration declaration : inline) if (declaration.important == important) apply(declaration, style, parentSize);
            }
            return style;
        }
    }

    /** Bounds selector ancestry, class tokenization, and rule declarations across a whole layout. */
    private static final class WorkBudget {
        int remaining = StyleSheet.MAX_LAYOUT_WORK;
        boolean limited;
        final IdentityHashMap<Html.Node, Set<String>> classCache = new IdentityHashMap<>();
        void reset() { remaining = StyleSheet.MAX_LAYOUT_WORK; limited = false; classCache.clear(); }
        boolean spend(long count) {
            if (count > remaining) { remaining = 0; limited = true; return false; }
            remaining -= (int) count;
            return true;
        }
        Set<String> classes(Html.Node node) {
            Set<String> cached = classCache.get(node);
            if (cached != null) return cached;
            Set<String> result = new LinkedHashSet<>();
            String value = node.attributes.getOrDefault("class", "");
            int start = -1;
            for (int i = 0; i < value.length(); i++) {
                if (!spend(1)) break;
                if (Character.isWhitespace(value.charAt(i))) {
                    if (start >= 0) { result.add(value.substring(start, i)); start = -1; }
                } else if (start < 0) start = i;
            }
            if (!limited && start >= 0) result.add(value.substring(start));
            classCache.put(node, result);
            return result;
        }
    }

    private static final Set<String> BLOCKS = set("html", "body", "address", "article", "aside", "blockquote", "center", "details", "dialog", "div", "dl", "dt", "dd", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "summary", "table", "thead", "tbody", "tfoot", "tr", "ul");
    private static final Set<String> HIDDEN = set("head", "title", "base", "meta", "link", "style", "script", "template", "noscript", "source", "track", "param");
    private static final Set<String> BOLD = set("strong", "b", "th");
    private static final Set<String> ITALIC = set("em", "i", "cite", "dfn", "var", "address");
    private static final Set<String> MONOSPACE = set("code", "pre", "kbd", "samp", "tt");
    private static final Set<String> MARGINS = set("p", "blockquote", "pre", "ul", "ol", "dl", "figure");
    private static final Set<String> DISPLAYS = set("none", "inline", "block", "inline-block", "list-item", "table", "table-row", "table-cell", "flex", "grid");
    private static final Set<String> COLORS = set("black", "white", "red", "green", "blue", "gray", "grey", "silver", "maroon", "purple", "fuchsia", "lime", "olive", "yellow", "navy", "teal", "aqua", "orange", "transparent", "rebeccapurple", "darkgray", "darkgrey", "lightgray", "lightgrey");

    private static void applyDefaults(Style style, Html.Node node) {
        String tag = node.tag;
        if (tag == null) {
            if (node.text == null) style.display = "block";
            return;
        }
        style.display = BLOCKS.contains(tag) ? "block" : "inline";
        if (HIDDEN.contains(tag) || node.attributes.containsKey("hidden")) style.display = "none";
        if (BOLD.contains(tag)) style.bold = true;
        if (ITALIC.contains(tag)) style.italic = true;
        if (MONOSPACE.contains(tag)) style.monospace = true;
        if (tag.equals("pre")) style.preformatted = true;
        if (tag.equals("u") || tag.equals("ins")) style.underline = true;
        if (tag.equals("a") && node.attributes.containsKey("href")) { style.color = "#245ac7"; style.underline = true; }
        if (MARGINS.contains(tag)) { style.marginTop = 12; style.marginBottom = 12; }
        if (tag.length() == 2 && tag.charAt(0) == 'h' && tag.charAt(1) >= '1' && tag.charAt(1) <= '6') {
            double[] multipliers = {2, 1.5, 1.17, 1, .83, .67};
            style.fontSize *= multipliers[tag.charAt(1) - '1'];
            style.bold = true;
            style.marginTop = 18;
            style.marginBottom = 10;
        }
        if (tag.equals("small")) style.fontSize *= .83;
        if (tag.equals("big")) style.fontSize *= 1.2;
        if (tag.equals("hr")) { style.marginTop = 14; style.marginBottom = 14; }
    }

    private static void apply(Declaration declaration, Style style, double parentSize) {
        String value = declaration.value.trim();
        String lower = lower(value);
        Double size;
        switch (declaration.name) {
            case "display":
                if (DISPLAYS.contains(lower)) style.display = lower.equals("none") || lower.equals("inline") ? lower : "block";
                break;
            case "font-size":
                String[] words = {"xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large"};
                double[] sizes = {9, 10, 13, 16, 18, 24, 32};
                int keyword = Arrays.asList(words).indexOf(lower);
                size = keyword >= 0 ? Double.valueOf(sizes[keyword]) : length(lower, parentSize);
                if (size != null) style.fontSize = clamp(size, 6, 144);
                else if (lower.equals("smaller")) style.fontSize = Math.max(6, parentSize * .83);
                else if (lower.equals("larger")) style.fontSize = Math.min(144, parentSize * 1.2);
                break;
            case "font-weight":
                if (lower.equals("bold") || lower.equals("bolder")) style.bold = true;
                else if (lower.equals("normal") || lower.equals("lighter")) style.bold = false;
                else {
                    try { int weight = Integer.parseInt(lower); if (weight >= 1 && weight <= 1000) style.bold = weight >= 600; }
                    catch (NumberFormatException ignored) { }
                }
                break;
            case "font-style":
                if (lower.equals("normal") || lower.equals("italic") || lower.equals("oblique")) style.italic = !lower.equals("normal");
                break;
            case "font-family":
                style.monospace = lower.contains("monospace") || lower.contains("courier") || lower.contains("menlo") || lower.contains("monaco");
                break;
            case "color": if (isColor(lower)) style.color = value; break;
            case "background":
            case "background-color":
                if (isColor(lower)) style.backgroundColor = value;
                if (lower.equals("transparent")) style.backgroundColor = null;
                break;
            case "margin-top":
                size = length(lower, style.fontSize); if (size != null) style.marginTop = clamp(size, -100, 1000); break;
            case "margin-bottom":
                size = length(lower, style.fontSize); if (size != null) style.marginBottom = clamp(size, -100, 1000); break;
            case "margin":
                String[] components = lower.split("\\s+");
                if (components.length >= 1 && components.length <= 4) {
                    size = length(components[0], style.fontSize); if (size != null) style.marginTop = clamp(size, -100, 1000);
                    size = length(components.length > 2 ? components[2] : components[0], style.fontSize); if (size != null) style.marginBottom = clamp(size, -100, 1000);
                }
                break;
            case "padding":
                size = length(lower.split("\\s+")[0], style.fontSize); if (size != null) style.padding = clamp(size, 0, 300); break;
            case "white-space":
                if (lower.equals("pre") || lower.equals("pre-wrap") || lower.equals("break-spaces")) style.preformatted = true;
                else if (lower.equals("normal") || lower.equals("nowrap") || lower.equals("pre-line")) style.preformatted = false;
                break;
            case "text-decoration":
            case "text-decoration-line":
                if (lower.equals("none")) style.underline = false;
                else if (lower.contains("underline")) style.underline = true;
                break;
            default: break;
        }
    }

    private static Double length(String value, double relativeSize) {
        String[] units = {"rem", "em", "px", "pt", "%"};
        double[] scales = {16, relativeSize, 1, 4.0 / 3, relativeSize / 100};
        for (int i = 0; i < units.length; i++) {
            if (!value.endsWith(units[i])) continue;
            try {
                double number = Double.parseDouble(value.substring(0, value.length() - units[i].length()));
                return Double.isNaN(number) || Double.isInfinite(number) ? null : number * scales[i];
            } catch (NumberFormatException ignored) { return null; }
        }
        try { return Double.parseDouble(value) == 0 ? 0.0 : null; }
        catch (NumberFormatException ignored) { return null; }
    }
    private static boolean isColor(String value) {
        if (value.startsWith("#")) return (value.length() == 4 || value.length() == 5 || value.length() == 7 || value.length() == 9) && value.substring(1).matches("[0-9a-f]+");
        if (value.startsWith("rgb(") || value.startsWith("rgba(")) return value.endsWith(")");
        return COLORS.contains(value);
    }

    private static final class Declaration {
        final String name, value;
        final boolean important;
        Declaration(String name, String value, boolean important) { this.name = name; this.value = value; this.important = important; }
    }
    private static final class Rule {
        final Selector selector;
        final List<Declaration> declarations;
        final int order;
        final long declarationWork;
        Rule(Selector selector, List<Declaration> declarations, int order) {
            this.selector = selector; this.declarations = declarations; this.order = order;
            long work = 0;
            for (Declaration declaration : declarations) work += 2L * (1 + declaration.name.length() + declaration.value.length());
            declarationWork = work;
        }
    }
    private static final class Specificity implements Comparable<Specificity> {
        int ids, classes, tags;
        public int compareTo(Specificity other) {
            int value = Integer.compare(ids, other.ids);
            if (value != 0) return value;
            value = Integer.compare(classes, other.classes);
            return value != 0 ? value : Integer.compare(tags, other.tags);
        }
    }
    private static final class Compound {
        String tag;
        final List<String> ids = new ArrayList<>();
        final List<String> classes = new ArrayList<>();
        int workCost = 1;
        boolean root, link;
        boolean matches(Html.Node node, WorkBudget budget) {
            if (!budget.spend(workCost)) return false;
            if (node.tag == null || tag != null && !tag.equals(node.tag)) return false;
            for (String id : ids) if (!id.equals(node.attributes.get("id"))) return false;
            if (!classes.isEmpty()) {
                Set<String> actual = budget.classes(node);
                if (budget.limited || !actual.containsAll(classes)) return false;
            }
            if (root && node.parent != null && node.parent.tag != null) return false;
            return !link || node.tag.equals("a") && node.attributes.containsKey("href");
        }
    }
    private static final class Selector {
        final List<Compound> compounds = new ArrayList<>();
        final List<Boolean> childRelations = new ArrayList<>();
        final Specificity specificity = new Specificity();
        static Selector parse(String source) {
            String input = source.trim();
            if (input.isEmpty() || input.length() >= 1000) return null;
            Selector result = new Selector();
            int cursor = 0;
            while (cursor < input.length()) {
                Compound part = new Compound();
                boolean recognized = false;
                char ch = input.charAt(cursor);
                if (ch == '*') { cursor++; recognized = true; }
                else if (Character.isLetter(ch) || ch == '_' || ch == '-') {
                    int start = cursor;
                    while (cursor < input.length() && isName(input.charAt(cursor))) cursor++;
                    part.tag = lower(input.substring(start, cursor));
                    part.workCost += part.tag.length();
                    result.specificity.tags++;
                    recognized = true;
                }
                while (cursor < input.length() && ".#:".indexOf(input.charAt(cursor)) >= 0) {
                    char prefix = input.charAt(cursor++);
                    int start = cursor;
                    while (cursor < input.length() && isName(input.charAt(cursor))) cursor++;
                    if (start == cursor) return null;
                    String name = input.substring(start, cursor);
                    part.workCost += 1 + name.length();
                    if (prefix == '.') { part.classes.add(name); result.specificity.classes++; }
                    else if (prefix == '#') { part.ids.add(name); result.specificity.ids++; }
                    else {
                        if (name.equals("root")) part.root = true;
                        else if (name.equals("link") || name.equals("any-link")) part.link = true;
                        else return null;
                        result.specificity.classes++;
                    }
                    recognized = true;
                }
                if (!recognized) return null;
                result.compounds.add(part);
                int beforeWhitespace = cursor;
                while (cursor < input.length() && Character.isWhitespace(input.charAt(cursor))) cursor++;
                if (cursor == input.length()) break;
                if (input.charAt(cursor) == '>') {
                    result.childRelations.add(true);
                    cursor++;
                    while (cursor < input.length() && Character.isWhitespace(input.charAt(cursor))) cursor++;
                    if (cursor == input.length()) return null;
                } else if (cursor > beforeWhitespace) result.childRelations.add(false);
                else return null;
            }
            return result.compounds.size() == result.childRelations.size() + 1 ? result : null;
        }
        boolean matches(Html.Node node, WorkBudget budget) { return match(compounds.size() - 1, node, false, new IdentityHashMap<>(), budget); }
        boolean match(int position, Html.Node candidate, boolean maySkip, IdentityHashMap<Html.Node, byte[]> memo, WorkBudget budget) {
            if (!budget.spend(1)) return false;
            if (candidate == null) return false;
            byte[] cached = memo.get(candidate);
            if (cached == null) { cached = new byte[compounds.size() * 2]; memo.put(candidate, cached); }
            int key = position * 2 + (maySkip ? 1 : 0);
            if (cached[key] != 0) return cached[key] == 2;
            boolean matched = compounds.get(position).matches(candidate, budget)
                    && (position == 0 || match(position - 1, candidate.parent, !childRelations.get(position - 1), memo, budget));
            if (!matched && maySkip) matched = match(position, candidate.parent, true, memo, budget);
            cached[key] = (byte)(matched ? 2 : 1);
            return matched;
        }
        static boolean isName(char ch) { return Character.isLetterOrDigit(ch) || ch == '_' || ch == '-'; }
    }

    private static List<Rule> readRules(String source) {
        String input = removeComments(source.substring(0, Math.min(500_000, source.length())));
        int cursor = 0;
        List<Rule> output = new ArrayList<>();
        while (cursor < input.length() && output.size() < 5000) {
            while (cursor < input.length() && Character.isWhitespace(input.charAt(cursor))) cursor++;
            int start = cursor;
            char quote = 0;
            while (cursor < input.length()) {
                char ch = input.charAt(cursor);
                if (ch == '\\') { cursor = Math.min(cursor + 2, input.length()); continue; }
                if (quote != 0) { if (ch == quote) quote = 0; }
                else if (ch == '"' || ch == '\'') quote = ch;
                else if (ch == '{' || ch == ';') break;
                cursor++;
            }
            if (cursor >= input.length()) break;
            if (input.charAt(cursor) == ';') { cursor++; continue; }
            String selector = input.substring(start, cursor).trim();
            int bodyStart = ++cursor;
            int depth = 1;
            quote = 0;
            while (cursor < input.length() && depth > 0) {
                char ch = input.charAt(cursor);
                if (ch == '\\') { cursor = Math.min(cursor + 2, input.length()); continue; }
                if (quote != 0) { if (ch == quote) quote = 0; }
                else if (ch == '"' || ch == '\'') quote = ch;
                else if (ch == '{') depth++;
                else if (ch == '}') { depth--; if (depth == 0) break; }
                cursor++;
            }
            String body = input.substring(bodyStart, cursor);
            if (cursor < input.length()) cursor++;
            if (selector.startsWith("@")) continue;
            List<Declaration> properties = declarations(body);
            for (String candidate : selector.split(",")) {
                if (output.size() >= 5000) break;
                Selector parsed = Selector.parse(candidate);
                if (parsed != null) output.add(new Rule(parsed, properties, output.size()));
            }
        }
        return output;
    }

    private static List<Declaration> declarations(String source) {
        String input = removeComments(source.substring(0, Math.min(100_000, source.length())));
        List<String> pieces = new ArrayList<>();
        int start = 0, cursor = 0, parentheses = 0;
        char quote = 0;
        while (cursor < input.length()) {
            char ch = input.charAt(cursor);
            if (ch == '\\') { cursor = Math.min(cursor + 2, input.length()); continue; }
            if (quote != 0) { if (ch == quote) quote = 0; }
            else if (ch == '"' || ch == '\'') quote = ch;
            else if (ch == '(') parentheses++;
            else if (ch == ')') parentheses = Math.max(0, parentheses - 1);
            else if (ch == ';' && parentheses == 0) { pieces.add(input.substring(start, cursor)); start = cursor + 1; }
            cursor++;
        }
        pieces.add(input.substring(start));
        List<Declaration> result = new ArrayList<>();
        for (String piece : pieces) {
            int separator = piece.indexOf(':');
            if (separator < 0) continue;
            String name = lower(piece.substring(0, separator).trim());
            String value = piece.substring(separator + 1).trim();
            boolean important = lower(value).endsWith("!important");
            if (important) value = value.substring(0, value.length() - 10).trim();
            if (!name.isEmpty() && !value.isEmpty()) result.add(new Declaration(name, value, important));
        }
        return result;
    }

    private static String removeComments(String source) {
        StringBuilder result = new StringBuilder(source.length());
        int cursor = 0;
        char quote = 0;
        while (cursor < source.length()) {
            char ch = source.charAt(cursor);
            if (ch == '\\' && cursor + 1 < source.length()) { result.append(ch).append(source.charAt(cursor + 1)); cursor += 2; continue; }
            if (quote != 0) { if (ch == quote) quote = 0; }
            else if (ch == '"' || ch == '\'') quote = ch;
            else if (ch == '/' && cursor + 1 < source.length() && source.charAt(cursor + 1) == '*') {
                int end = source.indexOf("*/", cursor + 2);
                cursor = end < 0 ? source.length() : end + 2;
                result.append(' ');
                continue;
            }
            result.append(ch);
            cursor++;
        }
        return result.toString();
    }
    private static double clamp(double value, double low, double high) { return Math.max(low, Math.min(high, value)); }
    private static String lower(String value) { return value.toLowerCase(Locale.ROOT); }
    private static Set<String> set(String... values) { return new HashSet<>(Arrays.asList(values)); }
}
