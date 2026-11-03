package com.culpen.browser.engine;

import org.junit.Test;
import java.net.URI;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.List;
import static org.junit.Assert.*;

public class HtmlTest {
    @Test public void quotedAttributesEntitiesAndCaseInsensitiveMarkup() {
        Html.Document document = Html.parse("<!doctype html><HTML><HEAD><TITLE> A &amp; B </TITLE></HEAD><BODY><A HREF='next?a=1&amp;b=2' title=hello data-value=\"1 > 0\">Go &#x1F680;</A><br>tail</BODY></HTML>");
        assertEquals("A & B", document.title());
        Html.Node link = document.body().descendants("a").get(0);
        assertEquals("next?a=1&b=2", link.attributes.get("href"));
        assertEquals("1 > 0", link.attributes.get("data-value"));
        assertEquals("Go 🚀", link.textContent());
        List<Html.Node> children = document.body().children;
        assertEquals("tail", children.get(children.size() - 1).textContent());
        assertSame(document.body(), link.parent);
    }

    @Test public void rawTextDoesNotCreateMarkup() {
        Html.Document document = Html.parse("<title>A &lt; B</title><style>p::before { content: '<b>&amp;'; }</style><script>if (a < b) x = '<div>value</div>';</script><p>visible</p>");
        assertEquals("A < B", document.title());
        assertTrue(document.embeddedStyles().contains("<b>&amp;"));
        assertTrue(document.root.descendants("div").isEmpty());
        assertEquals("visible", document.root.descendants("p").get(0).textContent());
    }

    @Test public void rawClosingTagNeedsDelimiter() {
        Html.Document document = Html.parse("<script>bad </scripted><p>hidden</p></SCRIPT><p>visible</p>");
        assertEquals(1, document.root.descendants("p").size());
        assertEquals("visible", document.root.descendants("p").get(0).textContent());
    }

    @Test public void commentsMalformedTagsAndDuplicateAttributes() {
        Html.Document document = Html.parse("<!-- <p>hidden</p> --><p>1 < 2 &amp; 3</p><div DATA-X='a' data-x='b'>end</div>");
        assertEquals(1, document.root.descendants("p").size());
        assertEquals("1 < 2 & 3", document.root.descendants("p").get(0).textContent());
        assertEquals("a", document.root.descendants("div").get(0).attributes.get("data-x"));
    }

    @Test public void optionalParagraphAndListEndTags() {
        Html.Document document = Html.parse("<p>first<p>second<ul><li>one<li>two</ul><p>last");
        List<Html.Node> paragraphs = document.root.descendants("p");
        assertEquals(3, paragraphs.size());
        assertEquals("first", paragraphs.get(0).textContent());
        assertEquals("second", paragraphs.get(1).textContent());
        assertEquals("last", paragraphs.get(2).textContent());
        Html.Node list = document.root.descendants("ul").get(0);
        assertEquals(2, list.children.size());
        assertEquals("one", list.children.get(0).textContent());
        assertEquals("two", list.children.get(1).textContent());
    }

    @Test public void nestedListsDoNotCloseOuterListItem() {
        Html.Document document = Html.parse("<ul><li>outer<ul><li>inner<li>inner2</ul><li>next</ul>");
        Html.Node outer = document.root.descendants("ul").get(0);
        assertEquals(2, outer.children.size());
        assertEquals("outerinnerinner2", outer.children.get(0).textContent());
        assertEquals("next", outer.children.get(1).textContent());
    }

    @Test public void baseUrlAndUnsupportedSchemeFallback() {
        URI original = URI.create("https://example.org/docs/index.html");
        assertEquals(URI.create("https://example.org/assets/"), Html.parse("<base href='../assets/'>").baseUrl(original));
        assertEquals(original, Html.parse("<base href='javascript:alert(1)'>").baseUrl(original));
        assertEquals(original, Html.parse("<base href='http://bad host/'>").baseUrl(original));
    }

    @Test public void numericUnknownAndOptionalSemicolonEntities() {
        assertEquals("A A � � € &unknown; ©", Html.decodeEntities("&#65; &#x41; &#0; &#xD800; &#128; &unknown; &copy;"));
        assertEquals("a & b < c", Html.decodeEntities("a &amp b &lt c"));
        assertEquals("� &#9999999999999999999999999999999;", Html.decodeEntities("&#x110000; &#9999999999999999999999999999999;"));
    }

    @Test public void extremeNestingAndNodeCountAreBounded() {
        StringBuilder source = new StringBuilder();
        for (int i = 0; i < 1500; i++) source.append("<div>");
        source.append("content");
        for (int i = 0; i < 1500; i++) source.append("</div>");
        Html.Document document = Html.parse(source.toString());
        Deque<Html.Node> pending = new ArrayDeque<>();
        pending.push(document.root);
        while (!pending.isEmpty()) {
            Html.Node node = pending.pop();
            int depth = 0;
            for (Html.Node parent = node.parent; parent != null; parent = parent.parent) depth++;
            assertTrue(depth <= 256);
            pending.addAll(node.children);
        }
        assertTrue(document.root.textContent().contains("content"));
        source.setLength(0);
        for (int i = 0; i < 90000; i++) source.append("<br>");
        assertEquals(79999, Html.parse(source.toString()).root.children.size());
    }
}
