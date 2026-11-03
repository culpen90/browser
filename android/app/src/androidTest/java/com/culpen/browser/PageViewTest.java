package com.culpen.browser;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.RectF;
import android.view.MotionEvent;
import android.view.View;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityNodeProvider;
import android.widget.ScrollView;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import com.culpen.browser.engine.Html;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.net.URI;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.Assert.*;

/** Exercises the independent renderer on Android's real font, canvas, input and accessibility APIs. */
@RunWith(AndroidJUnit4.class)
public class PageViewTest {
    @Test public void wrapsAtViewportAndHidesNonPageContent() {
        onMain(() -> {
            PageView page = page("<head><style>p { color: blue }</style><script>HIDDEN SCRIPT</script></head>"
                    + "<body><h1>Visible title</h1><p>" + repeat("Readable words, links and long addresses. ", 40) + "</p></body>", "");
            size(page, 600);
            int wideHeight = page.getMeasuredHeight();
            assertTrue(page.getTextContent().contains("Visible title"));
            assertFalse(page.getTextContent().contains("HIDDEN SCRIPT"));
            assertFalse(page.getTextContent().contains("color: blue"));
            size(page, 240);
            assertTrue("Narrow viewports must reflow into more lines", page.getMeasuredHeight() > wideHeight);
            assertTrue(page.getTextContent().contains("Readable"));
        });
    }

    @Test public void rendersBackgroundImagesAndAlternativeText() {
        onMain(() -> {
            PageView page = new PageView(context());
            Bitmap source = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888);
            source.eraseColor(Color.GREEN);
            Map<String, Bitmap> images = new HashMap<>();
            images.put("https://example.com/pixel.png", source);
            page.setPage(Html.parse("<body><img src='pixel.png' width='80' height='40' alt='Green sample'>"
                            + "<img src='missing.png' alt='Useful alternative'></body>"),
                    "body { background-color: #123456; padding: 0; }", URI.create("https://example.com/index.html"), images);
            size(page, 300);
            Bitmap output = Bitmap.createBitmap(page.getWidth(), page.getHeight(), Bitmap.Config.ARGB_8888);
            page.draw(new Canvas(output));
            assertEquals("Canvas must paint the CSS body background", 0xff123456, output.getPixel(0, 0));
            boolean foundGreen = false;
            for (int y = 0; y < output.getHeight() && !foundGreen; y += 4) {
                for (int x = 0; x < output.getWidth(); x += 4) if (output.getPixel(x, y) == Color.GREEN) { foundGreen = true; break; }
            }
            assertTrue("The custom display list must draw a decoded image", foundGreen);
            assertTrue(page.getTextContent().contains("[Useful alternative]"));
            output.recycle();
            source.recycle();
        });
    }

    @Test public void touchAndAccessibilityFollowResolvedLinks() {
        onMain(() -> {
            PageView page = page("<p><a href='second.html'>Visit next page</a></p>", "");
            AtomicReference<URI> visited = new AtomicReference<>();
            page.setOnNavigateListener(visited::set);
            size(page, 320);
            assertEquals(1, page.getLinkCount());
            assertEquals(URI.create("https://example.com/second.html"), page.getLinkUri(0));
            RectF bounds = page.getLinkBounds(0);
            MotionEvent down = MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, bounds.centerX(), bounds.centerY(), 0);
            MotionEvent up = MotionEvent.obtain(0, 10, MotionEvent.ACTION_UP, bounds.centerX(), bounds.centerY(), 0);
            page.onTouchEvent(down); page.onTouchEvent(up);
            down.recycle(); up.recycle();
            assertEquals(URI.create("https://example.com/second.html"), visited.get());
            visited.set(null);
            AccessibilityNodeProvider provider = page.getAccessibilityNodeProvider();
            AccessibilityNodeInfo host = provider.createAccessibilityNodeInfo(View.NO_ID);
            assertTrue("Custom canvas must expose readable accessibility children", host.getChildCount() > 0);
            boolean clicked = false;
            for (int id = 0; id < host.getChildCount(); id++) {
                AccessibilityNodeInfo node = provider.createAccessibilityNodeInfo(id);
                if (node != null && node.isClickable()) {
                    assertTrue(node.getText().toString().contains("Visit next page"));
                    assertTrue(provider.performAction(id, AccessibilityNodeInfo.ACTION_CLICK, null));
                    clicked = true;
                    break;
                }
            }
            assertTrue("Links must be actionable with TalkBack", clicked);
            assertEquals(URI.create("https://example.com/second.html"), visited.get());
        });
    }

    @Test public void fragmentsScrollAndPlusRemainsLiteral() {
        onMain(() -> {
            PageView page = page("<body><p>Start</p><p>" + repeat("Scrollable content. ", 100)
                    + "</p><h2 id='finish+here'>Finish</h2></body>", "");
            ScrollView scroll = new ScrollView(context());
            scroll.addView(page, new ScrollView.LayoutParams(-1, -2));
            int width = px(280), height = px(180);
            scroll.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY));
            scroll.layout(0, 0, width, height);
            page.scrollToAnchor("finish+here");
            assertTrue("A matching fragment must scroll its host", scroll.getScrollY() > 0);
            page.scrollToAnchor(null);
            assertEquals(0, scroll.getScrollY());
        });
    }

    @Test public void largeStyledTreesStopWithinTheUiBudgetAndExplainTruncation() {
        onMain(() -> {
            StringBuilder html = new StringBuilder("<body>");
            for (int i = 0; i < 25_000; i++) html.append("<div class='work'>Visible words</div>");
            html.append("</body>");
            StringBuilder css = new StringBuilder();
            for (int i = 0; i < 2_000; i++) css.append("body div.work { color: #123456; }");
            Html.Document document = Html.parse(html.toString());
            PageView page = new PageView(context());
            page.setPage(document, css.toString(), URI.create("https://example.com/large.html"), Collections.emptyMap());
            long start = System.nanoTime();
            size(page, 320);
            long elapsedMillis = (System.nanoTime() - start) / 1_000_000;
            assertTrue("Bounded rendering must return promptly, took " + elapsedMillis + " ms", elapsedMillis < 2_500);
            assertTrue(page.getTextContent().contains("Page display limit reached."));
            AccessibilityNodeProvider provider = page.getAccessibilityNodeProvider();
            AccessibilityNodeInfo host = provider.createAccessibilityNodeInfo(View.NO_ID);
            boolean noticeExposed = false;
            for (int id = 0; id < host.getChildCount(); id++) {
                AccessibilityNodeInfo node = provider.createAccessibilityNodeInfo(id);
                if (node != null && node.getText() != null && node.getText().toString().contains("display limit")) noticeExposed = true;
            }
            assertTrue("Truncation must be explained to accessibility users", noticeExposed);
        });
    }

    @Test public void cssAlphaUsesRgbaOrderAndRejectsInvalidValues() {
        onMain(() -> {
            assertEquals(0x44112233, PageView.parseColor("#1234", 0));
            assertEquals(0x80112233, PageView.parseColor("#11223380", 0));
            assertEquals(0x80ff0000, PageView.parseColor("rgba(100%, 0%, 0%, .5)", 0));
            assertEquals(7, PageView.parseColor("rgba(NaN, 0, 0, 1)", 7));
        });
    }

    private static String repeat(String text, int count) {
        StringBuilder result = new StringBuilder();
        for (int i = 0; i < count; i++) result.append(text);
        return result.toString();
    }
    private static android.content.Context context() { return InstrumentationRegistry.getInstrumentation().getTargetContext(); }
    private static int px(int dp) { return Math.round(dp * context().getResources().getDisplayMetrics().density); }
    private static void onMain(Runnable action) { InstrumentationRegistry.getInstrumentation().runOnMainSync(action); }
    private static PageView page(String html, String css) {
        PageView page = new PageView(context());
        page.setPage(Html.parse(html), css, URI.create("https://example.com/index.html"), Collections.emptyMap());
        return page;
    }
    private static void size(PageView page, int widthDp) {
        int width = px(widthDp);
        page.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        page.layout(0, 0, width, page.getMeasuredHeight());
    }
}
