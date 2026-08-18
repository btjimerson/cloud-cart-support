package dev.snbv2.cloudcart.support.controller;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * REST controller that exposes a health check endpoint for the application.
 *
 * <p>Reports which registry and runtime this instance is pointed at. It deliberately does
 * not enumerate agents: this service holds no agent registry, and the catalog is the only
 * authoritative answer to what agents exist.
 */
@RestController
public class HealthController {

    private final String registryBaseUrl;
    private final String defaultRuntime;
    private final String conciergeAgent;

    /**
     * Constructs a new {@code HealthController}.
     *
     * @param registryBaseUrl the base URL of the agentregistry API this instance calls
     * @param defaultRuntime  the runtime connection name agents are invoked on
     * @param conciergeAgent  the deployment name of the concierge agent
     */
    public HealthController(@Value("${agentregistry.base-url}") String registryBaseUrl,
                            @Value("${agentregistry.default-runtime}") String defaultRuntime,
                            @Value("${agentregistry.concierge-agent}") String conciergeAgent) {
        this.registryBaseUrl = registryBaseUrl;
        this.defaultRuntime = defaultRuntime;
        this.conciergeAgent = conciergeAgent;
    }

    /**
     * Handles GET requests to {@code /health} and returns the application health status.
     *
     * @return a map containing the health status and the registry, runtime, and concierge
     *         agent this instance is configured against
     */
    @GetMapping("/health")
    public Map<String, Object> health() {
        // "healthy but not wired" is a real state, and the one an app sits in before anyone
        // points it at a catalog. Reporting it plainly beats looking healthy and answering
        // nothing.
        boolean wired = !registryBaseUrl.isBlank() && !defaultRuntime.isBlank()
                && !conciergeAgent.isBlank();
        return Map.of(
                "status", "healthy",
                "agent_source", wired ? "agentregistry" : "unconfigured",
                "registry", registryBaseUrl,
                "runtime", defaultRuntime,
                "concierge_agent", conciergeAgent
        );
    }
}
