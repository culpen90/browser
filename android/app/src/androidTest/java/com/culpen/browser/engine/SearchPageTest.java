package com.culpen.browser.engine;

import org.junit.Test;

import java.util.List;

import static org.junit.Assert.*;

public class SearchPageTest {
    @Test public void rendersEscapedResultsAndAcceptsOnlyRealWebLinks() throws Exception {
        Html.Document page = SearchPage.results("café <img> & more", """
                {"results": [
                    {"url":"https://example.com/a?q=one&x=two","title":"<a href='bad'>Real title</a>","content":"<img> & description"},
                    {"url":"javascript:alert(1)","title":"Unsafe"},
                    {"url":"browser:search?q=forged","title":"Forged"},
                    {"url":"https://person:password@example.com/","title":"Credentials"},
                    {"url":"https://example.com/a?q=one&x=two","title":"Duplicate"}
                ]}
                """);
        assertEquals("Browser Search", page.title());
        assertEquals("café <img> & more", page.root.descendants("h2").get(0).textContent());
        assertTrue(page.body().textContent().contains("<img> & description"));
        assertTrue(page.root.descendants("img").isEmpty());
        List<Html.Node> links = page.root.descendants("a");
        assertEquals(2, links.size());
        assertEquals("https://example.com/a?q=one&x=two", links.get(0).attributes.get("href"));
        assertEquals("<a href='bad'>Real title</a>", links.get(0).textContent());
        assertEquals("CC BY-NC-SA 4.0", links.get(1).textContent());
        assertFalse(page.body().textContent().contains("api.mwmbl.org"));
    }

    @Test public void emptyResultSetKeepsQueryAndShowsHowToRecover() throws Exception {
        Html.Document page = SearchPage.results("unlikely search", "{\"results\":[]}");
        assertTrue(page.body().textContent().contains("No results found"));
        assertTrue(page.body().textContent().contains("Try a different search."));
        assertTrue(page.body().textContent().contains("unlikely search"));
    }
}
