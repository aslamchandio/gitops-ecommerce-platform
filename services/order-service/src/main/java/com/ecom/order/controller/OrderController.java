package com.ecom.order.controller;

import com.ecom.order.model.Order;
import com.ecom.order.model.OrderItem;
import com.ecom.order.repo.OrderRepository;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/orders")
public class OrderController {

    private final OrderRepository repo;

    public OrderController(OrderRepository repo) {
        this.repo = repo;
    }

    @PostMapping
    public ResponseEntity<Order> create(@RequestBody Map<String, Object> body) {
        Order order = new Order();
        order.setSessionId((String) body.get("sessionId"));
        order.setTotal(((Number) body.get("total")).doubleValue());

        @SuppressWarnings("unchecked")
        Map<String, String> shipping = (Map<String, String>) body.get("shipping");
        order.setShippingName(shipping.get("name"));
        order.setShippingAddress(shipping.get("address"));
        order.setShippingCity(shipping.get("city"));
        order.setShippingPostal(shipping.get("postal"));
        order.setShippingCountry(shipping.get("country"));

        @SuppressWarnings("unchecked")
        List<Map<String, Object>> items = (List<Map<String, Object>>) body.get("items");
        for (Map<String, Object> i : items) {
            OrderItem item = new OrderItem();
            item.setProductId(((Number) i.get("productId")).intValue());
            item.setTitle((String) i.get("title"));
            item.setImage((String) i.get("image"));
            item.setPrice(((Number) i.get("price")).doubleValue());
            item.setQuantity(((Number) i.get("quantity")).intValue());
            item.setOrder(order);
            order.getItems().add(item);
        }

        return ResponseEntity.status(201).body(repo.save(order));
    }

    @GetMapping("/{id}")
    public ResponseEntity<Order> get(@PathVariable Long id) {
        return repo.findById(id)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    @GetMapping
    public List<Order> bySession(@RequestParam String sessionId) {
        return repo.findBySessionIdOrderByCreatedAtDesc(sessionId);
    }
}
