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
    boolean selectDevice(java.lang.String);
    java.lang.String phonePairingLink(java.lang.String);
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
    java.lang.String identity();
    java.lang.String pairingLink();
}

# Preserve the pairing and invitation entry points called by instrumentation.
-keep class com.culpen.browser.AgentPairingStore {
    <init>(android.content.Context);
    com.culpen.browser.AgentConnection load();
    java.util.List devices();
    void save(java.lang.String);
    void forget(java.lang.String);
}
-keep class com.culpen.browser.AgentPhoneIdentity {
    java.lang.String id;
    java.security.KeyPair keyPair;
    static com.culpen.browser.AgentPhoneIdentity load(android.content.Context);
    boolean trusts(byte[]);
    boolean trusts(byte[],java.lang.String);
    void remember(byte[],java.lang.String);
    void forget(java.lang.String);
}
-keep class com.culpen.browser.AgentPhoneInbox {
    <init>(android.content.Context,java.util.function.BiFunction,java.util.function.Function);
    void start();
    boolean isRunning();
    void forgetComputer(java.lang.String);
    void destroy();
}
-keep class com.culpen.browser.PhoneInviteCrypto {
    static byte[] REQUEST_AAD;
    static byte[] sharedKey(java.security.KeyPair,byte[]);
    static java.lang.String code(byte[]);
}
