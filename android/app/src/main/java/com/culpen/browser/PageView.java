package com.culpen.browser;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewParent;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityManager;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityNodeProvider;
import android.widget.ScrollView;

import com.culpen.browser.engine.Css;
import com.culpen.browser.engine.Html;

import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** A bounded display list from our own HTML/CSS layout engine, drawn using Canvas primitives. */
public final class PageView extends View {
    public interface NavigationListener { void onNavigate(URI uri); }
    private static final int MAX_ITEMS = 40_000;
    private static final int MAX_VISITED_NODES = 20_000;
    private static final int MAX_TEXT_CHARACTERS = 500_000;
    private static final long MAX_LAYOUT_NANOS = 250_000_000L;
    private static final int MIN_TIMED_NODES = 1_000;
    private static final int MIN_TIMED_ITEMS = 1_000;
    private static final int MIN_TIMED_CHARACTERS = 16_384;
    private static final float MAX_HEIGHT = 4_000_000;
    private static final int NO_ID = Integer.MIN_VALUE;
    private Html.Document document;
    private Css.StyleSheet sheet = new Css.StyleSheet("");
    private URI baseUri = URI.create("browser:home");
    private Map<String, Bitmap> images = Collections.emptyMap();
    private NavigationListener navigationListener;
    private Layout layout = new Layout();
    private int layoutWidth = -1;
    private int focusedLink = -1;
    private int accessibilityFocus = NO_ID;
    private int hovered = NO_ID;
    private URI pressedLink;
    private float downX, downY;
    private boolean moved;
    private String pendingFragment;
    private final Paint decoration = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final NodeProvider nodeProvider = new NodeProvider();

    public PageView(Context context) {
        super(context);
        setFocusable(true);
        setFocusableInTouchMode(true);
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_YES);
        setContentDescription("Web page");
    }

    public void setOnNavigateListener(NavigationListener listener) { navigationListener = listener; }

    public void setPage(Html.Document document, String css, URI baseUri, Map<String, Bitmap> images) {
        this.document = document;
        this.sheet = new Css.StyleSheet(css == null ? "" : css);
        this.baseUri = baseUri;
        this.images = images == null ? Collections.emptyMap() : images;
        this.layoutWidth = -1;
        this.focusedLink = -1;
        this.accessibilityFocus = NO_ID;
        this.hovered = NO_ID;
        this.pendingFragment = baseUri.getRawFragment();
        requestLayout();
        invalidate();
        sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED);
    }

    public String getTextContent() { return layout.text; }
    public int getLinkCount() { return layout.links.size(); }

    /** Positions are in this View's coordinate space, useful to hosts and instrumentation. */
    public RectF getLinkBounds(int index) {
        return index >= 0 && index < layout.links.size() ? new RectF(layout.links.get(index).rect) : null;
    }

    public URI getLinkUri(int index) {
        return index >= 0 && index < layout.links.size() ? layout.links.get(index).link : null;
    }

    public void scrollToAnchor(String fragment) {
        if (layoutWidth < 0) { pendingFragment = fragment; return; }
        String decoded = fragment;
        try {
            if (fragment != null) decoded = URLDecoder.decode(fragment.replace("+", "%2B"), StandardCharsets.UTF_8.name());
        } catch (Exception ignored) { }
        final int position = Math.round(layout.anchors.getOrDefault(decoded, 0f));
        ViewParent parent = getParent();
        if (parent instanceof ScrollView) ((ScrollView) parent).scrollTo(0, position);
        else requestRectangleOnScreen(new Rect(0, position, Math.max(1, getWidth()), position + 1), true);
    }

    @Override protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        int width = Math.max(1, MeasureSpec.getSize(widthMeasureSpec));
        if (document != null && width != layoutWidth) {
            layoutWidth = width;
            layout = new Layouter(width).build(document);
            post(() -> {
                scrollToAnchor(pendingFragment);
                pendingFragment = null;
                sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED);
            });
        }
        int height = Math.max(getSuggestedMinimumHeight(), (int) Math.ceil(layout.height));
        setMeasuredDimension(resolveSize(width, widthMeasureSpec), resolveSize(height, heightMeasureSpec));
    }

    @Override protected void onDraw(Canvas canvas) {
        canvas.drawColor(layout.background);
        RectF clip = new RectF(canvas.getClipBounds());
        for (Item item : layout.items) {
            if (!RectF.intersects(item.rect, clip)) continue;
            if (item.text != null) {
                canvas.drawText(item.text, item.rect.left, item.rect.top - item.paint.ascent(), item.paint);
            } else if (item.bitmap != null) {
                decoration.setFilterBitmap(true);
                canvas.drawBitmap(item.bitmap, null, item.rect, decoration);
            } else {
                decoration.setColor(item.color);
                decoration.setStyle(Paint.Style.FILL);
                canvas.drawRect(item.rect, decoration);
            }
        }
        if (focusedLink >= 0 && focusedLink < layout.links.size()) drawFocus(canvas, layout.links.get(focusedLink).rect);
        if (accessibilityFocus >= 0 && accessibilityFocus < layout.segments.size()) drawFocus(canvas, layout.segments.get(accessibilityFocus).rect);
    }

    private void drawFocus(Canvas canvas, RectF rect) {
        decoration.setColor(0xff2563eb);
        decoration.setStyle(Paint.Style.STROKE);
        decoration.setStrokeWidth(dp(2));
        RectF outline = new RectF(rect);
        outline.inset(-dp(2), -dp(1));
        canvas.drawRoundRect(outline, dp(2), dp(2), decoration);
        decoration.setStyle(Paint.Style.FILL);
    }

    private URI linkAt(float x, float y) {
        for (int i = layout.items.size() - 1; i >= 0; i--) {
            Item item = layout.items.get(i);
            if (item.link != null && item.rect.contains(x, y)) return item.link;
        }
        return null;
    }

    @Override public boolean onTouchEvent(MotionEvent event) {
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                downX = event.getX(); downY = event.getY(); moved = false;
                pressedLink = linkAt(downX, downY);
                return true;
            case MotionEvent.ACTION_MOVE:
                if (Math.hypot(event.getX() - downX, event.getY() - downY) > ViewConfiguration.get(getContext()).getScaledTouchSlop()) moved = true;
                return true;
            case MotionEvent.ACTION_UP:
                URI uri = linkAt(event.getX(), event.getY());
                if (!moved && uri != null && uri.equals(pressedLink)) {
                    performClick();
                    if (navigationListener != null) navigationListener.onNavigate(uri);
                }
                pressedLink = null;
                return true;
            case MotionEvent.ACTION_CANCEL:
                pressedLink = null;
                return true;
            default: return super.onTouchEvent(event);
        }
    }

    @Override public boolean performClick() { super.performClick(); return true; }

    @Override public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_TAB && !layout.links.isEmpty()) {
            int direction = event.isShiftPressed() ? -1 : 1;
            if (focusedLink < 0) focusedLink = event.isShiftPressed() ? layout.links.size() - 1 : 0;
            else focusedLink = (focusedLink + direction + layout.links.size()) % layout.links.size();
            Item item = layout.links.get(focusedLink);
            Rect rect = new Rect(); item.rect.roundOut(rect); rect.inset(-(int) dp(8), -(int) dp(8));
            requestRectangleOnScreen(rect, false);
            invalidate(); return true;
        }
        if ((keyCode == KeyEvent.KEYCODE_ENTER || keyCode == KeyEvent.KEYCODE_DPAD_CENTER) && focusedLink >= 0 && focusedLink < layout.links.size()) {
            if (navigationListener != null) navigationListener.onNavigate(layout.links.get(focusedLink).link);
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override public AccessibilityNodeProvider getAccessibilityNodeProvider() { return nodeProvider; }

    @Override public boolean dispatchHoverEvent(MotionEvent event) {
        AccessibilityManager manager = (AccessibilityManager) getContext().getSystemService(Context.ACCESSIBILITY_SERVICE);
        if (manager != null && manager.isTouchExplorationEnabled()) {
            int id = NO_ID;
            if (event.getActionMasked() != MotionEvent.ACTION_HOVER_EXIT) {
                for (int i = 0; i < layout.segments.size(); i++) if (layout.segments.get(i).rect.contains(event.getX(), event.getY())) { id = i; break; }
            }
            if (id != hovered) {
                int previous = hovered; hovered = id;
                if (id != NO_ID) sendVirtualEvent(id, AccessibilityEvent.TYPE_VIEW_HOVER_ENTER);
                if (previous != NO_ID) sendVirtualEvent(previous, AccessibilityEvent.TYPE_VIEW_HOVER_EXIT);
            }
            return id != NO_ID;
        }
        return super.dispatchHoverEvent(event);
    }

    private void sendVirtualEvent(int id, int type) {
        if (id < 0 || id >= layout.segments.size() || getParent() == null) return;
        AccessibilityEvent event = AccessibilityEvent.obtain(type);
        event.setSource(this, id);
        event.setClassName(layout.segments.get(id).link == null ? "android.widget.TextView" : "android.widget.Button");
        event.setPackageName(getContext().getPackageName());
        event.getText().add(layout.segments.get(id).label);
        getParent().requestSendAccessibilityEvent(this, event);
    }

    private final class NodeProvider extends AccessibilityNodeProvider {
        @Override public AccessibilityNodeInfo createAccessibilityNodeInfo(int id) {
            if (id == View.NO_ID) {
                AccessibilityNodeInfo info = AccessibilityNodeInfo.obtain(PageView.this);
                onInitializeAccessibilityNodeInfo(info);
                for (int i = 0; i < layout.segments.size(); i++) info.addChild(PageView.this, i);
                return info;
            }
            if (id < 0 || id >= layout.segments.size()) return null;
            Segment item = layout.segments.get(id);
            AccessibilityNodeInfo info = AccessibilityNodeInfo.obtain();
            info.setSource(PageView.this, id);
            info.setParent(PageView.this);
            info.setPackageName(getContext().getPackageName());
            info.setClassName(item.link == null ? "android.widget.TextView" : "android.widget.Button");
            info.setText(item.label);
            info.setEnabled(true);
            info.setFocusable(true);
            Rect bounds = new Rect(); item.rect.roundOut(bounds);
            info.setBoundsInParent(bounds);
            int[] location = new int[2]; getLocationOnScreen(location);
            bounds.offset(location[0], location[1]);
            Rect visible = new Rect();
            info.setVisibleToUser(isShown() && getGlobalVisibleRect(visible) && Rect.intersects(bounds, visible));
            info.setBoundsInScreen(bounds);
            info.setAccessibilityFocused(accessibilityFocus == id);
            info.addAction(accessibilityFocus == id ? AccessibilityNodeInfo.AccessibilityAction.ACTION_CLEAR_ACCESSIBILITY_FOCUS : AccessibilityNodeInfo.AccessibilityAction.ACTION_ACCESSIBILITY_FOCUS);
            if (item.link != null) {
                info.setClickable(true);
                info.setContentDescription(item.label + ", link");
                info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_CLICK);
            }
            return info;
        }

        @Override public boolean performAction(int id, int action, Bundle arguments) {
            if (id == View.NO_ID) return PageView.this.performAccessibilityAction(action, arguments);
            if (id < 0 || id >= layout.segments.size()) return false;
            Segment item = layout.segments.get(id);
            if (action == AccessibilityNodeInfo.ACTION_CLICK && item.link != null && navigationListener != null) {
                navigationListener.onNavigate(item.link); return true;
            }
            if (action == AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS) {
                if (accessibilityFocus != NO_ID) sendVirtualEvent(accessibilityFocus, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED);
                accessibilityFocus = id;
                Rect rect = new Rect(); item.rect.roundOut(rect); requestRectangleOnScreen(rect, false);
                sendVirtualEvent(id, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED);
                invalidate(); return true;
            }
            if (action == AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS && accessibilityFocus == id) {
                accessibilityFocus = NO_ID;
                sendVirtualEvent(id, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED);
                invalidate(); return true;
            }
            return false;
        }

        @Override public AccessibilityNodeInfo findFocus(int focus) {
            return focus == AccessibilityNodeInfo.FOCUS_ACCESSIBILITY && accessibilityFocus != NO_ID ? createAccessibilityNodeInfo(accessibilityFocus) : null;
        }
    }

    private static final class Item {
        RectF rect;
        String text;
        Paint paint;
        Bitmap bitmap;
        URI link;
        int color;
        String alt;
        boolean notice;
        Item(RectF rect) { this.rect = rect; }
    }
    private static final class Segment {
        String label;
        final RectF rect;
        final URI link;
        Segment(String label, RectF rect, URI link) { this.label = label; this.rect = new RectF(rect); this.link = link; }
    }
    private static final class Layout {
        final List<Item> items = new ArrayList<>();
        final List<Item> links = new ArrayList<>();
        final List<Segment> segments = new ArrayList<>();
        final Map<String, Float> anchors = new HashMap<>();
        float height;
        int background = Color.WHITE;
        String text = "";
    }

    private float dp(double value) { return (float) value * getResources().getDisplayMetrics().density; }

    private final class Layouter {
        final Layout result = new Layout();
        final Map<Css.Style, Paint> paints = new IdentityHashMap<>();
        final List<Integer> counters = new ArrayList<>();
        float left = dp(16), right, x = left, y = dp(18), lineHeight;
        boolean pendingSpace;
        boolean limited;
        int visitedNodes;
        int textCharacters;
        final long started = System.nanoTime();

        Layouter(float width) { right = Math.max(left + dp(24), width - dp(16)); }

        Layout build(Html.Document document) {
            sheet.beginLayout();
            Css.Style initial = sheet.style(document.root, null);
            // Visit the entire tree: the default sheet hides head/script/style and works for fragments.
            for (Html.Node child : document.root.children) visit(child, initial, null);
            flush(false, 0);
            if (limited || sheet.isLayoutLimited()) addLimitNotice();
            result.height = Math.min(MAX_HEIGHT, y + dp(24));
            LinkedHashMap<URI, Item> links = new LinkedHashMap<>();
            StringBuilder text = new StringBuilder();
            Item previous = null;
            for (Item item : result.items) {
                if (item.link != null) links.putIfAbsent(item.link, item);
                String label = item.text != null ? item.text : item.bitmap != null ? item.alt : null;
                if (label == null) continue;
                if (item.text != null) {
                    if (previous != null) {
                        if (Math.abs(item.rect.top - previous.rect.top) > dp(1)) text.append('\n');
                        else if (item.rect.left - previous.rect.right > dp(.5)) text.append(' ');
                    }
                    text.append(item.text); previous = item;
                }
                if (result.segments.size() >= 10_000 && !item.notice) continue;
                Segment last = result.segments.isEmpty() ? null : result.segments.get(result.segments.size() - 1);
                if (last != null && java.util.Objects.equals(last.link, item.link) && Math.abs(last.rect.top - item.rect.top) < dp(1) && item.text != null) {
                    last.label += (item.rect.left - last.rect.right > dp(.5) ? " " : "") + label;
                    last.rect.union(item.rect);
                } else result.segments.add(new Segment(label, item.rect, item.link));
            }
            result.links.addAll(links.values());
            result.text = text.toString();
            return result;
        }

        boolean full() {
            if (limited) return true;
            // Cold font initialization and a descheduled UI thread can consume the elapsed
            // budget before a short page has drawn its first paragraph. Permit a small,
            // deterministic slice of work first; node/text/item/CSS limits always apply.
            boolean minimumSliceComplete = visitedNodes >= MIN_TIMED_NODES
                    || result.items.size() >= MIN_TIMED_ITEMS
                    || textCharacters >= MIN_TIMED_CHARACTERS;
            if (result.items.size() >= MAX_ITEMS || y >= MAX_HEIGHT
                    || textCharacters >= MAX_TEXT_CHARACTERS
                    || (minimumSliceComplete && System.nanoTime() - started >= MAX_LAYOUT_NANOS)) limited = true;
            return limited;
        }

        void addLimitNotice() {
            // A fixed-size notice is added outside the work budget so truncation remains visible
            // and readable by accessibility services even after the content budget is exhausted.
            Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
            p.setTextSize(14 * getResources().getDisplayMetrics().scaledDensity);
            p.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
            p.setColor(0xff713f12);
            left = dp(16);
            right = Math.max(left + dp(24), layoutWidth - dp(16));
            x = left + dp(8);
            y = Math.max(dp(18), Math.min(y, MAX_HEIGHT - dp(160))) + dp(16);
            float top = y - dp(8);
            Item background = new Item(new RectF());
            background.color = 0xfffef3c7;
            result.items.add(background);
            float height = (p.descent() - p.ascent()) * 1.3f;
            for (String word : "Page display limit reached. Some content or styling was omitted.".split(" ")) {
                float width = p.measureText(word);
                if (x > left + dp(8) && x + width > right - dp(8)) { y += height; x = left + dp(8); }
                Item item = new Item(new RectF(x, y, x + width, y + p.descent() - p.ascent()));
                item.text = word; item.paint = p; item.notice = true;
                result.items.add(item);
                x += width + p.measureText(" ");
            }
            y += height + dp(8);
            background.rect.set(left, top, right, y);
        }

        void visit(Html.Node node, Css.Style inherited, URI link) {
            if (full()) return;
            if (visitedNodes >= MAX_VISITED_NODES) { limited = true; return; }
            visitedNodes++;
            if (node.text != null) { addText(node.text, inherited, link); return; }
            Css.Style style = sheet.style(node, inherited);
            if ("none".equals(style.display)) return;
            String tag = node.tag == null ? "" : node.tag;
            URI activeLink = link;
            if (tag.equals("a")) {
                String href = node.attributes.get("href");
                if (href != null) activeLink = resolve(href);
            }
            boolean block = "block".equals(style.display);
            float oldLeft = left, oldRight = right;
            if (block) { flush(false, 0); y += dp(style.marginTop); }
            String anchor = node.attributes.get("id");
            if (anchor == null) anchor = node.attributes.get("name");
            if (anchor != null) result.anchors.put(anchor, y);
            if (tag.equals("br")) { flush(true, dp(style.fontSize * 1.4)); return; }
            if (tag.equals("hr")) {
                flush(false, 0); y += dp(12);
                Item rule = new Item(new RectF(left, y, right, y + dp(1))); rule.color = 0xffd1d5db;
                result.items.add(rule); y += dp(14); return;
            }
            if (tag.equals("img")) { addImage(node, style, activeLink); return; }
            float startY = y;
            Item background = null;
            if (tag.equals("body")) result.background = parseColor(style.backgroundColor, Color.WHITE);
            else if (block && style.backgroundColor != null) {
                background = new Item(new RectF()); background.color = parseColor(style.backgroundColor, Color.TRANSPARENT);
                result.items.add(background);
            }
            if (block) {
                float padding = Math.max(0, Math.min(dp(style.padding), (right - left) / 4));
                left += padding; right -= padding;
                y += dp(style.padding); x = left;
            }
            if (tag.equals("ul") || tag.equals("ol")) {
                counters.add(tag.equals("ol") ? 1 : -1);
                left += Math.min(dp(22), Math.max(0, (right - left) / 4)); x = left;
            }
            if (tag.equals("li")) {
                int count = counters.isEmpty() ? -1 : counters.get(counters.size() - 1);
                String marker = count < 0 ? "•" : count + ".";
                if (count >= 0) counters.set(counters.size() - 1, count + 1);
                Paint p = paint(style);
                Item item = new Item(new RectF(left - dp(20), y, left - dp(2), y + p.descent() - p.ascent()));
                item.text = marker; item.paint = p;
                result.items.add(item);
            }
            for (Html.Node child : node.children) visit(child, style, activeLink);
            if (tag.equals("ul") || tag.equals("ol")) counters.remove(counters.size() - 1);
            if (block) {
                flush(false, 0); y += dp(style.padding);
                if (background != null) background.rect.set(oldLeft, startY, oldRight, Math.max(startY, y));
                left = oldLeft; right = oldRight; x = left;
                y += dp(style.marginBottom);
            }
        }

        Paint paint(Css.Style style) {
            Paint existing = paints.get(style);
            if (existing != null) return existing;
            Paint p = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.SUBPIXEL_TEXT_FLAG);
            p.setTextSize((float) Math.min(96, Math.max(8, style.fontSize)) * getResources().getDisplayMetrics().scaledDensity);
            p.setTypeface(Typeface.create(style.monospace ? "monospace" : "sans-serif", style.bold ? (style.italic ? Typeface.BOLD_ITALIC : Typeface.BOLD) : (style.italic ? Typeface.ITALIC : Typeface.NORMAL)));
            p.setUnderlineText(style.underline);
            p.setColor(parseColor(style.color, Color.BLACK));
            paints.put(style, p); return p;
        }

        void addText(String value, Css.Style style, URI link) {
            if (style.preformatted) {
                String text = value.replace("\r\n", "\n").replace('\r', '\n');
                for (int offset = 0; offset < text.length() && !full();) {
                    int codePoint = text.codePointAt(offset); offset += Character.charCount(codePoint);
                    textCharacters += Character.charCount(codePoint);
                    if (codePoint == '\n') flush(true, paint(style).getTextSize() * 1.4f);
                    else addWord(codePoint == '\t' ? "    " : new String(Character.toChars(codePoint)), style, link, true);
                }
                return;
            }
            int wordStart = -1;
            for (int offset = 0; offset < value.length() && !full();) {
                int cp = value.codePointAt(offset), count = Character.charCount(cp);
                textCharacters += count;
                // Nonbreaking space is rendered as part of a word.
                boolean whitespace = cp != 0xa0 && (Character.isWhitespace(cp) || cp == 0x85);
                if (whitespace) {
                    if (wordStart >= 0) { addWord(value.substring(wordStart, offset), style, link, false); wordStart = -1; }
                    pendingSpace = true;
                } else if (wordStart < 0) wordStart = offset;
                offset += count;
            }
            if (wordStart >= 0 && !full()) addWord(value.substring(wordStart), style, link, false);
        }

        void addWord(String word, Css.Style style, URI link, boolean allowBreak) {
            if (full()) return;
            // Bound a single font-shaping call as well as the traversal. A megabyte-long
            // unbroken word must not spend the entire UI budget inside Paint.measureText.
            if (word.length() > 2048 && !allowBreak) {
                for (int offset = 0; offset < word.length() && !full();) {
                    int cp = word.codePointAt(offset); offset += Character.charCount(cp);
                    addWord(new String(Character.toChars(cp)), style, link, true);
                }
                return;
            }
            Paint p = paint(style);
            float width = p.measureText(word);
            float space = pendingSpace && x > left ? p.measureText(" ") : 0;
            if (x > left && x + space + width > right) flush(false, 0);
            else x += space;
            pendingSpace = false;
            if (width > right - left && !allowBreak && word.codePointCount(0, word.length()) > 1) {
                for (int offset = 0; offset < word.length() && !full();) {
                    int cp = word.codePointAt(offset); offset += Character.charCount(cp);
                    addWord(new String(Character.toChars(cp)), style, link, true);
                }
                return;
            }
            Item item = new Item(new RectF(x, y, x + width, y + p.descent() - p.ascent()));
            item.text = word; item.paint = p; item.link = link;
            result.items.add(item); x += width;
            lineHeight = Math.max(lineHeight, (float) Math.ceil((p.descent() - p.ascent()) * 1.22));
        }

        void flush(boolean force, float minimum) {
            if (lineHeight > 0 || force) y += Math.max(lineHeight, minimum);
            x = left; lineHeight = 0; pendingSpace = false;
        }

        void addImage(Html.Node node, Css.Style style, URI link) {
            URI uri = resolve(node.attributes.get("src"));
            Bitmap bitmap = uri == null ? null : images.get(uri.toString());
            String alt = node.attributes.getOrDefault("alt", "Image");
            if (bitmap == null || bitmap.getWidth() <= 0 || bitmap.getHeight() <= 0) { addText("[" + alt + "]", style, link); return; }
            float width = dp(bitmap.getWidth()), height = dp(bitmap.getHeight());
            try {
                float specified = Float.parseFloat(node.attributes.get("width"));
                if (Float.isFinite(specified) && specified > 0) { width = dp(Math.min(4096, specified)); height = bitmap.getHeight() * width / bitmap.getWidth(); }
            } catch (Exception ignored) { }
            try {
                float specified = Float.parseFloat(node.attributes.get("height"));
                if (Float.isFinite(specified) && specified > 0) height = dp(Math.min(4096, specified));
            } catch (Exception ignored) { }
            if (width > right - left) { height *= (right - left) / width; width = right - left; }
            height = Math.min(dp(4096), height);
            flush(false, 0);
            Item item = new Item(new RectF(left, y, left + width, y + height));
            item.bitmap = bitmap; item.link = link; item.alt = alt;
            result.items.add(item); y += height + dp(8);
        }

        URI resolve(String raw) {
            if (raw == null) return null;
            try { return baseUri.resolve(raw.trim()); } catch (IllegalArgumentException ignored) { return null; }
        }
    }

    /** Supported CSS color syntax; Android's hex parser uses a different alpha byte order. */
    static int parseColor(String raw, int fallback) {
        if (raw == null) return fallback;
        String value = raw.trim().toLowerCase(Locale.ROOT);
        if (value.equals("transparent")) return Color.TRANSPARENT;
        String named = NAMED_COLORS.get(value);
        if (named != null) value = named;
        try {
            if (value.startsWith("#")) {
                String hex = value.substring(1);
                if (hex.length() == 3 || hex.length() == 4) {
                    StringBuilder expanded = new StringBuilder();
                    for (char c : hex.toCharArray()) expanded.append(c).append(c);
                    hex = expanded.toString();
                }
                if (hex.length() == 6) return (int) (0xff000000L | Long.parseLong(hex, 16));
                if (hex.length() == 8) {
                    long n = Long.parseLong(hex, 16);
                    return (int) ((n >>> 8) | ((n & 255) << 24));
                }
                return fallback;
            }
            boolean alpha = value.startsWith("rgba(");
            if ((alpha || value.startsWith("rgb(")) && value.endsWith(")")) {
                String[] parts = value.substring(alpha ? 5 : 4, value.length() - 1).split(",");
                if (parts.length != (alpha ? 4 : 3)) return fallback;
                int[] channels = {0, 0, 0, 255};
                for (int i = 0; i < parts.length; i++) {
                    String part = parts[i].trim(); boolean percent = part.endsWith("%");
                    double number = Double.parseDouble(percent ? part.substring(0, part.length() - 1) : part);
                    if (!Double.isFinite(number)) return fallback;
                    double divisor = percent ? 100 : i == 3 ? 1 : 255;
                    channels[i] = (int) Math.round(Math.max(0, Math.min(1, number / divisor)) * 255);
                }
                return Color.argb(channels[3], channels[0], channels[1], channels[2]);
            }
        } catch (NumberFormatException ignored) { }
        return fallback;
    }

    private static final Map<String, String> NAMED_COLORS = new HashMap<>();
    static {
        String[] pairs = {"black","#000000","white","#ffffff","red","#ff0000","green","#008000","blue","#0000ff","gray","#808080","grey","#808080","silver","#c0c0c0","navy","#000080","teal","#008080","purple","#800080","orange","#ffa500","yellow","#ffff00","rebeccapurple","#663399","maroon","#800000","fuchsia","#ff00ff","lime","#00ff00","olive","#808000","aqua","#00ffff","darkgray","#a9a9a9","darkgrey","#a9a9a9","lightgray","#d3d3d3","lightgrey","#d3d3d3"};
        for (int i = 0; i < pairs.length; i += 2) NAMED_COLORS.put(pairs[i], pairs[i + 1]);
    }
}
