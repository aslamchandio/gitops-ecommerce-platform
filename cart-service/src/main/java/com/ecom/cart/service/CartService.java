package com.ecom.cart.service;

import com.ecom.cart.model.Cart;
import com.ecom.cart.model.CartItem;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;

import java.time.Duration;
import java.util.Map;
import java.util.concurrent.TimeUnit;

@Service
public class CartService {

    private static final Duration TTL = Duration.ofDays(7);
    private final RedisTemplate<String, Cart> redis;
    private final WebClient catalog;

    public CartService(RedisTemplate<String, Cart> redis, WebClient catalogClient) {
        this.redis = redis;
        this.catalog = catalogClient;
    }

    private String key(String sessionId) {
        return "cart:" + sessionId;
    }

    public Cart get(String sessionId) {
        Cart cart = redis.opsForValue().get(key(sessionId));
        if (cart == null) {
            cart = new Cart(sessionId, new java.util.ArrayList<>(), 0);
        }
        return cart;
    }

    public Cart addItem(String sessionId, int productId, int quantity) {
        Cart cart = get(sessionId);

        // Pull product detail from catalog so the cart line is self-contained.
        @SuppressWarnings("unchecked")
        Map<String, Object> product = catalog.get()
                .uri("/products/{id}", productId)
                .retrieve()
                .bodyToMono(Map.class)
                .block();

        if (product == null) {
            throw new IllegalArgumentException("product not found: " + productId);
        }

        CartItem existing = cart.getItems().stream()
                .filter(i -> i.getProductId() == productId)
                .findFirst().orElse(null);

        if (existing != null) {
            existing.setQuantity(existing.getQuantity() + quantity);
        } else {
            CartItem item = new CartItem();
            item.setProductId(productId);
            item.setTitle((String) product.get("title"));
            item.setImage((String) product.get("image"));
            item.setPrice(((Number) product.get("price")).doubleValue());
            item.setQuantity(quantity);
            cart.getItems().add(item);
        }
        recalc(cart);
        save(cart);
        return cart;
    }

    public Cart removeItem(String sessionId, int productId) {
        Cart cart = get(sessionId);
        cart.getItems().removeIf(i -> i.getProductId() == productId);
        recalc(cart);
        save(cart);
        return cart;
    }

    public void clear(String sessionId) {
        redis.delete(key(sessionId));
    }

    private void recalc(Cart cart) {
        double total = cart.getItems().stream()
                .mapToDouble(i -> i.getPrice() * i.getQuantity())
                .sum();
        cart.setTotal(Math.round(total * 100.0) / 100.0);
    }

    private void save(Cart cart) {
        redis.opsForValue().set(key(cart.getSessionId()), cart, TTL.getSeconds(), TimeUnit.SECONDS);
    }
}
