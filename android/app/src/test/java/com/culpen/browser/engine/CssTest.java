package com.culpen.browser.engine;

import org.junit.Test;
import java.util.List;
import static org.junit.Assert.*;

public class CssTest {
    @Test public void specificitySourceOrderAndInlineStyles() {
        Html.Document document = Html.parse("<p class='notice' id='target'>hello</p><p class='notice' style='color: green'>inline</p>");
        List<Html.Node> nodes = document.root.descendants("p");
        Css.StyleSheet sheet = new Css.StyleSheet("#target { color: red; } .notice { color: blue; } p { color: black; } .notice { font-size: 20px; } .notice { font-size: 21px; }");
        assertEquals("red", sheet.style(nodes.get(0), null).color);
        assertEquals(21, sheet.style(nodes.get(0), null).fontSize, .001);
        assertEquals("green", sheet.style(nodes.get(1), null).color);
    }

    @Test public void importantBeatsInlineNormalAndPreservesOrder() {
        Html.Node node = Html.parse("<p id='target' style='color: green; font-size: 18px !important'>hello</p>").root.descendants("p").get(0);
        Css.StyleSheet sheet = new Css.StyleSheet("p {color: blue !important; color: orange; font-size: 24px !important} #target { color: red !important; }");
        Css.Style style = sheet.style(node, null);
        assertEquals("red", style.color);
        assertEquals(18, style.fontSize, .001);
    }

    @Test public void inheritedPropertiesAndNoninheritedBoxValues() {
        Html.Document document = Html.parse("<div><span>text</span></div>");
        Css.StyleSheet sheet = new Css.StyleSheet("div { color: red; font-size: 20px; font-weight: bold; background: blue; margin: 12px; padding: 8px } span { font-size: 1.5em }");
        Css.Style parent = sheet.style(document.root.descendants("div").get(0), null);
        Css.Style child = sheet.style(document.root.descendants("span").get(0), parent);
        assertEquals(30, child.fontSize, .001);
        assertEquals("red", child.color);
        assertTrue(child.bold);
        assertNull(child.backgroundColor);
        assertEquals(0, child.padding, .001);
        assertEquals(0, child.marginTop, .001);
        assertEquals("inline", child.display);
    }

    @Test public void descendantChildAndCompoundSelectors() {
        Html.Document document = Html.parse("<div class='outer'><section><a class='action selected'>deep</a></section><a class='action'>direct</a></div>");
        List<Html.Node> links = document.root.descendants("a");
        Css.StyleSheet sheet = new Css.StyleSheet(".outer a.action { color: red } .outer > a.action { color: green } a.action.selected { font-weight: bold }");
        assertEquals("red", sheet.style(links.get(0), null).color);
        assertEquals("green", sheet.style(links.get(1), null).color);
        assertTrue(sheet.style(links.get(0), null).bold);
        assertFalse(sheet.style(links.get(1), null).bold);
    }

    @Test public void defaultHeadingLinkAndHiddenContent() {
        Html.Document document = Html.parse("<h1>Heading</h1><p>text <strong>bold</strong></p><script>bad()</script><div hidden>hidden</div><a href='next'>link</a><pre>spaces</pre>");
        Css.StyleSheet sheet = new Css.StyleSheet("");
        assertEquals(32, sheet.style(document.root.descendants("h1").get(0), null).fontSize, .001);
        assertEquals("none", sheet.style(document.root.descendants("script").get(0), null).display);
        assertEquals("none", sheet.style(document.root.descendants("div").get(0), null).display);
        assertTrue(sheet.style(document.root.descendants("a").get(0), null).underline);
        assertTrue(sheet.style(document.root.descendants("pre").get(0), null).preformatted);
    }

    @Test public void descendantMatchingRetriesAncestorsForEarlierChildRelation() {
        Html.Document document = Html.parse("<div class='outer'><div class='mid'><div><div class='mid'><p class='leaf'>match</p></div></div></div></div><div class='outer'><div><div class='mid'><p class='leaf'>no match</p></div></div></div>");
        List<Html.Node> leaves = document.root.descendants("p");
        Css.StyleSheet sheet = new Css.StyleSheet(".outer > .mid .leaf {color: red}");
        assertEquals("red", sheet.style(leaves.get(0), null).color);
        assertEquals("#202124", sheet.style(leaves.get(1), null).color);
    }

    @Test public void commentsQuotesUnknownSelectorsAndAtRules() {
        Html.Node node = Html.parse("<p class='target'>hello</p>").root.descendants("p").get(0);
        Css.StyleSheet sheet = new Css.StyleSheet("/* p {color: blue} */ @media print { p { color: red } } p:hover { color: red } .target { font-family: 'thing;other', monospace; color: rgb(1, 2, 3); margin: 10px 0 20px; } p {padding: 4px}");
        Css.Style style = sheet.style(node, null);
        assertEquals("rgb(1, 2, 3)", style.color);
        assertTrue(style.monospace);
        assertEquals(10, style.marginTop, .001);
        assertEquals(20, style.marginBottom, .001);
        assertEquals(4, style.padding, .001);
    }

    @Test public void invalidValuesDoNotPoisonComputedStyle() {
        Html.Node node = Html.parse("<p>text</p>").root.descendants("p").get(0);
        Css.Style style = new Css.StyleSheet("p {font-size: nanpx; color: totally-invalid; margin: bogus; padding: -20px}").style(node, null);
        assertEquals(16, style.fontSize, .001);
        assertEquals("#202124", style.color);
        assertEquals(12, style.marginTop, .001);
        assertEquals(0, style.padding, .001);
    }

    @Test public void rootLinkCommaSelectorsAndClampedUnits() {
        Html.Document document = Html.parse("<html><body><a href='/'>linked</a><a>unlinked</a><p>text</p></body></html>");
        Css.StyleSheet sheet = new Css.StyleSheet(":root { font-size: 200px } a:any-link, p { color: rebeccapurple } body {font-size:2rem} p {font-size:200%;padding:900px;margin:-200px}");
        assertEquals(144, sheet.style(document.root.descendants("html").get(0), null).fontSize, .001);
        assertEquals("rebeccapurple", sheet.style(document.root.descendants("a").get(0), null).color);
        assertEquals("#202124", sheet.style(document.root.descendants("a").get(1), null).color);
        Css.Style body = sheet.style(document.body(), null);
        Css.Style p = sheet.style(document.root.descendants("p").get(0), body);
        assertEquals(64, p.fontSize, .001);
        assertEquals(300, p.padding, .001);
        assertEquals(-100, p.marginTop, .001);
    }

    @Test public void malformedRulesDoNotExposeNestedAtRuleStyles() {
        Html.Node node = Html.parse("<p>text</p>").root.descendants("p").get(0);
        Css.Style style = new Css.StyleSheet("@import 'ignored.css'; @media screen { p {color:red} } p[bad] {color:red} p::before {color:red} p {color:blue}").style(node, null);
        assertEquals("blue", style.color);
    }

    @Test public void layoutBudgetBoundsLargeCascadesAndResetsForReflow() {
        StringBuilder css = new StringBuilder();
        for (int i = 0; i < 1000; i++) css.append("*{color:red}");
        Css.StyleSheet sheet = new Css.StyleSheet(css.toString());
        Html.Node node = Html.parse("<p style='font-weight:bold'>text</p>").root.descendants("p").get(0);
        assertEquals("red", sheet.style(node, null).color);
        int count = 1;
        while (!sheet.isLayoutLimited() && count < 1000) { sheet.style(node, null); count++; }
        assertTrue(sheet.isLayoutLimited());
        assertTrue(count < 1000);
        Css.Style bounded = sheet.style(node, null);
        assertEquals("#202124", bounded.color);
        assertTrue(bounded.bold); // Inline styles and native defaults survive the custom CSS limit.
        sheet.beginLayout();
        assertFalse(sheet.isLayoutLimited());
        assertEquals("red", sheet.style(node, null).color);
    }

    @Test public void rightmostIndexSkipsUnrelatedSelectors() {
        StringBuilder css = new StringBuilder();
        for (int i = 0; i < 4000; i++) css.append("#other").append(i).append("{color:red}");
        css.append("p.special{color:green}");
        Css.StyleSheet sheet = new Css.StyleSheet(css.toString());
        Html.Node node = Html.parse("<p class='special special'>text</p>").root.descendants("p").get(0);
        for (int i = 0; i < 1000; i++) assertEquals("green", sheet.style(node, null).color);
        assertFalse(sheet.isLayoutLimited());
    }

    @Test public void repeatedCommaRulesCannotMultiplyDeclarationWorkWithoutBound() {
        StringBuilder css = new StringBuilder();
        for (int i = 0; i < 5000; i++) css.append(i == 0 ? "*" : ",*");
        css.append('{');
        for (int i = 0; i < 1000; i++) css.append("color:red;");
        css.append('}');
        Css.StyleSheet sheet = new Css.StyleSheet(css.toString());
        Html.Node node = Html.parse("<p>text</p>").root.descendants("p").get(0);
        assertEquals("#202124", sheet.style(node, null).color);
        assertTrue(sheet.isLayoutLimited());
    }
}
