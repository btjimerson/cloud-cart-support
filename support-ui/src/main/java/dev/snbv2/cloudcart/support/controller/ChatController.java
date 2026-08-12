package dev.snbv2.cloudcart.support.controller;

import dev.snbv2.cloudcart.support.model.ConversationContext;
import dev.snbv2.cloudcart.support.service.A2AClient;
import dev.snbv2.cloudcart.support.service.ContextManager;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

/**
 * REST controller that handles chat interactions with the support system.
 *
 * <p>Provides endpoints for sending chat messages and retrieving conversation history.
 * Messages are forwarded to the concierge agent over A2A via agentregistry; this service
 * holds no agent logic, no model configuration, and no tool bindings. Guardrails, rate
 * limiting, and tool authorization are enforced at the gateway rather than here.
 */
@RestController
public class ChatController {

    private final ContextManager contextManager;
    private final A2AClient a2aClient;
    private final String conciergeAgent;

    /**
     * Constructs a new {@code ChatController} with the required dependencies.
     *
     * @param contextManager  the manager responsible for creating and retrieving conversation contexts
     * @param a2aClient       the client used to invoke agents over A2A
     * @param conciergeAgent  the deployment name of the concierge agent that fields incoming messages
     */
    public ChatController(ContextManager contextManager, A2AClient a2aClient,
                          @Value("${agentregistry.concierge-agent}") String conciergeAgent) {
        this.contextManager = contextManager;
        this.a2aClient = a2aClient;
        this.conciergeAgent = conciergeAgent;
    }

    /**
     * Handles a chat message submitted via HTTP POST to {@code /chat}.
     *
     * <p>The request body must contain a {@code "message"} field and may optionally include
     * a {@code "conversation_id"} to continue an existing conversation and a {@code "customer_id"}
     * to associate the conversation with a customer.
     *
     * @param request a map containing {@code "message"}, and optionally {@code "conversation_id"}
     *                and {@code "customer_id"}
     * @return a {@link ResponseEntity} containing the agent's response, conversation ID, and agent
     *         name; or a 404 response if the specified conversation was not found
     */
    @PostMapping("/chat")
    public ResponseEntity<Map<String, Object>> chat(@RequestBody Map<String, String> request) {
        String message = request.get("message");
        String conversationId = request.get("conversation_id");
        String customerId = request.getOrDefault("customer_id", "");

        if (message == null || message.isBlank()) {
            return ResponseEntity.badRequest().body(Map.of("error", "Message is required"));
        }

        ConversationContext ctx;
        if (conversationId != null && !conversationId.isBlank()) {
            ctx = contextManager.get(conversationId);
            if (ctx == null) {
                return ResponseEntity.status(HttpStatus.NOT_FOUND)
                        .body(Map.of("error", "Conversation not found"));
            }
        } else {
            ctx = contextManager.create(customerId);
        }

        contextManager.addTurn(ctx.getConversationId(), "user", message, "", null);

        A2AClient.A2AReply reply = a2aClient.invoke(conciergeAgent, message, ctx.getConversationId());

        contextManager.addTurn(ctx.getConversationId(), "assistant",
                reply.content(), reply.agent(), null);

        return ResponseEntity.ok(Map.of(
                "response", reply.content(),
                "conversation_id", ctx.getConversationId(),
                "agent", reply.agent(),
                "tool_calls", List.of()
        ));
    }

    /**
     * Retrieves the details of an existing conversation by its ID.
     *
     * @param conversationId the unique identifier of the conversation to retrieve
     * @return a {@link ResponseEntity} containing the conversation details, or a 404 response
     *         if no conversation with the given ID exists
     */
    @GetMapping("/conversations/{conversationId}")
    public ResponseEntity<Map<String, Object>> getConversation(@PathVariable String conversationId) {
        ConversationContext ctx = contextManager.get(conversationId);
        if (ctx == null) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND)
                    .body(Map.of("error", "Conversation not found"));
        }

        return ResponseEntity.ok(Map.of(
                "conversation_id", ctx.getConversationId(),
                "customer_id", ctx.getCustomerId(),
                "current_agent", ctx.getCurrentAgent(),
                "turns", ctx.getTurns(),
                "handoffs", ctx.getHandoffs(),
                "created_at", ctx.getCreatedAt()
        ));
    }
}
