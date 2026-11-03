package com.culpen.browser;

import android.app.Activity;
import android.app.AlertDialog;
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
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.EditText;
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

/** Native Android shell around the independent HTML/CSS engine. */
public final class MainActivity extends Activity {
    private static final URI HOME = URI.create("browser:home");
    private static final int OPEN_DOCUMENT = 10;
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
        navigate(initial == null ? HOME : initial, !restored);
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
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
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
        reload.setOnClickListener(v -> { if (loading) stop(); else navigate(current, false); });
        menu.setOnClickListener(this::showMenu); root.addView(controls);
        page.requestFocus();
    }

    private void submitAddress() {
        URI uri = Address.resolve(address.getText().toString());
        if (uri == null) { address.setError("Enter an HTTP or HTTPS address"); return; }
        ((InputMethodManager) getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(address.getWindowToken(), 0);
        address.clearFocus(); page.requestFocus(); navigate(uri);
    }
    private void showMenu(View anchor) {
        PopupMenu menu = new PopupMenu(this, anchor);
        menu.getMenu().add(0, 1, 0, "Open file"); menu.getMenu().add(0, 2, 1, "Copy page text");
        menu.getMenu().add(0, 3, 2, "Copy address"); menu.getMenu().add(0, 4, 3, "Sample page"); menu.getMenu().add(0, 5, 4, "About Browser");
        menu.setOnMenuItemClickListener(item -> {
            switch (item.getItemId()) {
                case 1:
                    Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT); intent.addCategory(Intent.CATEGORY_OPENABLE); intent.setType("*/*");
                    intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[]{"text/html", "text/plain", "application/xhtml+xml"});
                    startActivityForResult(intent, OPEN_DOCUMENT); break;
                case 2: copy("Page text", page.getTextContent()); break;
                case 3: copy("Address", current.toString()); break;
                case 4: navigate(URI.create("browser:demo")); break;
                case 5: new AlertDialog.Builder(this).setTitle("Browser for Android")
                    .setMessage("Version " + getVersion() + "\n\nAn independent HTML/CSS engine with native Android controls.\n\nBuilt for reading simple pages. JavaScript, interactive forms, tabs, and downloads are not supported yet. Browsing history and cookies stay in memory for this session.")
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
        if (!canNavigate(uri)) { status.setText("This address type is not supported"); return; }
        stopWork();
        int request = ++generation;
        current = uri; if (record) history.push(uri);
        address.setText(uri.toString()); updateButtons();
        if (displayed != null && withoutFragment(displayed).equals(withoutFragment(uri)) && !displayed.equals(uri)) {
            displayed = uri; setLoading(false); page.scrollToAnchor(uri.getRawFragment()); status.setText("Ready"); return;
        }
        setLoading(true); status.setText("Loading…");
        PageLoader.Cancellation token = new PageLoader.Cancellation(); cancellation = token;
        task = worker.submit(() -> {
            try {
                PageLoader.LoadedPage loaded = loader.load(uri, token);
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
    public void stop() { ++generation; stopWork(); setLoading(false); status.setText("Stopped"); }
    public void goBack() { URI uri = history.back(); if (uri != null) navigate(uri, false); }
    // API 33+ uses the native OnBackInvokedDispatcher above; this handles older Android versions.
    @android.annotation.SuppressLint("GestureBackNavigation")
    @Override public void onBackPressed() { if (history.canGoBack()) goBack(); else super.onBackPressed(); }
    @Override protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state); state.putString("address", current.toString());
        ArrayList<String> entries = new ArrayList<>(); for (URI entry : history.entries()) entries.add(entry.toString());
        state.putStringArrayList("history", entries); state.putInt("historyIndex", history.index());
    }
    @Override protected void onDestroy() {
        ++generation; stopWork(); worker.shutdownNow();
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
    public URI getCurrentAddress() { return current; }
    public boolean isLoading() { return loading; }
    public ScrollView getPageScroll() { return scroll; }
}
