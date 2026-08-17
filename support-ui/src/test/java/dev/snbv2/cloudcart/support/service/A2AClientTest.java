package dev.snbv2.cloudcart.support.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Method;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for {@link A2AClient}'s handling of A2A responses.
 *
 * <p>The shapes exercised here are taken from real responses returned by agentregistry's A2A
 * proxy. The duplicate-reply case is the one that matters: a Task carries the answer in
 * {@code artifacts} and the whole exchange in {@code history}, so a naive scan of the response
 * returns the answer and the user's own message together.
 */
class A2AClientTest {

    private final ObjectMapper objectMapper = new ObjectMapper();

    private A2AClient client() {
        return new A2AClient(objectMapper, "http://registry:12121", "kagent", "", 30, "", "", "");
    }

    /** {@code parseReply} is private; these tests exercise it directly rather than over HTTP. */
    private A2AClient.A2AReply parse(String body) throws Exception {
        Method m = A2AClient.class.getDeclaredMethod("parseReply", String.class, String.class);
        m.setAccessible(true);
        return (A2AClient.A2AReply) m.invoke(client(), "support-concierge", body);
    }

    @Test
    void taskResult_returnsArtifactTextOnly_notHistory() throws Exception {
        String body = """
            {"jsonrpc":"2.0","id":"1","result":{
              "kind":"task","id":"t1",
              "artifacts":[{"artifactId":"a1","parts":[{"kind":"text","text":"Our return window is 30 days."}]}],
              "history":[
                {"kind":"message","role":"user","parts":[{"kind":"text","text":"What is your return policy?"}]},
                {"kind":"message","role":"agent","parts":[{"kind":"text","text":"Our return window is 30 days."}]}
              ]}}
            """;
        A2AClient.A2AReply reply = parse(body);

        assertFalse(reply.failed());
        assertEquals("Our return window is 30 days.", reply.content());
        assertFalse(reply.content().contains("What is your return policy?"),
                "the user's own message must not be echoed back as the reply");
    }

    @Test
    void messageResult_returnsTopLevelParts() throws Exception {
        String body = """
            {"jsonrpc":"2.0","id":"1","result":{
              "kind":"message","role":"agent",
              "parts":[{"kind":"text","text":"Hello, how can I help?"}]}}
            """;
        assertEquals("Hello, how can I help?", parse(body).content());
    }

    @Test
    void taskWithoutArtifacts_fallsBackToLastNonUserTurn() throws Exception {
        String body = """
            {"jsonrpc":"2.0","id":"1","result":{
              "kind":"task","id":"t1","artifacts":[],
              "history":[
                {"kind":"message","role":"user","parts":[{"kind":"text","text":"Where is my order?"}]},
                {"kind":"message","role":"agent","parts":[{"kind":"text","text":"It ships tomorrow."}]}
              ]}}
            """;
        assertEquals("It ships tomorrow.", parse(body).content());
    }

    /**
     * An agent that needs more information returns a task in {@code input-required} whose only
     * content is a structured elicitation -- a data part with no text anywhere. That is a
     * question for the customer, and the chat showed it as "returned an empty response".
     */
    @Test
    void inputRequiredElicitation_isRenderedAsAQuestion() throws Exception {
        String body = """
            {"jsonrpc":"2.0","id":"1","result":{
              "kind":"task",
              "status":{"state":"input-required","message":{"role":"agent","parts":[
                {"kind":"data","data":{"args":{"originalFunctionCall":{"name":"ask_user","args":{"questions":[
                  {"question":"What will you primarily use the headset for?",
                   "choices":["Gaming","Music","Work/Calls"]}
                ]}}}}}
              ]}}}}
            """;
        A2AClient.A2AReply reply = parse(body);

        assertFalse(reply.failed(), "an agent asking a question is not a failure");
        assertTrue(reply.content().contains("What will you primarily use the headset for?"));
        assertTrue(reply.content().contains("Gaming"));
    }

    @Test
    void statusMessageText_isUsedWhenThereAreNoArtifacts() throws Exception {
        String body = """
            {"jsonrpc":"2.0","id":"1","result":{
              "kind":"task",
              "status":{"state":"input-required","message":{"role":"agent","parts":[
                {"kind":"text","text":"Which order do you mean?"}]}}}}
            """;
        assertEquals("Which order do you mean?", parse(body).content());
    }

    @Test
    void jsonRpcError_isReportedAsFailure() throws Exception {
        String body = """
            {"jsonrpc":"2.0","id":"1","error":{"code":-32000,"message":"agent unavailable"}}
            """;
        A2AClient.A2AReply reply = parse(body);
        assertTrue(reply.failed());
        assertEquals("system", reply.agent());
    }

    @Test
    void emptyResponse_isReportedAsFailure() throws Exception {
        A2AClient.A2AReply reply = parse("{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":{\"kind\":\"task\",\"artifacts\":[]}}");
        assertTrue(reply.failed());
    }

    @Test
    void multipleArtifactParts_areJoined() throws Exception {
        String body = """
            {"jsonrpc":"2.0","id":"1","result":{
              "kind":"task",
              "artifacts":[{"parts":[{"kind":"text","text":"First."},{"kind":"text","text":"Second."}]}]}}
            """;
        assertEquals("First.\n\nSecond.", parse(body).content());
    }
}
