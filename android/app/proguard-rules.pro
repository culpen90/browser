# Preserve view methods inspected by the release instrumentation suite.
-keep class com.culpen.browser.MainActivity { public *; }
-keep class com.culpen.browser.PageView { *; }
-keep interface com.culpen.browser.PageView$NavigationListener { *; }
-keep class com.culpen.browser.engine.** { public *; }

# Preserve the agent API called by release instrumentation.
-keepclassmembers class com.culpen.browser.MainActivity {
    com.culpen.browser.BrowserAgentPanel getAgentPanel();
    java.util.concurrent.CompletableFuture observeAgentPage();
    java.util.concurrent.CompletableFuture performAgentAction(com.culpen.browser.MobileBrowserAgent$Command, com.culpen.browser.MobileBrowserAgent$Snapshot, boolean);
}
-keep class com.culpen.browser.BrowserAgentPanel {
    void show();
    void hide();
    boolean isOpen();
    boolean connect(java.lang.String);
    java.lang.String logText();
}
-keep class com.culpen.browser.MobileBrowserAgent$Snapshot {
    <fields>;
    <init>(...);
}
-keep class com.culpen.browser.MobileBrowserAgent$Element {
    <fields>;
    <init>(...);
}
-keep class com.culpen.browser.MobileBrowserAgent$Command {
    <fields>;
    <init>(...);
}
-keep class com.culpen.browser.AgentConnection {
    static com.culpen.browser.AgentConnection parse(java.lang.String);
}
