package dev.snbv2.cloudcart.support;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Spring Boot application entry point for the support chat frontend.
 *
 * <p>This service owns the chat UI and the conversation context store. It holds no agents,
 * no model configuration, and no API keys: there is no required-environment check at startup
 * because there is no credential for this process to be missing. Agents are resolved from
 * agentregistry at call time and authorized at the gateway.
 */
@SpringBootApplication
public class SupportUiApplication {

    /**
     * Application main method that launches the Spring Boot application.
     *
     * @param args command-line arguments passed to the application
     */
    public static void main(String[] args) {
        SpringApplication.run(SupportUiApplication.class, args);
    }
}
