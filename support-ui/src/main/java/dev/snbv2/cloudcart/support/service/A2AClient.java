package dev.snbv2.cloudcart.support.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.apachecommons.CommonsLog;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Client that invokes agents over the A2A protocol via agentregistry.
 *
 * <p>Requests are sent to {@code /v0/a2a/sessions/{runtime}/agents/{deploymentName}},
 * which streams the body through to the upstream agent endpoint using the credentials
 * held by the stored runtime connection. Because the registry proxies rather than
 * re-encodes, the body is a standard A2A JSON-RPC {@code message/send} envelope and the
 * response is whatever the upstream agent returns.
 *
 * <p>Routing an agent through the registry rather than addressing its runtime directly
 * is what keeps this class runtime-agnostic: the same call reaches an agent on kagent or
 * on Bedrock AgentCore, and moving an agent between runtimes is a deployment change here,
 * not a code change.
 */
@Service
@CommonsLog
public class A2AClient {

    private final ObjectMapper objectMapper;
    private final HttpClient httpClient;
    private final String registryBaseUrl;
    private final String defaultRuntime;
    private final String authToken;
    private final Duration requestTimeout;

    private final String oidcIssuer;
    private final String oidcClientId;
    private final String oidcClientSecret;

    /** Cached client-credentials token, refreshed shortly before it expires. */
    private volatile String cachedToken;
    private volatile Instant cachedTokenExpiry = Instant.EPOCH;

    /**
     * Constructs a new {@code A2AClient}.
     *
     * @param objectMapper    the Jackson object mapper used to build and parse A2A envelopes
     * @param registryBaseUrl the base URL of the agentregistry API, e.g. {@code http://agentregistry:12121}
     * @param defaultRuntime  the runtime connection name to invoke agents on when none is given
     * @param authToken       static bearer token for the registry API; blank to mint one instead
     * @param timeoutSeconds  per-request timeout in seconds
     * @param oidcIssuer      OIDC issuer used to mint tokens when no static token is supplied
     * @param oidcClientId    client id of this service's account
     * @param oidcClientSecret client secret of this service's account
     */
    public A2AClient(ObjectMapper objectMapper,
                     @Value("${agentregistry.base-url}") String registryBaseUrl,
                     @Value("${agentregistry.default-runtime}") String defaultRuntime,
                     @Value("${agentregistry.auth-token:}") String authToken,
                     @Value("${agentregistry.timeout-seconds:60}") long timeoutSeconds,
                     @Value("${agentregistry.oidc.issuer:}") String oidcIssuer,
                     @Value("${agentregistry.oidc.client-id:}") String oidcClientId,
                     @Value("${agentregistry.oidc.client-secret:}") String oidcClientSecret) {
        this.objectMapper = objectMapper;
        this.registryBaseUrl = registryBaseUrl.replaceAll("/+$", "");
        this.defaultRuntime = defaultRuntime;
        this.authToken = authToken;
        this.oidcIssuer = oidcIssuer.replaceAll("/+$", "");
        this.oidcClientId = oidcClientId;
        this.oidcClientSecret = oidcClientSecret;
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .build();
        this.requestTimeout = Duration.ofSeconds(timeoutSeconds);
    }

    /**
     * Returns a bearer token for the registry, or an empty string when auth is not configured.
     *
     * <p>Prefers a statically supplied token, otherwise mints one with the client-credentials
     * grant and caches it. Registry tokens are short-lived, so a token pasted into config
     * would leave the chat silently failing a few hours after deploy; minting keeps the
     * frontend working across a long-running demo without anyone re-pasting anything.
     *
     * @return a bearer token, or an empty string if no credentials are configured
     */
    private String bearerToken() {
        if (!authToken.isBlank()) {
            return authToken;
        }
        if (oidcIssuer.isBlank() || oidcClientId.isBlank() || oidcClientSecret.isBlank()) {
            return "";
        }
        String current = cachedToken;
        if (current != null && Instant.now().isBefore(cachedTokenExpiry)) {
            return current;
        }
        synchronized (this) {
            if (cachedToken != null && Instant.now().isBefore(cachedTokenExpiry)) {
                return cachedToken;
            }
            try {
                String form = "grant_type=client_credentials"
                        + "&client_id=" + URLEncoder.encode(oidcClientId, StandardCharsets.UTF_8)
                        + "&client_secret=" + URLEncoder.encode(oidcClientSecret, StandardCharsets.UTF_8);

                HttpRequest request = HttpRequest.newBuilder()
                        .uri(URI.create(oidcIssuer + "/protocol/openid-connect/token"))
                        .timeout(Duration.ofSeconds(15))
                        .header("Content-Type", "application/x-www-form-urlencoded")
                        .POST(HttpRequest.BodyPublishers.ofString(form))
                        .build();

                HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
                if (response.statusCode() >= 400) {
                    log.error("Token request failed: HTTP %d".formatted(response.statusCode()));
                    return "";
                }

                JsonNode body = objectMapper.readTree(response.body());
                cachedToken = body.path("access_token").asText("");
                // Refresh a minute early so an in-flight request never rides an expiring token.
                long ttl = Math.max(60, body.path("expires_in").asLong(300) - 60);
                cachedTokenExpiry = Instant.now().plusSeconds(ttl);
                return cachedToken;

            } catch (Exception e) {
                log.error("Could not mint a registry token: %s".formatted(e.getMessage()));
                return "";
            }
        }
    }

    /**
     * Invokes an agent on the default runtime.
     *
     * @param deploymentName the deployment name of the agent to invoke
     * @param message        the user message to send
     * @param contextId      the conversation identifier, carried through as the A2A context ID
     * @return the agent's reply
     */
    public A2AReply invoke(String deploymentName, String message, String contextId) {
        return invoke(defaultRuntime, deploymentName, message, contextId);
    }

    /**
     * Invokes an agent on a specific runtime.
     *
     * <p>Note that AgentCore's A2A support is a text-chat compatibility bridge and treats
     * each invocation as a fresh conversation, so {@code contextId} is only meaningful for
     * runtimes that maintain session state.
     *
     * @param runtime        the runtime connection name, e.g. {@code kagent} or {@code aws-bedrock}
     * @param deploymentName the deployment name of the agent to invoke
     * @param message        the user message to send
     * @param contextId      the conversation identifier, carried through as the A2A context ID
     * @return the agent's reply
     */
    public A2AReply invoke(String runtime, String deploymentName, String message, String contextId) {
        String url = "%s/v0/a2a/sessions/%s/agents/%s".formatted(registryBaseUrl, runtime, deploymentName);

        try {
            String body = objectMapper.writeValueAsString(buildEnvelope(message, contextId));

            HttpRequest.Builder builder = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .timeout(requestTimeout)
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(body));
            String token = bearerToken();
            if (!token.isBlank()) {
                builder.header("Authorization", "Bearer " + token);
            }

            HttpResponse<String> response = httpClient.send(builder.build(),
                    HttpResponse.BodyHandlers.ofString());

            if (response.statusCode() >= 400) {
                log.error("A2A call to %s/%s failed: HTTP %d %s"
                        .formatted(runtime, deploymentName, response.statusCode(), response.body()));
                return A2AReply.error("The %s agent is unavailable right now.".formatted(deploymentName));
            }

            return parseReply(deploymentName, response.body());

        } catch (Exception e) {
            log.error("A2A call to %s/%s failed: %s".formatted(runtime, deploymentName, e.getMessage()));
            return A2AReply.error("The %s agent is unavailable right now.".formatted(deploymentName));
        }
    }

    /**
     * Builds an A2A JSON-RPC {@code message/send} envelope for the given user message.
     *
     * @param message   the user message text
     * @param contextId the conversation identifier to carry as the A2A context ID
     * @return the envelope as a nested map ready for JSON serialization
     */
    private Map<String, Object> buildEnvelope(String message, String contextId) {
        Map<String, Object> part = Map.of("kind", "text", "text", message);

        Map<String, Object> msg = new LinkedHashMap<>();
        msg.put("role", "user");
        msg.put("parts", List.of(part));
        msg.put("messageId", UUID.randomUUID().toString());
        if (contextId != null && !contextId.isBlank()) {
            msg.put("contextId", contextId);
        }

        Map<String, Object> envelope = new LinkedHashMap<>();
        envelope.put("jsonrpc", "2.0");
        envelope.put("id", UUID.randomUUID().toString());
        envelope.put("method", "message/send");
        envelope.put("params", Map.of("message", msg));
        return envelope;
    }

    /**
     * Extracts the reply text from an A2A response.
     *
     * <p>A2A permits the result to be either a Message or a Task, and a Task carries its
     * text under either {@code status.message} or the last entry in {@code artifacts}.
     * Rather than binding to one shape, this walks the tree collecting every text part it
     * finds, which tolerates all of them.
     *
     * @param deploymentName the agent that produced the response, used for attribution
     * @param rawBody        the raw JSON response body
     * @return the parsed reply
     */
    private A2AReply parseReply(String deploymentName, String rawBody) {
        try {
            JsonNode root = objectMapper.readTree(rawBody);

            JsonNode error = root.path("error");
            if (!error.isMissingNode() && !error.isNull()) {
                log.error("A2A agent %s returned an error: %s".formatted(deploymentName, error));
                return A2AReply.error("The %s agent could not complete that request.".formatted(deploymentName));
            }

            List<String> texts = new ArrayList<>();
            collectTextParts(root.path("result").isMissingNode() ? root : root.path("result"), texts);

            if (texts.isEmpty()) {
                log.warn("A2A response from %s contained no text parts: %s".formatted(deploymentName, rawBody));
                return A2AReply.error("The %s agent returned an empty response.".formatted(deploymentName));
            }

            return new A2AReply(String.join("\n\n", texts), deploymentName, false);

        } catch (Exception e) {
            log.error("Could not parse A2A response from %s: %s".formatted(deploymentName, e.getMessage()));
            return A2AReply.error("The %s agent returned a response we could not read.".formatted(deploymentName));
        }
    }

    /**
     * Recursively collects the {@code text} field of every text part in the given tree.
     *
     * @param node  the node to walk
     * @param sink  the list that collected text is appended to
     */
    private void collectTextParts(JsonNode node, List<String> sink) {
        if (node == null || node.isMissingNode()) {
            return;
        }
        if (node.isObject()) {
            JsonNode text = node.get("text");
            boolean isTextPart = text != null && text.isTextual()
                    && (!node.has("kind") || "text".equals(node.path("kind").asText()));
            if (isTextPart && !text.asText().isBlank()) {
                sink.add(text.asText());
                return;
            }
            node.fields().forEachRemaining(entry -> collectTextParts(entry.getValue(), sink));
        } else if (node.isArray()) {
            node.forEach(child -> collectTextParts(child, sink));
        }
    }

    /**
     * The outcome of an A2A invocation.
     *
     * @param content the reply text, or a user-facing message when {@code failed} is true
     * @param agent   the deployment name of the agent that answered
     * @param failed  whether the invocation failed
     */
    public record A2AReply(String content, String agent, boolean failed) {

        /**
         * Builds a failed reply attributed to the system rather than to an agent.
         *
         * @param content the user-facing message
         * @return a failed reply
         */
        static A2AReply error(String content) {
            return new A2AReply(content, "system", true);
        }
    }
}
