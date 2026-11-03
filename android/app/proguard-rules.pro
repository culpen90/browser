# Preserve view methods inspected by the release instrumentation suite.
-keep class com.culpen.browser.MainActivity { public *; }
-keep class com.culpen.browser.PageView { *; }
-keep interface com.culpen.browser.PageView$NavigationListener { *; }
-keep class com.culpen.browser.engine.** { public *; }
