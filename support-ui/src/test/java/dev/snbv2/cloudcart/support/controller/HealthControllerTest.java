package dev.snbv2.cloudcart.support.controller;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * MockMvc integration tests for the {@link HealthController}.
 * Verifies that the GET /health endpoint reports which registry and runtime
 * this instance is configured against.
 */
@SpringBootTest
@AutoConfigureMockMvc
@TestPropertySource(properties = {
        "agentregistry.base-url=http://localhost:12121",
        "agentregistry.default-runtime=kagent",
        "agentregistry.concierge-agent=support-concierge"
})
class HealthControllerTest {

    @Autowired
    private MockMvc mockMvc;

    /**
     * Tests that GET /health returns HTTP 200 with a healthy status.
     */
    @Test
    void health_returnsHealthyStatus() throws Exception {
        mockMvc.perform(get("/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("healthy"));
    }

    /**
     * Tests that the health payload names the catalog as the source of agents and
     * reports the runtime and concierge agent it is configured against. This service
     * holds no agent list of its own, so these fields are the whole answer.
     */
    @Test
    void health_reportsRegistryAsAgentSource() throws Exception {
        mockMvc.perform(get("/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.agent_source").value("agentregistry"))
                .andExpect(jsonPath("$.runtime").value("kagent"))
                .andExpect(jsonPath("$.concierge_agent").value("support-concierge"));
    }
}
