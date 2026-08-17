package dev.snbv2.cloudcart.support.controller;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.snbv2.cloudcart.support.model.AgentHandoff;
import dev.snbv2.cloudcart.support.model.ConversationContext;
import dev.snbv2.cloudcart.support.service.A2AClient;
import dev.snbv2.cloudcart.support.service.ContextManager;
import lombok.extern.apachecommons.CommonsLog;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * WebSocket handler that manages real-time chat communication at the {@code /ws} endpoint.
 *
 * <p>Implements the same conversation flow as {@link ChatController} but over a WebSocket
 * connection, enabling bidirectional, low-latency messaging. Messages are forwarded to the
 * concierge agent over A2A via agentregistry.
 */
@Component
@CommonsLog
public class ChatWebSocketHandler extends TextWebSocketHandler {

    private final ContextManager contextManager;
    private final A2AClient a2aClient;
    private final ObjectMapper objectMapper;
    private final String conciergeAgent;

    /**
     * Constructs a new {@code ChatWebSocketHandler} with the required dependencies.
     *
     * @param contextManager  the manager responsible for creating and retrieving conversation contexts
     * @param a2aClient       the client used to invoke agents over A2A
     * @param objectMapper    the Jackson object mapper for serializing and deserializing JSON messages
     * @param conciergeAgent  the deployment name of the concierge agent that fields incoming messages
     */
    public ChatWebSocketHandler(ContextManager contextManager, A2AClient a2aClient,
                                ObjectMapper objectMapper,
                                @Value("${agentregistry.concierge-agent}") String conciergeAgent) {
        this.contextManager = contextManager;
        this.a2aClient = a2aClient;
        this.objectMapper = objectMapper;
        this.conciergeAgent = conciergeAgent;
    }

    /**
     * Invoked after a new WebSocket connection has been established.
     *
     * @param session the newly established WebSocket session
     */
    @Override
    public void afterConnectionEstablished(WebSocketSession session) {
        log.info(String.format("WebSocket connected: %s", session.getId()));
    }

    /**
     * Handles an incoming text message received over the WebSocket connection.
     *
     * <p>Parses the JSON payload to extract {@code "message"}, {@code "conversation_id"},
     * and {@code "customer_id"} fields, forwards the message to the concierge agent, and
     * sends the reply back through the session.
     *
     * @param session     the WebSocket session from which the message was received
     * @param textMessage the incoming text message containing a JSON payload
     * @throws Exception if an error occurs during message processing or response serialization
     */
    @Override
    protected void handleTextMessage(WebSocketSession session, TextMessage textMessage) throws Exception {
        Map<String, Object> data = objectMapper.readValue(textMessage.getPayload(), Map.class);

        String message = (String) data.get("message");
        String conversationId = (String) data.get("conversation_id");
        String customerId = (String) data.getOrDefault("customer_id", "");

        if (message == null || message.isBlank()) {
            sendJson(session, Map.of("error", "Message is required"));
            return;
        }

        ConversationContext ctx;
        if (conversationId != null && !conversationId.isBlank()) {
            ctx = contextManager.get(conversationId);
            if (ctx == null) {
                sendJson(session, Map.of("error", "Conversation not found"));
                return;
            }
        } else {
            ctx = contextManager.create(customerId);
        }

        contextManager.addTurn(ctx.getConversationId(), "user", message, "", null);

        A2AClient.A2AReply reply = a2aClient.invoke(conciergeAgent, message, ctx.getConversationId());

        contextManager.addTurn(ctx.getConversationId(), "assistant",
                reply.content(), reply.agent(), null);

        Map<String, Object> response = new LinkedHashMap<>();
        response.put("content", reply.content());
        response.put("conversation_id", ctx.getConversationId());
        response.put("agent", reply.agent());
        response.put("tool_calls", List.of());

        for (String specialist : reply.delegates()) {
            AgentHandoff handoff = contextManager.handoff(
                    ctx.getConversationId(), reply.agent(), specialist, "delegated over A2A");
            if (handoff != null) {
                response.put("handoff", Map.of(
                        "from_agent", handoff.getFromAgent(),
                        "to_agent", handoff.getToAgent(),
                        "reason", handoff.getReason()));
            }
        }

        sendJson(session, response);
    }

    /**
     * Invoked after a WebSocket connection has been closed.
     *
     * @param session the WebSocket session that was closed
     * @param status  the status code and reason for the closure
     */
    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
        log.info(String.format("WebSocket disconnected: %s (%s)", session.getId(), status));
    }

    /**
     * Handles a transport-level error that occurred on the WebSocket connection.
     *
     * @param session   the WebSocket session on which the error occurred
     * @param exception the exception representing the transport error
     */
    @Override
    public void handleTransportError(WebSocketSession session, Throwable exception) {
        log.error(String.format("WebSocket error for session %s: %s", session.getId(), exception.getMessage()));
    }

    /**
     * Serializes the given data map to JSON and sends it as a text message through
     * the specified WebSocket session.
     *
     * @param session the WebSocket session to send the message through
     * @param data    the data map to serialize to JSON and send
     * @throws Exception if serialization or message sending fails
     */
    private void sendJson(WebSocketSession session, Map<String, Object> data) throws Exception {
        session.sendMessage(new TextMessage(objectMapper.writeValueAsString(data)));
    }
}
