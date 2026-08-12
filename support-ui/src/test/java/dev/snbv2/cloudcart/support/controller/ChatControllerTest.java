package dev.snbv2.cloudcart.support.controller;

import dev.snbv2.cloudcart.support.model.ConversationContext;
import dev.snbv2.cloudcart.support.service.ContextManager;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * MockMvc integration tests for the {@link ChatController}.
 *
 * <p>Covers request validation, conversation lifecycle, and graceful degradation when the
 * registry is unreachable. These tests deliberately point at a port with nothing listening:
 * agent behaviour belongs to the deployed agents, not to this service, so what is worth
 * asserting here is that the frontend stays well-behaved when it cannot reach them.
 */
@SpringBootTest
@AutoConfigureMockMvc
@TestPropertySource(properties = {
        "agentregistry.base-url=http://localhost:1",
        "agentregistry.default-runtime=kagent",
        "agentregistry.concierge-agent=support-concierge",
        "agentregistry.timeout-seconds=2"
})
class ChatControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ContextManager contextManager;

    /**
     * Tests that a request without a message is rejected with HTTP 400.
     */
    @Test
    void chat_missingMessage_returnsBadRequest() throws Exception {
        mockMvc.perform(post("/chat")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"customer_id\": \"CUST-001\"}"))
                .andExpect(status().isBadRequest());
    }

    /**
     * Tests that when no conversation_id is provided, the chat endpoint automatically
     * creates a new conversation and returns its ID in the response.
     */
    @Test
    void chat_missingConversationId_createsNewConversation() throws Exception {
        mockMvc.perform(post("/chat")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"message\": \"hello\", \"customer_id\": \"CUST-001\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.conversation_id").isNotEmpty());
    }

    /**
     * Tests that an unknown conversation ID returns HTTP 404 rather than silently
     * starting a new conversation.
     */
    @Test
    void chat_unknownConversationId_returnsNotFound() throws Exception {
        mockMvc.perform(post("/chat")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"message\": \"hello\", \"conversation_id\": \"does-not-exist\"}"))
                .andExpect(status().isNotFound());
    }

    /**
     * Tests that an unreachable registry degrades to a plain answer attributed to the
     * system, rather than surfacing a stack trace or a 5xx to the chat client.
     */
    @Test
    void chat_registryUnreachable_returnsGracefulFallback() throws Exception {
        mockMvc.perform(post("/chat")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"message\": \"where is my order\", \"customer_id\": \"CUST-001\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.agent").value("system"))
                .andExpect(jsonPath("$.response").isNotEmpty());
    }

    /**
     * Tests that the user's turn is recorded in the conversation context even when the
     * agent call fails, so that history is not lost on a transient outage.
     */
    @Test
    void chat_recordsUserTurnEvenWhenAgentUnreachable() throws Exception {
        ConversationContext ctx = contextManager.create("CUST-001");

        mockMvc.perform(post("/chat")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"message\": \"hello\", \"conversation_id\": \"" + ctx.getConversationId() + "\"}"))
                .andExpect(status().isOk());

        mockMvc.perform(get("/conversations/" + ctx.getConversationId()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.turns[0].role").value("user"))
                .andExpect(jsonPath("$.turns[0].content").value("hello"));
    }

    /**
     * Tests that retrieving an unknown conversation returns HTTP 404.
     */
    @Test
    void getConversation_unknownId_returnsNotFound() throws Exception {
        mockMvc.perform(get("/conversations/does-not-exist"))
                .andExpect(status().isNotFound());
    }
}
