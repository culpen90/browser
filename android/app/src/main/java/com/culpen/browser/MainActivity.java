package com.culpen.browser;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Message;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.webkit.CookieManager;
import android.webkit.ValueCallback;
import android.webkit.WebBackForwardList;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.LinearLayout;
import android.widget.PopupMenu;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import com.culpen.browser.engine.Address;
import com.culpen.browser.engine.Html;
import com.culpen.browser.engine.NavigationHistory;
import com.culpen.browser.engine.PageLoader;

import java.net.URI;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

/** Native shell with an independent engine and a full-site compatibility surface. */
public final class MainActivity extends Activity {
    private static final URI HOME = URI.create("browser:home");
    private static final int OPEN_DOCUMENT = 10;
    private static final int CHOOSE_UPLOAD = 11;
    private final ArrayList<Boolean> compatibilityEntries = new ArrayList<>();
    private final ArrayList<Integer> webHistoryEntries = new ArrayList<>();
    private final ArrayList<Dialog> popupDialogs = new ArrayList<>();
    private final ArrayList<WebView> popupViews = new ArrayList<>();
    private final Map<WebView, TextView> popupAddresses = new LinkedHashMap<>();
    private final Map<WebView, URI> committedWebAddresses = new LinkedHashMap<>();
    private FrameLayout surfaces;
    private WebView web;
    private boolean compatibilityVisible;
    private boolean pendingWebNavigation;
    private boolean restoringWebState;
    private ValueCallback<Uri[]> uploadCallback;
    private WebView uploadOwner;
    private String compatibilityError;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final NavigationHistory history = new NavigationHistory();
    private PageLoader loader;
    private PageLoader.Cancellation cancellation;
    private Future<?> task;
    private int generation;
    private URI current = HOME;
    private URI displayed;
    private boolean loading;
    private PageView page;
    private EditText address;
    private ScrollView scroll;
    private TextView status;
    private ProgressBar progress;
    private Button back, forward, reload;
    private android.window.OnBackInvokedCallback gestureBack;
    private boolean gestureBackRegistered;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        loader = new PageLoader(getApplicationContext());
        buildInterface();
        URI initial = state == null ? externalAddress(getIntent()) : null;
        boolean restored = false;
        if (state != null && initial == null) {
            String saved = state.getString("address");
            if (saved != null) try { initial = URI.create(saved); } catch (IllegalArgumentException ignored) { }
            ArrayList<String> savedEntries = state.getStringArrayList("history");
            if (savedEntries != null) {
                ArrayList<URI> entries = new ArrayList<>();
                for (String entry : savedEntries) try { entries.add(URI.create(entry)); } catch (IllegalArgumentException ignored) { }
                history.restore(entries, state.getInt("historyIndex", -1));
                restored = initial != null && initial.equals(history.current());
            }
        }
        if (state != null) {
            boolean[] modes = state.getBooleanArray("compatibilityHistory");
            int[] indices = state.getIntArray("webHistoryIndices");
            for (int i = 0; i < history.entries().size(); i++) {
                compatibilityEntries.add(modes != null && i < modes.length && modes[i]);
                webHistoryEntries.add(indices != null && i < indices.length ? indices[i] : -1);
            }
            Bundle webState = state.getBundle("webHistory");
            if (webState != null) restoringWebState = ensureWebView().restoreState(webState) != null;
        }
        navigate(initial == null ? HOME : initial, !restored);
        restoringWebState = false;
    }

    private int dp(float value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private GradientDrawable background(int color, int radius) {
        GradientDrawable d = new GradientDrawable(); d.setColor(color); d.setCornerRadius(dp(radius)); return d;
    }
    private Button control(String text, String description) {
        Button b = new Button(this);
        b.setText(text); b.setTextSize(24); b.setTextColor(0xff2563eb);
        b.setContentDescription(description); b.setAllCaps(false); b.setMinWidth(0); b.setMinimumWidth(0);
        b.setPadding(0, 0, 0, 0); b.setBackgroundResource(android.R.drawable.list_selector_background);
        return b;
    }
    private void buildInterface() {
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(0xfff7f8fa);
        setContentView(root);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        if (Build.VERSION.SDK_INT >= 30) {
            getWindow().setDecorFitsSystemWindows(false);
            root.setOnApplyWindowInsetsListener((v, insets) -> {
                Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                Insets ime = insets.getInsets(WindowInsets.Type.ime());
                v.setPadding(bars.left, bars.top, bars.right, Math.max(bars.bottom, ime.bottom));
                return insets;
            });
        }
        LinearLayout top = new LinearLayout(this); top.setGravity(Gravity.CENTER_VERTICAL); top.setPadding(dp(12), dp(8), dp(8), dp(8));
        address = new EditText(this); address.setId(View.generateViewId()); address.setSingleLine(true);
        address.setTextSize(15); address.setTextColor(0xff26354a); address.setHint("Enter a web address");
        address.setContentDescription("Address"); address.setSelectAllOnFocus(true);
        address.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI);
        address.setImeOptions(EditorInfo.IME_ACTION_GO); address.setPadding(dp(14), 0, dp(14), 0);
        address.setBackground(background(Color.WHITE, 14));
        top.addView(address, new LinearLayout.LayoutParams(0, dp(48), 1));
        Button go = control("→", "Go to address"); top.addView(go, new LinearLayout.LayoutParams(dp(48), dp(48)));
        go.setOnClickListener(v -> submitAddress());
        address.setOnEditorActionListener((v, action, event) -> {
            if (action == EditorInfo.IME_ACTION_GO || event != null && event.getKeyCode() == KeyEvent.KEYCODE_ENTER && event.getAction() == KeyEvent.ACTION_UP) { submitAddress(); return true; }
            return false;
        });
        root.addView(top);
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal); progress.setIndeterminate(true); progress.setVisibility(View.INVISIBLE);
        root.addView(progress, new LinearLayout.LayoutParams(-1, dp(2)));
        scroll = new ScrollView(this); scroll.setFillViewport(true); scroll.setBackgroundColor(Color.WHITE);
        page = new PageView(this); page.setOnNavigateListener(uri -> {
            if ("content".equalsIgnoreCase(uri.getScheme())) { status.setText("Open local documents using the menu"); return; }
            if ("asset".equalsIgnoreCase(uri.getScheme()) && (displayed == null || !("asset".equals(displayed.getScheme()) || "browser:demo".equals(withoutFragment(displayed))))) {
                status.setText("Remote pages cannot open local resources"); return;
            }
            navigate(uri);
        });
        scroll.addView(page, new ScrollView.LayoutParams(-1, -2));
        surfaces = new FrameLayout(this);
        surfaces.addView(scroll, new FrameLayout.LayoutParams(-1, -1));
        root.addView(surfaces, new LinearLayout.LayoutParams(-1, 0, 1));
        status = new TextView(this); status.setTextSize(11); status.setTextColor(0xff65758b); status.setSingleLine(true);
        status.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE); status.setPadding(dp(16), dp(5), dp(16), dp(3));
        root.addView(status, new LinearLayout.LayoutParams(-1, dp(25)));
        LinearLayout controls = new LinearLayout(this); controls.setGravity(Gravity.CENTER);
        back = control("‹", "Back"); forward = control("›", "Forward");
        Button home = control("⌂", "Home"); reload = control("↻", "Reload"); Button menu = control("⋮", "Menu");
        for (Button b : new Button[]{back, forward, home, reload, menu}) controls.addView(b, new LinearLayout.LayoutParams(0, dp(52), 1));
        back.setOnClickListener(v -> goBack());
        forward.setOnClickListener(v -> { URI uri = history.forward(); if (uri != null) navigate(uri, false); });
        home.setOnClickListener(v -> navigate(HOME));
        reload.setOnClickListener(v -> {
            if (loading) stop();
            else if (compatibilityVisible && web != null) web.reload();
            else navigate(current, false);
        });
        menu.setOnClickListener(this::showMenu); root.addView(controls);
        page.requestFocus();
    }

    private void submitAddress() {
        URI uri = Address.resolve(address.getText().toString());
        if (uri == null) { address.setError("Enter an HTTP or HTTPS address"); return; }
        ((InputMethodManager) getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(address.getWindowToken(), 0);
        address.clearFocus(); navigate(uri);
        if (compatibilityVisible && web != null) web.requestFocus(); else page.requestFocus();
    }
    private void showMenu(View anchor) {
        PopupMenu menu = new PopupMenu(this, anchor);
        menu.getMenu().add(0, 1, 0, "Open file");
        menu.getMenu().add(0, 2, 1, "Copy page text")
                .setEnabled(!compatibilityVisible || web != null && web.getVisibility() == View.VISIBLE);
        menu.getMenu().add(0, 3, 2, "Copy address"); menu.getMenu().add(0, 4, 3, "Sample page");
        menu.getMenu().add(0, 6, 4, compatibilityVisible ? "Use independent engine" : "Use full website")
                .setEnabled(CompatibilityPolicy.canLoad(current));
        menu.getMenu().add(0, 5, 5, "About Browser");
        menu.setOnMenuItemClickListener(item -> {
            switch (item.getItemId()) {
                case 1:
                    Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT); intent.addCategory(Intent.CATEGORY_OPENABLE); intent.setType("*/*");
                    intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[]{"text/html", "text/plain", "application/xhtml+xml"});
                    startActivityForResult(intent, OPEN_DOCUMENT); break;
                case 2:
                    if (compatibilityVisible && web != null) web.evaluateJavascript("document.body ? document.body.innerText : ''", value -> {
                        if (value == null) return;
                        try { Object decoded = new org.json.JSONTokener(value).nextValue(); if (decoded instanceof String) copy("Page text", (String) decoded); }
                        catch (org.json.JSONException ignored) { status.setText("Page text could not be copied"); }
                    });
                    else if (!compatibilityVisible) copy("Page text", page.getTextContent());
                    break;
                case 3: copy("Address", current.toString()); break;
                case 4: navigate(URI.create("browser:demo")); break;
                case 6: navigate(current, false, !compatibilityVisible); break;
                case 5: new AlertDialog.Builder(this).setTitle("Browser for Android")
                    .setMessage("Version " + getVersion() + "\n\nAn independent HTML/CSS engine with native Android controls. Reddit opens in the system WebView for JavaScript, forms, media, and sign-in. Use full website in the menu to select it for another site.\n\nFull-site cookies and website storage persist on this device; independent-engine cookies remain in memory. Some providers disallow embedded sign-in. Downloads and camera capture are not supported.")
                    .setPositiveButton("Done", null).show(); break;
                default: return false;
            }
            return true;
        }); menu.show();
    }
    private String getVersion() {
        try { return getPackageManager().getPackageInfo(getPackageName(), 0).versionName; } catch (Exception ignored) { return "0.1.0"; }
    }
    private void copy(String label, String text) {
        ((ClipboardManager) getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText(label, text));
        if (Build.VERSION.SDK_INT < 33) Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show();
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == CHOOSE_UPLOAD) {
            ValueCallback<Uri[]> callback = uploadCallback; uploadCallback = null; uploadOwner = null;
            if (callback != null) {
                Uri[] selected = WebChromeClient.FileChooserParams.parseResult(result, data);
                ArrayList<Uri> safe = new ArrayList<>();
                if (selected != null) for (Uri uri : selected) if ("content".equalsIgnoreCase(uri.getScheme())) safe.add(uri);
                callback.onReceiveValue(safe.isEmpty() ? null : safe.toArray(new Uri[0]));
            }
            return;
        }
        if (request == OPEN_DOCUMENT && result == RESULT_OK && data != null && data.getData() != null) {
            Uri uri = data.getData();
            if (!"content".equals(uri.getScheme())) return;
            if ((data.getFlags() & Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION) != 0) {
                try { getContentResolver().takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION); } catch (SecurityException ignored) { }
            }
            navigate(URI.create(uri.toString()));
        }
    }

    public void navigate(URI uri) { navigate(uri, true); }
    private void navigate(URI uri, boolean record) {
        boolean mode = record ? CompatibilityPolicy.usesCompatibility(uri)
                : history.index() >= 0 && history.index() < compatibilityEntries.size() && compatibilityEntries.get(history.index());
        navigate(uri, record, mode, true);
    }
    public void navigateCompatibility(URI uri) { navigate(uri, true, true); }
    private void navigate(URI uri, boolean record, boolean fullSite) {
        navigate(uri, record, fullSite, false);
    }
    private void navigate(URI uri, boolean record, boolean fullSite, boolean allowRedirectCompatibility) {
        if (!canNavigate(uri)) { status.setText("This address type is not supported"); return; }
        stopWork();
        int request = ++generation;
        current = uri;
        if (record) recordHistory(uri, fullSite, -1);
        else if (history.index() >= 0) compatibilityEntries.set(history.index(), fullSite);
        compatibilityVisible = fullSite && CompatibilityPolicy.canLoad(uri);
        scroll.setVisibility(compatibilityVisible ? View.GONE : View.VISIBLE);
        if (compatibilityVisible) {
            WebView view = ensureWebView();
            showCommittedOrigin(view, uri);
            address.setText(uri.toString()); updateButtons();
            view.onResume();
            setLoading(true); status.setText("Full website · Loading…");
            pendingWebNavigation = true;
            int target = history.index() >= 0 ? webHistoryEntries.get(history.index()) : -1;
            WebBackForwardList list = view.copyBackForwardList();
            if (target >= 0 && target < list.getSize() && uri.toString().equals(list.getItemAtIndex(target).getUrl())) {
                if (target != list.getCurrentIndex()) {
                    view.stopLoading(); view.goBackOrForward(target - list.getCurrentIndex());
                    return;
                }
                // restoreState has already started loading this entry. Stopping it can
                // leave a blank WebView with a populated back-forward list.
                if (restoringWebState) return;
                if (uri.equals(committedWebAddresses.get(view)) || view.getVisibility() == View.VISIBLE && uri.toString().equals(view.getUrl())) {
                    view.stopLoading(); pendingWebNavigation = false;
                    setLoading(false); status.setText("Full website · Ready");
                    return;
                }
            }
            view.stopLoading(); view.loadUrl(uri.toString());
            return;
        }
        if (web != null) { web.setVisibility(View.GONE); web.stopLoading(); web.onPause(); }
        address.setText(uri.toString()); updateButtons();
        pendingWebNavigation = false;
        if (displayed != null && withoutFragment(displayed).equals(withoutFragment(uri)) && !displayed.equals(uri)) {
            displayed = uri; setLoading(false); page.scrollToAnchor(uri.getRawFragment()); status.setText("Ready"); return;
        }
        setLoading(true); status.setText("Loading…");
        PageLoader.Cancellation token = new PageLoader.Cancellation(); cancellation = token;
        task = worker.submit(() -> {
            try {
                PageLoader.LoadedPage loaded = loader.load(uri, token);
                if (allowRedirectCompatibility && !uri.equals(loaded.url) && CompatibilityPolicy.usesCompatibility(loaded.url)) {
                    runOnUiThread(() -> {
                        if (generation == request && !isFinishing() && !isDestroyed()) navigate(loaded.url, false, true);
                    });
                    return;
                }
                Map<String, Bitmap> images = decodeImages(loaded.images, token);
                token.check();
                runOnUiThread(() -> {
                    if (generation != request || isFinishing() || isDestroyed()) return;
                    current = loaded.url; displayed = loaded.url; history.replaceCurrent(current);
                    address.setText(current.toString());
                    page.setPage(loaded.document, loaded.css, loaded.baseUri, images);
                    page.scrollToAnchor(current.getRawFragment());
                    setTitle(loaded.document.title().isEmpty() ? "Browser" : loaded.document.title());
                    status.setText(loaded.statusCode != null && loaded.statusCode >= 400 ? "HTTP " + loaded.statusCode : "Ready");
                    setLoading(false);
                });
            } catch (Exception e) {
                if (token.isCancelled()) return;
                runOnUiThread(() -> {
                    if (generation != request || isFinishing() || isDestroyed()) return;
                    String message = e.getMessage() == null ? "Check your connection and try again." : e.getMessage();
                    Html.Document error = Html.parse("<html><head><title>Page unavailable</title><style>body{padding:20px;color:#26354a}h1{font-size:30px;margin-top:36px}</style></head><body><h1>This page couldn’t be loaded.</h1><p>" + escape(message) + "</p><p>" + escape(uri.toString()) + "</p><p>Check the address or your connection, then tap Reload.</p></body></html>");
                    displayed = null; page.setPage(error, error.embeddedStyles(), uri, Collections.emptyMap());
                    page.scrollToAnchor(null); status.setText("Couldn’t load page"); setLoading(false);
                });
            }
        });
    }
    private void recordHistory(URI uri, boolean compatibility, int nativeIndex) {
        int previous = history.index();
        int previousNativeIndex = previous >= 0 ? webHistoryEntries.get(previous) : -1;
        if (compatibility && nativeIndex >= 0 && nativeIndex != previousNativeIndex) history.pushEntry(uri);
        else history.push(uri);
        if (history.index() > previous) {
            compatibilityEntries.subList(history.index(), compatibilityEntries.size()).clear();
            webHistoryEntries.subList(history.index(), webHistoryEntries.size()).clear();
            compatibilityEntries.add(compatibility); webHistoryEntries.add(nativeIndex);
        } else if (history.index() >= 0) {
            boolean previousCompatibility = compatibilityEntries.set(history.index(), compatibility);
            if (nativeIndex >= 0 || !compatibility || !previousCompatibility) webHistoryEntries.set(history.index(), nativeIndex);
        }
    }
    private void updateWebHistory(WebView view, String addressValue) {
        if (!compatibilityVisible || view != web) return;
        URI uri = webAddress(addressValue);
        if (uri == null) return;
        int nativeIndex = view.copyBackForwardList().getCurrentIndex();
        int previousIndex = history.index() >= 0 ? webHistoryEntries.get(history.index()) : -1;
        if (pendingWebNavigation || nativeIndex == previousIndex) {
            history.replaceCurrent(uri);
            if (history.index() >= 0) webHistoryEntries.set(history.index(), nativeIndex);
            pendingWebNavigation = false;
        } else recordHistory(uri, true, nativeIndex);
        showCommittedOrigin(view, uri);
        current = uri; address.setText(uri.toString()); updateButtons();
    }
    private static URI webAddress(String value) {
        if (value == null) return null;
        try { URI uri = URI.create(value); return CompatibilityPolicy.canLoad(uri) ? uri : null; }
        catch (IllegalArgumentException ignored) { return null; }
    }
    private static int originPort(URI address) {
        if (address.getPort() >= 0) return address.getPort();
        return "https".equalsIgnoreCase(address.getScheme()) ? 443 : 80;
    }
    private void showCommittedOrigin(WebView view, URI address) {
        URI committed = committedWebAddresses.get(view);
        boolean sameOrigin = committed != null && address.getScheme().equalsIgnoreCase(committed.getScheme())
                && address.getHost().equalsIgnoreCase(committed.getHost()) && originPort(address) == originPort(committed);
        view.setVisibility(sameOrigin ? View.VISIBLE : View.INVISIBLE);
    }
    @android.annotation.SuppressLint("SetJavaScriptEnabled")
    private void configureWebView(WebView view) {
        WebSettings settings = view.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setSupportMultipleWindows(true);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setBuiltInZoomControls(true); settings.setDisplayZoomControls(false);
        if (Build.VERSION.SDK_INT >= 26) settings.setSafeBrowsingEnabled(true);
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, false);
        // Keep the platform User-Agent and TLS validation; never expose a native script bridge.
        view.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView source, WebResourceRequest request) {
                return rejectWebNavigation(source, request.getUrl().toString());
            }
            @SuppressWarnings("deprecation")
            @Override public boolean shouldOverrideUrlLoading(WebView source, String target) {
                return rejectWebNavigation(source, target);
            }
            @Override public void onPageStarted(WebView source, String url, Bitmap icon) {
                if (url.equals("about:blank")) return;
                URI target = webAddress(url);
                if (target == null) { source.stopLoading(); return; }
                TextView popupAddress = popupAddresses.get(source);
                if (popupAddress != null) { showCommittedOrigin(source, target); popupAddress.setText(url); }
                if (source == web && compatibilityVisible) {
                    showCommittedOrigin(source, target);
                    compatibilityError = null; current = target; address.setText(url);
                    setLoading(true); status.setText("Full website · Loading…");
                }
            }
            @Override public void onPageCommitVisible(WebView source, String url) {
                URI committed = webAddress(url);
                if (committed == null) return;
                committedWebAddresses.put(source, committed);
                if (source == web && compatibilityVisible) showCommittedOrigin(source, current);
                TextView popupAddress = popupAddresses.get(source);
                if (popupAddress != null) {
                    URI target = webAddress(popupAddress.getText().toString());
                    if (target != null) showCommittedOrigin(source, target);
                }
            }
            @Override public void doUpdateVisitedHistory(WebView source, String url, boolean isReload) {
                updateWebHistory(source, url);
            }
            @Override public void onPageFinished(WebView source, String url) {
                if (source != web || !compatibilityVisible || webAddress(url) == null || !url.equals(source.getUrl())) return;
                updateWebHistory(source, url);
                setTitle(source.getTitle() == null ? "Browser" : source.getTitle());
                setLoading(false); status.setText(compatibilityError == null ? "Full website · Ready" : compatibilityError);
                CookieManager.getInstance().flush();
            }
            @Override public void onReceivedError(WebView source, WebResourceRequest request, WebResourceError error) {
                if (source == web && compatibilityVisible && request.isForMainFrame()) {
                    compatibilityError = "Full website · " + error.getDescription();
                    status.setText(compatibilityError); setLoading(false);
                }
            }
            @Override public void onReceivedHttpError(WebView source, WebResourceRequest request, android.webkit.WebResourceResponse response) {
                if (source == web && compatibilityVisible && request.isForMainFrame()) {
                    compatibilityError = "Full website · HTTP " + response.getStatusCode(); status.setText(compatibilityError);
                }
            }
            @Override public void onFormResubmission(WebView source, Message dontResend, Message resend) {
                if (isFinishing() || isDestroyed() || source == web && !compatibilityVisible) { dontResend.sendToTarget(); return; }
                new AlertDialog.Builder(MainActivity.this).setTitle("Submit the form again?")
                        .setMessage("Reloading this page would resend its form data.")
                        .setPositiveButton("Resend", (dialog, which) -> resend.sendToTarget())
                        .setNegativeButton("Cancel", (dialog, which) -> dontResend.sendToTarget())
                        .setOnCancelListener(dialog -> dontResend.sendToTarget()).show();
            }
            @Override public boolean onRenderProcessGone(WebView source, android.webkit.RenderProcessGoneDetail detail) {
                committedWebAddresses.remove(source);
                if (source == web) {
                    surfaces.removeView(source); source.destroy(); web = null;
                    if (compatibilityVisible) { setLoading(false); status.setText("Full website stopped. Tap Reload to reopen it."); }
                } else {
                    int index = popupViews.indexOf(source);
                    if (index >= 0) popupDialogs.get(index).dismiss();
                }
                return true;
            }
        });
        view.setWebChromeClient(new WebChromeClient() {
            @Override public void onReceivedTitle(WebView source, String title) {
                if (source == web && compatibilityVisible && title != null) setTitle(title);
            }
            @Override public boolean onCreateWindow(WebView source, boolean isDialog, boolean isUserGesture, Message result) {
                if (!isUserGesture || isFinishing() || isDestroyed()) return false;
                WebView child = new WebView(MainActivity.this); configureWebView(child);
                Dialog popup = new Dialog(MainActivity.this);
                LinearLayout content = new LinearLayout(MainActivity.this); content.setOrientation(LinearLayout.VERTICAL);
                LinearLayout header = new LinearLayout(MainActivity.this); header.setGravity(Gravity.CENTER_VERTICAL);
                TextView label = new TextView(MainActivity.this); label.setText("Opening website…"); label.setPadding(dp(12), dp(8), dp(12), dp(8));
                label.setContentDescription("Website address"); label.setTextIsSelectable(true);
                label.setMaxLines(2); label.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE);
                Button close = new Button(MainActivity.this); close.setText("Close"); close.setOnClickListener(v -> popup.dismiss());
                header.addView(label, new LinearLayout.LayoutParams(0, -2, 1)); header.addView(close);
                content.addView(header); content.addView(child, new LinearLayout.LayoutParams(-1, 0, 1));
                popup.setContentView(content); popupViews.add(child); popupDialogs.add(popup); popupAddresses.put(child, label);
                popup.setOnDismissListener(dialog -> {
                    if (uploadOwner == child && uploadCallback != null) {
                        uploadCallback.onReceiveValue(null); uploadCallback = null; uploadOwner = null;
                    }
                    popupViews.remove(child); popupDialogs.remove(popup); popupAddresses.remove(child); committedWebAddresses.remove(child);
                    child.stopLoading(); child.destroy();
                    CookieManager.getInstance().flush();
                });
                popup.show();
                if (popup.getWindow() != null) popup.getWindow().setLayout(-1, -1);
                WebView.WebViewTransport transport = (WebView.WebViewTransport) result.obj;
                transport.setWebView(child); result.sendToTarget();
                return true;
            }
            @Override public void onCloseWindow(WebView source) {
                int index = popupViews.indexOf(source);
                if (index >= 0) popupDialogs.get(index).dismiss();
            }
            @Override public boolean onShowFileChooser(WebView source, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (uploadCallback != null) uploadCallback.onReceiveValue(null);
                uploadCallback = callback; uploadOwner = source;
                Intent chooser = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
                ArrayList<String> mimeTypes = new ArrayList<>();
                for (String accept : params.getAcceptTypes()) if (accept.matches("[A-Za-z0-9.+*-]+/[A-Za-z0-9.+*-]+")) mimeTypes.add(accept);
                if (!mimeTypes.isEmpty()) chooser.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toArray(new String[0]));
                chooser.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE);
                chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                try { startActivityForResult(chooser, CHOOSE_UPLOAD); }
                catch (android.content.ActivityNotFoundException error) {
                    uploadCallback.onReceiveValue(null); uploadCallback = null; uploadOwner = null;
                    status.setText("No document picker is available");
                }
                return true;
            }
        });
    }
    private boolean rejectWebNavigation(WebView source, String target) {
        if (target.equals("about:blank") && source != web) return false;
        if (webAddress(target) != null) return false;
        if (source == web && compatibilityVisible) status.setText("Full website · Only HTTP and HTTPS links can open here");
        return true;
    }
    private WebView ensureWebView() {
        if (web == null) {
            web = new WebView(this); configureWebView(web);
            web.setVisibility(compatibilityVisible ? View.INVISIBLE : View.GONE);
            surfaces.addView(web, new FrameLayout.LayoutParams(-1, -1));
        }
        return web;
    }
    private boolean canNavigate(URI uri) {
        if (uri == null) return false;
        String scheme = uri.getScheme();
        if ("http".equalsIgnoreCase(scheme) || "https".equalsIgnoreCase(scheme)) return Address.resolve(uri.toString()) != null;
        if ("browser:home".equals(withoutFragment(uri)) || "browser:demo".equals(withoutFragment(uri))) return true;
        // History/recreation may restore bundled demo pages; the page callback separately checks its origin.
        if ("asset".equals(scheme)) return uri.getPath() != null && uri.normalize().getPath().startsWith("/demo/")
                && PageLoader.resourceAllowed(uri, URI.create("asset:/demo/index.html"));
        if ("content".equals(scheme)) return checkUriPermission(Uri.parse(uri.toString()), android.os.Process.myPid(), android.os.Process.myUid(), Intent.FLAG_GRANT_READ_URI_PERMISSION) == android.content.pm.PackageManager.PERMISSION_GRANTED;
        return false;
    }
    private static String withoutFragment(URI uri) { String s = uri.toString(); int i = s.indexOf('#'); return i < 0 ? s : s.substring(0, i); }
    private static Map<String, Bitmap> decodeImages(Map<String, byte[]> encoded, PageLoader.Cancellation token) throws java.io.IOException {
        Map<String, Bitmap> decoded = new LinkedHashMap<>(); long total = 0;
        for (Map.Entry<String, byte[]> entry : encoded.entrySet()) {
            token.check(); byte[] bytes = entry.getValue(); BitmapFactory.Options bounds = new BitmapFactory.Options(); bounds.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0 || bounds.outWidth > 8192 || bounds.outHeight > 8192) continue;
            BitmapFactory.Options options = new BitmapFactory.Options(); options.inSampleSize = 1;
            while ((long) (bounds.outWidth / options.inSampleSize) * (bounds.outHeight / options.inSampleSize) > 4_000_000) options.inSampleSize *= 2;
            long expected = (long) (bounds.outWidth / options.inSampleSize) * (bounds.outHeight / options.inSampleSize) * 4;
            if (total + expected > 32_000_000) continue;
            Bitmap image = BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
            if (image != null) { total += image.getAllocationByteCount(); decoded.put(entry.getKey(), image); }
        }
        return decoded;
    }
    private void setLoading(boolean value) {
        loading = value; progress.setVisibility(value ? View.VISIBLE : View.INVISIBLE);
        reload.setText(value ? "×" : "↻"); reload.setContentDescription(value ? "Stop" : "Reload"); updateButtons();
    }
    private void updateButtons() {
        back.setEnabled(history.canGoBack()); forward.setEnabled(history.canGoForward()); back.setAlpha(back.isEnabled() ? 1 : .3f); forward.setAlpha(forward.isEnabled() ? 1 : .3f);
        if (Build.VERSION.SDK_INT >= 33) {
            if (gestureBack == null) gestureBack = this::goBack;
            if (history.canGoBack() && !gestureBackRegistered) {
                getOnBackInvokedDispatcher().registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, gestureBack);
                gestureBackRegistered = true;
            } else if (!history.canGoBack() && gestureBackRegistered) {
                getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback(gestureBack); gestureBackRegistered = false;
            }
        }
    }
    private void stopWork() { if (cancellation != null) cancellation.cancel(); if (task != null) task.cancel(true); }
    public void stop() {
        ++generation; stopWork(); if (web != null) web.stopLoading(); pendingWebNavigation = false;
        setLoading(false); status.setText(compatibilityVisible ? "Full website · Stopped" : "Stopped");
    }
    public void goBack() { URI uri = history.back(); if (uri != null) navigate(uri, false); }
    // API 33+ uses the native OnBackInvokedDispatcher above; this handles older Android versions.
    @android.annotation.SuppressLint("GestureBackNavigation")
    @Override public void onBackPressed() { if (history.canGoBack()) goBack(); else super.onBackPressed(); }
    @Override protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state); state.putString("address", current.toString());
        ArrayList<String> entries = new ArrayList<>(); for (URI entry : history.entries()) entries.add(entry.toString());
        state.putStringArrayList("history", entries); state.putInt("historyIndex", history.index());
        boolean[] modes = new boolean[compatibilityEntries.size()]; int[] indices = new int[webHistoryEntries.size()];
        for (int i = 0; i < modes.length; i++) modes[i] = compatibilityEntries.get(i);
        for (int i = 0; i < indices.length; i++) indices[i] = webHistoryEntries.get(i);
        state.putBooleanArray("compatibilityHistory", modes); state.putIntArray("webHistoryIndices", indices);
        if (web != null) { Bundle webState = new Bundle(); web.saveState(webState); state.putBundle("webHistory", webState); }
    }
    @Override protected void onPause() {
        // A login may set cookies through fetch without finishing a new page load.
        if (web != null || !popupViews.isEmpty()) CookieManager.getInstance().flush();
        if (web != null) web.onPause();
        for (WebView popup : popupViews) popup.onPause();
        super.onPause();
    }
    @Override protected void onResume() {
        super.onResume();
        if (web != null && compatibilityVisible) web.onResume();
        for (WebView popup : popupViews) popup.onResume();
    }
    @Override protected void onDestroy() {
        ++generation; stopWork(); worker.shutdownNow();
        if (uploadCallback != null) { uploadCallback.onReceiveValue(null); uploadCallback = null; }
        for (Dialog popup : new ArrayList<>(popupDialogs)) popup.dismiss();
        if (web != null) { surfaces.removeView(web); web.destroy(); }
        if (Build.VERSION.SDK_INT >= 33 && gestureBackRegistered) getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback(gestureBack);
        super.onDestroy();
    }
    private static URI externalAddress(Intent intent) {
        if (intent == null || !Intent.ACTION_VIEW.equals(intent.getAction()) || intent.getDataString() == null) return null;
        return Address.resolve(intent.getDataString());
    }
    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); URI uri = externalAddress(intent); if (uri != null) navigate(uri); }
    private static String escape(String s) { return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;"); }
    public PageView getPageView() { return page; }
    public WebView getCompatibilityView() { return web; }
    public boolean isCompatibilityVisible() { return compatibilityVisible; }
    public URI getCurrentAddress() { return current; }
    public boolean isLoading() { return loading; }
    public ScrollView getPageScroll() { return scroll; }
}
