package dev.snbv2.cloudcart.orders.config;

import dev.snbv2.cloudcart.orders.model.*;
import dev.snbv2.cloudcart.orders.repository.OrderRepository;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.apachecommons.CommonsLog;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.CommandLineRunner;
import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Component;

import java.io.InputStream;
import java.time.Duration;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.stream.Stream;

/**
 * Seeds the orders database with initial data on application startup.
 *
 * <p>Reads order definitions from {@code seed-data/orders.json} on the classpath,
 * including order items, and persists them via {@link OrderRepository}.</p>
 *
 * <p><strong>Dates are relative, not absolute.</strong> The file's timestamps are a fixed
 * reference span; on startup every date is shifted forward by the same amount so that the
 * most recent one lands {@code seed.newest-order-days-ago} days before now. Relative spacing
 * between orders is preserved exactly, so the data keeps its shape while ageing with the
 * calendar.</p>
 *
 * <p>Without this, the whole dataset silently expires: return eligibility is measured in days
 * since delivery, so absolute 2024 dates mean every order eventually falls outside the return
 * window and the returns flow can only ever answer "no".</p>
 */
@Component
@CommonsLog
public class DataSeeder implements CommandLineRunner {

    private final OrderRepository orderRepository;
    private final ObjectMapper objectMapper;
    private final long newestOrderDaysAgo;

    /**
     * Constructs the seeder.
     *
     * @param orderRepository     repository the seeded orders are written to
     * @param objectMapper        mapper used to read the seed file
     * @param newestOrderDaysAgo  how far in the past the most recent seeded date should land;
     *                            1 by default, so nothing is dated in the future
     */
    public DataSeeder(OrderRepository orderRepository, ObjectMapper objectMapper,
                      @Value("${seed.newest-order-days-ago:1}") long newestOrderDaysAgo) {
        this.orderRepository = orderRepository;
        this.objectMapper = objectMapper;
        this.newestOrderDaysAgo = newestOrderDaysAgo;
    }

    /**
     * Computes the offset that moves the seed file's most recent timestamp to the configured
     * number of days before now.
     *
     * @param orders the parsed seed entries
     * @return the duration to add to every timestamp in the file
     */
    private Duration shiftFor(List<JsonNode> orders) {
        Instant newest = orders.stream()
                .flatMap(n -> Stream.of(n.get("created_at").asText(), n.get("updated_at").asText()))
                .map(Instant::parse)
                .max(Instant::compareTo)
                .orElse(Instant.now());
        return Duration.between(newest, Instant.now().minus(newestOrderDaysAgo, ChronoUnit.DAYS));
    }

    @Override
    public void run(String... args) throws Exception {
        try (InputStream is = new ClassPathResource("seed-data/orders.json").getInputStream()) {
            List<JsonNode> orders = objectMapper.readValue(is, new TypeReference<>() {});
            Duration shift = shiftFor(orders);
            for (JsonNode node : orders) {
                Order o = new Order();
                o.setId(node.get("id").asText());
                o.setCustomerId(node.get("customer_id").asText());
                o.setStatus(OrderStatus.fromValue(node.get("status").asText()));
                o.setTotal(node.get("total").asDouble());
                o.setCreatedAt(Instant.parse(node.get("created_at").asText()).plus(shift));
                o.setUpdatedAt(Instant.parse(node.get("updated_at").asText()).plus(shift));
                o.setTrackingNumber(node.has("tracking_number") && !node.get("tracking_number").isNull()
                        ? node.get("tracking_number").asText() : null);
                o.setShippingAddress(node.has("shipping_address") ? node.get("shipping_address").asText() : "");

                for (JsonNode itemNode : node.get("items")) {
                    OrderItem item = new OrderItem();
                    item.setProductId(itemNode.get("product_id").asInt());
                    item.setProductName(itemNode.get("product_name").asText());
                    item.setQuantity(itemNode.get("quantity").asInt());
                    item.setPrice(itemNode.get("price").asDouble());
                    o.addItem(item);
                }

                orderRepository.save(o);
            }
            log.info(String.format("Seeded %d orders, dates shifted by %d days so the newest lands %d day(s) ago",
                    orders.size(), shift.toDays(), newestOrderDaysAgo));
        }
    }
}
