import BrowserCore

enum SearchPage {
    static func html(query: String, results: [WebSearch.Result]) -> String {
        guard !results.isEmpty else {
            return html(query: query, message: "No results found. Try a shorter or different search.")
        }
        let escape = BrowserWindowController.escape
        let rows = results.map { result in
            """
            <article>
                <p class="domain">\(escape(result.url.host ?? ""))</p>
                <h2><a href="\(escape(result.url.absoluteString))">\(escape(result.title))</a></h2>
                <p class="snippet">\(escape(result.snippet))</p>
            </article>
            """
        }.joined(separator: "\n")
        return document(query: query, body: rows)
    }

    static func html(query: String, message: String) -> String {
        document(query: query, body: "<p class=\"message\">\(BrowserWindowController.escape(message))</p>")
    }

    private static func document(query: String, body: String) -> String {
        """
        <!doctype html><html><head><title>Search Results</title><style>
        body { background-color: #ffffff; color: #26354a; padding: 8px; }
        header { padding: 18px; background-color: #eff5ff; margin-bottom: 22px; }
        .brand { color: #245ac7; font-size: 14px; font-weight: bold; margin: 0; }
        h1 { color: #15243b; font-size: 27px; margin-top: 6px; margin-bottom: 0; }
        .section { color: #245ac7; font-size: 13px; font-weight: bold; margin: 0; }
        article { margin-bottom: 23px; }
        .domain { color: #53647b; font-size: 13px; margin: 0; }
        h2 { font-size: 20px; margin-top: 3px; margin-bottom: 4px; }
        h2 a { color: #245ac7; text-decoration: none; }
        .snippet { color: #36475e; font-size: 15px; margin: 0; }
        .message { font-size: 16px; margin-top: 8px; margin-bottom: 24px; }
        footer { color: #53647b; font-size: 12px; margin-top: 12px; }
        </style></head><body>
        <header><p class="brand">Browser Search</p><h1>\(BrowserWindowController.escape(query))</h1></header>
        <p class="section">Web</p><hr>
        <main>\(body)</main>
        <footer>Powered by SearXNG on this Mac · <a href="browser:search-settings">Search Settings</a></footer>
        </body></html>
        """
    }
}
