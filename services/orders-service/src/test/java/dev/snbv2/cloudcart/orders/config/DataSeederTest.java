package dev.snbv2.cloudcart.orders.config;

import dev.snbv2.cloudcart.orders.model.Order;
import dev.snbv2.cloudcart.orders.model.OrderStatus;
import dev.snbv2.cloudcart.orders.repository.OrderRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;

import java.time.Duration;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Tests that seeded order dates stay relative to now.
 *
 * <p>These guard the demo rather than the code. Return eligibility is measured in days since
 * delivery, so if the seed dates were ever pinned to absolute values again the whole dataset
 * would age out and the returns flow could only answer "no" -- which is exactly what happened
 * with the original 2024 timestamps. The specific ages below are what the demo script depends
 * on, so a change that moves them should fail here and be made deliberately.
 */
@SpringBootTest
class DataSeederTest {

    @Autowired
    private OrderRepository orderRepository;

    private long daysSinceUpdate(String orderId) {
        Order order = orderRepository.findById(orderId).orElseThrow();
        return Duration.between(order.getUpdatedAt(), Instant.now()).toDays();
    }

    @Test
    void seedsAllOrders() {
        assertEquals(20, orderRepository.count());
    }

    @Test
    void noOrderIsDatedInTheFuture() {
        Instant now = Instant.now();
        orderRepository.findAll().forEach(o -> {
            assertTrue(o.getCreatedAt().isBefore(now), o.getId() + " created in the future");
            assertTrue(o.getUpdatedAt().isBefore(now), o.getId() + " updated in the future");
        });
    }

    @Test
    void createdNeverAfterUpdated() {
        orderRepository.findAll().forEach(o ->
                assertFalse(o.getCreatedAt().isAfter(o.getUpdatedAt()),
                        o.getId() + " was created after it was updated"));
    }

    /** CUST-001's delivered order is the standard-return demo: inside the 30-day window. */
    @Test
    void standardReturnOrderIsInsideTheReturnWindow() {
        long days = daysSinceUpdate("ORD-2024-0001");
        assertTrue(days < 30, "ORD-2024-0001 is " + days + " days old; the standard return demo needs < 30");
    }

    /**
     * CUST-010 is Platinum and their delivered order sits between the standard 30-day window
     * and a 90-day tier exception, so publishing returns-eligibility v2 visibly changes the
     * answer. If this drifts inside 30 days, that beat stops demonstrating anything.
     */
    @Test
    void platinumOrderSitsBetweenTheStandardAndTierWindows() {
        long days = daysSinceUpdate("ORD-2024-0010");
        assertTrue(days > 30 && days < 90,
                "ORD-2024-0010 is " + days + " days old; the tier-exception demo needs 31-89");
    }

    /** CUST-008's order has shipped but not been delivered: the "cannot return it yet" path. */
    @Test
    void deniedPathOrderHasShippedButNotBeenDelivered() {
        Order order = orderRepository.findById("ORD-2024-0008").orElseThrow();
        assertEquals(OrderStatus.SHIPPED, order.getStatus());
    }
}
