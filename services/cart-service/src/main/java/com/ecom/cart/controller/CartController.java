package com.ecom.cart.controller;

import com.ecom.cart.model.Cart;
import com.ecom.cart.service.CartService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

@RestController
@RequestMapping("/carts")
public class CartController {

    private final CartService service;

    public CartController(CartService service) {
        this.service = service;
    }

    @GetMapping("/{sessionId}")
    public Cart get(@PathVariable String sessionId) {
        return service.get(sessionId);
    }

    @PostMapping("/{sessionId}/items")
    public Cart addItem(@PathVariable String sessionId, @RequestBody Map<String, Integer> body) {
        return service.addItem(sessionId, body.get("productId"), body.getOrDefault("quantity", 1));
    }

    @DeleteMapping("/{sessionId}/items/{productId}")
    public Cart removeItem(@PathVariable String sessionId, @PathVariable int productId) {
        return service.removeItem(sessionId, productId);
    }

    @DeleteMapping("/{sessionId}")
    public ResponseEntity<Void> clear(@PathVariable String sessionId) {
        service.clear(sessionId);
        return ResponseEntity.noContent().build();
    }
}
