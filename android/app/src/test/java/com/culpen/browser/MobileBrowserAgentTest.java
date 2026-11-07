package com.culpen.browser;

import org.junit.Test;
import java.util.concurrent.CompletableFuture;
import static org.junit.Assert.*;

public final class MobileBrowserAgentTest {
    @Test public void conversationalInputNeverReadsThePageOrContactsThePC() throws Exception {
        MobileBrowserAgent.Host noBrowser = new MobileBrowserAgent.Host() {
            @Override public CompletableFuture<MobileBrowserAgent.Snapshot> observe() { throw new AssertionError("Observed page for a greeting"); }
            @Override public CompletableFuture<Void> act(MobileBrowserAgent.Command command, MobileBrowserAgent.Snapshot page, boolean approved) { throw new AssertionError("Acted for a greeting"); }
            @Override public CompletableFuture<Boolean> approve(String message) { throw new AssertionError("Requested approval for a greeting"); }
            @Override public void activity(String message) { throw new AssertionError("Started browser activity for a greeting"); }
            @Override public void cancel() { throw new AssertionError("Cancelled browser for a greeting"); }
        };
        // A null connection proves these replies do not depend on an available PC/model.
        MobileBrowserAgent agent = new MobileBrowserAgent(null, noBrowser);
        for (String task : new String[]{"hola", "¡HOLA!", "hola amiga", "buenas", " Hola, ¿cómo estás? ", "hello!", "hi agent", "good morning", "Hi there", "How are you?", "What's up?", "¿Cómo estás?", "thanks", "¿Qué puedes hacer?"}) {
            String answer = agent.run(task);
            assertFalse(task, answer.isEmpty());
        }
        assertTrue(agent.run("hola").contains("¡Hola!"));
    }

    @Test public void greetingPrefixDoesNotHideARealBrowsingTask() {
        for (String task : new String[]{"Hola, busca Reddit", "Hello, open https://example.com", "Search for hola", "Summarize this page", "Click the Hello link"}) {
            assertNull(task, MobileBrowserAgent.directReply(task));
        }
    }

    @Test public void unclearInputAndHomeQuestionsCannotEnterTheActionLoop() {
        for (String task : new String[]{"how are you", "what is two plus two", "When does the museum open?", "Reddit"}) {
            assertFalse(task, new MobileBrowserAgent.TaskPolicy(task).allowsBrowsingFor("browser:home"));
        }
        for (String task : new String[]{"Summarize this page", "Follow the Opening Hours link", "Hello, open Reddit", "Hola, busca Reddit", "Abre Reddit", "Resume esta página", "Search for hola", "https://example.com"}) {
            assertTrue(task, new MobileBrowserAgent.TaskPolicy(task).allowsBrowsingFor("browser:home"));
        }
    }

    @Test public void questionsCanFollowLinksOnAnExistingPageButSocialInputCannot() {
        for (String task : new String[]{"What time does the museum open?", "When does the museum open?", "¿Cuándo abre el museo?"}) {
            assertTrue(task, new MobileBrowserAgent.TaskPolicy(task).allowsBrowsingFor("https://example.com/museum"));
        }
        for (String task : new String[]{"hola", "How are you?", "What's up?", "¿Cómo estás?", "Reddit"}) {
            assertFalse(task, new MobileBrowserAgent.TaskPolicy(task).allowsBrowsingFor("https://example.com/museum"));
        }
    }

    @Test public void homePageAndEmptyPagesDoNotAuthorizeAnUnrequestedSearch() {
        MobileBrowserAgent.Snapshot home = new MobileBrowserAgent.Snapshot("home", "browser:home", "Home", "Reddit Feedback", java.util.Collections.emptyList(), false, false, false, false, 0, 0);
        MobileBrowserAgent.Snapshot page = new MobileBrowserAgent.Snapshot("page", "https://example.com", "Example", "", java.util.Collections.emptyList(), false, false, false, false, 0, 0);
        assertFalse(new MobileBrowserAgent.TaskPolicy("Summarize this page").allowsSearch(home));
        assertFalse(new MobileBrowserAgent.TaskPolicy("What time does the museum open?").allowsSearch(home));
        assertFalse(new MobileBrowserAgent.TaskPolicy("Follow the Opening Hours link").allowsSearch(page));
        assertTrue(new MobileBrowserAgent.TaskPolicy("Open Reddit").allowsSearch(home));
        assertTrue(new MobileBrowserAgent.TaskPolicy("Find the museum hours online").allowsSearch(page));
    }

}
