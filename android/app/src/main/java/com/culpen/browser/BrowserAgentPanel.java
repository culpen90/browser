package com.culpen.browser;

import android.app.Activity;
import android.app.AlertDialog;
import android.graphics.Color;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.function.Supplier;

/** A dismissible native sidebar. Closing it keeps the current task running. */
final class BrowserAgentPanel extends LinearLayout {
    private final Activity activity;
    private final MobileBrowserAgent.Host browser;
    private final AgentPairingStore store;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final TextView state, pc, log;
    private final ScrollView logScroll;
    private final EditText task;
    private final Button run, stop, pair;
    private AgentConnection connection;
    private Future<?> running;
    private int runID;
    private boolean destroyed;
    private AlertDialog review;
    private CompletableFuture<Boolean> reviewResult;

    BrowserAgentPanel(Activity activity, MobileBrowserAgent.Host browser) {
        super(activity);
        this.activity = activity; this.browser = browser;
        store = new AgentPairingStore(activity); connection = store.load();
        setOrientation(VERTICAL); setPadding(dp(16), dp(10), dp(16), dp(12));
        setBackgroundColor(0xfff7f8fa); setElevation(dp(12)); setVisibility(GONE);
        LinearLayout heading = new LinearLayout(activity); heading.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = label("AI Agent", 20); title.setTypeface(null, android.graphics.Typeface.BOLD);
        heading.addView(title, new LayoutParams(0, -2, 1));
        Button close = button("×", "Close agent");
        close.setTextSize(25); close.setOnClickListener(view -> hide());
        heading.addView(close, new LayoutParams(dp(44), dp(44))); addView(heading);
        ScrollView bodyScroll = new ScrollView(activity);
        bodyScroll.setFillViewport(true);
        LinearLayout body = new LinearLayout(activity); body.setOrientation(VERTICAL);
        state = label("Ready", 12); body.addView(state);
        pc = label("", 12); pc.setTextIsSelectable(false); body.addView(pc);
        LinearLayout connectionRow = new LinearLayout(activity);
        pair = button("Connect PC", "Connect PC"); pair.setOnClickListener(view -> showPairingInput());
        Button disconnect = button("Disconnect", "Disconnect PC");
        disconnect.setOnClickListener(view -> {
            stop(); connection = null; store.clear(); updatePC(); state.setText("Disconnected");
        });
        connectionRow.addView(pair, new LayoutParams(0, -2, 1));
        connectionRow.addView(disconnect, new LayoutParams(0, -2, 1)); body.addView(connectionRow);
        task = new EditText(activity); task.setHint("Ask about this page or give a browsing task");
        task.setContentDescription("Agent task"); task.setTextSize(15); task.setTextColor(0xff26354a);
        task.setGravity(Gravity.TOP); task.setMinLines(2); task.setMaxLines(3);
        task.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        task.setImportantForAutofill(IMPORTANT_FOR_AUTOFILL_NO);
        body.addView(task, new LayoutParams(-1, -2));
        LinearLayout controls = new LinearLayout(activity);
        run = button("Run", "Run agent"); stop = button("Stop", "Stop agent");
        run.setOnClickListener(view -> runTask()); stop.setOnClickListener(view -> stop());
        controls.addView(run, new LayoutParams(0, -2, 1)); controls.addView(stop, new LayoutParams(0, -2, 1)); body.addView(controls);
        logScroll = new ScrollView(activity); logScroll.setFillViewport(true);
        log = label("Open Browser on your PC, open its agent, and choose Connect Phone. Scan the QR code or paste its pairing link here.", 14);
        log.setContentDescription("Agent activity"); log.setTextIsSelectable(true);
        log.setPadding(0, dp(8), 0, dp(8));
        logScroll.addView(log, new ScrollView.LayoutParams(-1, -2));
        logScroll.setNestedScrollingEnabled(true);
        body.addView(logScroll, new LayoutParams(-1, dp(220)));
        TextView footer = label("The paired PC runs the model. Tasks and page text travel encrypted over your local network.", 11);
        footer.setPadding(0, dp(6), 0, 0); body.addView(footer);
        bodyScroll.addView(body, new ScrollView.LayoutParams(-1, -2));
        addView(bodyScroll, new LayoutParams(-1, 0, 1));
        updatePC(); updateControls();
    }

    private int dp(float value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private TextView label(String text, float size) {
        TextView view = new TextView(activity); view.setText(text); view.setTextSize(size); view.setTextColor(0xff26354a);
        return view;
    }
    private Button button(String text, String description) {
        Button view = new Button(activity); view.setText(text); view.setAllCaps(false); view.setTextSize(14);
        view.setMinWidth(0); view.setMinimumWidth(0); view.setContentDescription(description); return view;
    }
    void toggle() { if (getVisibility() == VISIBLE) hide(); else show(); }
    void show() { setVisibility(VISIBLE); updatePC(); }
    void hide() {
        ((android.view.inputmethod.InputMethodManager) activity.getSystemService(Activity.INPUT_METHOD_SERVICE))
                .hideSoftInputFromWindow(task.getWindowToken(), 0);
        setVisibility(GONE);
    }
    boolean isOpen() { return getVisibility() == VISIBLE; }
    String logText() { return log.getText().toString(); }

    void offerPairing(String link) {
        final AgentConnection proposed;
        try { proposed = AgentConnection.parse(link); }
        catch (IllegalArgumentException error) { show(); state.setText(error.getMessage()); return; }
        show();
        new AlertDialog.Builder(activity).setTitle("Connect this PC?")
                .setMessage(proposed.label() + "\n\nYour browsing tasks and page text will be sent encrypted to this PC for local AI processing.")
                .setPositiveButton("Connect", (dialog, which) -> connect(link))
                .setNegativeButton("Cancel", null).show();
    }

    private void showPairingInput() {
        EditText field = new EditText(activity); field.setHint("browseragent://pair?…"); field.setSingleLine(true);
        field.setContentDescription("PC pairing link");
        field.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        field.setImportantForAutofill(IMPORTANT_FOR_AUTOFILL_NO);
        field.setPadding(dp(20), dp(12), dp(20), dp(12));
        AlertDialog dialog = new AlertDialog.Builder(activity).setTitle("Connect to your PC")
                .setMessage("On your PC, open Browser’s agent and choose Connect Phone. Paste its pairing link. Keep both devices on the same local network.")
                .setView(field).setPositiveButton("Connect", null).setNegativeButton("Cancel", null).create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(view -> {
            if (connect(field.getText().toString())) { field.setText(""); dialog.dismiss(); }
            else field.setError("Use the complete pairing link from your PC");
        }));
        dialog.show();
    }

    boolean connect(String link) {
        try {
            AgentConnection proposed = AgentConnection.parse(link);
            store.save(link);
            stop(); connection = proposed; updatePC(); state.setText("Paired · Ready");
            append("Paired with PC at " + proposed.label() + ".");
            return true;
        } catch (Exception error) {
            state.setText("Couldn’t save this pairing link. Check the link and try again.");
            return false;
        }
    }

    private void updatePC() { pc.setText(connection == null ? "No PC connected" : "PC · " + connection.label()); }
    private void updateControls() {
        boolean busy = running != null;
        run.setEnabled(!busy); stop.setEnabled(busy); pair.setEnabled(!busy); task.setEnabled(!busy);
    }
    private void append(String text) {
        String existing = log.getText().toString();
        if (existing.length() > 16_000) existing = existing.substring(existing.length() - 12_000);
        log.setText(existing.isEmpty() ? text : existing + "\n\n" + text);
        logScroll.post(() -> logScroll.fullScroll(FOCUS_DOWN));
    }

    private void runTask() {
        if (running != null) return;
        String instruction = task.getText().toString().trim();
        if (instruction.isEmpty()) { task.setError("Enter a browsing task"); return; }
        if (instruction.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 1600) {
            task.setError("Enter a task up to 1,600 bytes"); return;
        }
        String directReply = MobileBrowserAgent.directReply(instruction);
        if (directReply != null) {
            hideKeyboard(); log.setText(directReply); state.setText("Complete"); return;
        }
        if (connection == null) { showPairingInput(); return; }
        hideKeyboard();
        log.setText(""); state.setText("Running on PC…");
        int id = ++runID;
        AgentConnection endpoint = connection;
        MobileBrowserAgent.Host guarded = new MobileBrowserAgent.Host() {
            @Override public CompletableFuture<MobileBrowserAgent.Snapshot> observe() { return dispatch(id, browser::observe); }
            @Override public CompletableFuture<Void> act(MobileBrowserAgent.Command command, MobileBrowserAgent.Snapshot page, boolean approved) {
                return dispatch(id, () -> browser.act(command, page, approved));
            }
            @Override public CompletableFuture<Boolean> approve(String message) {
                return dispatch(id, () -> requestApproval(message));
            }
            @Override public void activity(String message) { main.post(() -> { if (id == runID && !destroyed) append(message); }); }
            @Override public void cancel() { main.post(browser::cancel); }
        };
        running = worker.submit(() -> {
            try {
                String answer = new MobileBrowserAgent(endpoint, guarded).run(instruction);
                main.post(() -> finish(id, "Complete", answer));
            } catch (Exception error) {
                String message = error.getMessage();
                if (message == null || message.isEmpty()) message = "Couldn’t reach the PC. Check Connect Phone on the PC and the local network.";
                String detail = message;
                main.post(() -> finish(id, "Couldn’t finish", detail));
            }
        });
        updateControls();
    }

    private <T> CompletableFuture<T> dispatch(int id, Supplier<CompletableFuture<T>> action) {
        CompletableFuture<T> result = new CompletableFuture<>();
        main.post(() -> {
            if (id != runID || destroyed) { result.cancel(false); return; }
            try {
                action.get().whenComplete((value, error) -> {
                    if (id != runID || destroyed) result.cancel(false);
                    else if (error != null) result.completeExceptionally(error);
                    else result.complete(value);
                });
            } catch (Exception error) { result.completeExceptionally(error); }
        });
        return result;
    }

    private CompletableFuture<Boolean> requestApproval(String message) {
        reviewResult = new CompletableFuture<>();
        review = new AlertDialog.Builder(activity).setTitle("Review agent action").setMessage(message)
                .setPositiveButton("Allow", (dialog, which) -> resolveReview(true))
                .setNegativeButton("Skip", (dialog, which) -> resolveReview(false))
                .setOnCancelListener(dialog -> resolveReview(false)).create();
        review.show(); state.setText("Waiting for review");
        return reviewResult;
    }
    private void resolveReview(boolean approved) {
        CompletableFuture<Boolean> result = reviewResult;
        reviewResult = null;
        if (review != null) { review.dismiss(); review = null; }
        if (result != null) result.complete(approved);
        if (running != null) state.setText("Running on PC…");
    }
    void stop() {
        runID++;
        if (running != null) { running.cancel(true); running = null; state.setText("Stopped"); append("Stopped by you."); }
        if (connection != null) connection.cancel();
        browser.cancel(); resolveReview(false); updateControls();
    }
    private void finish(int id, String status, String text) {
        if (id != runID || destroyed) return;
        resolveReview(false);
        running = null; state.setText(status); append(text); updateControls();
    }
    void destroy() { destroyed = true; stop(); worker.shutdownNow(); }
    private void hideKeyboard() {
        ((android.view.inputmethod.InputMethodManager) activity.getSystemService(Activity.INPUT_METHOD_SERVICE))
                .hideSoftInputFromWindow(task.getWindowToken(), 0);
    }
}
