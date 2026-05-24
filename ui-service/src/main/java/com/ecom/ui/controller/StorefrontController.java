package com.ecom.ui.controller;

import jakarta.servlet.http.Cookie;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Mono;

import java.util.*;

@Controller
public class StorefrontController {

    private final WebClient catalog;
    private final WebClient cart;
    private final WebClient checkout;

    public StorefrontController(WebClient catalogClient, WebClient cartClient, WebClient checkoutClient) {
        this.catalog = catalogClient;
        this.cart = cartClient;
        this.checkout = checkoutClient;
    }

    @GetMapping("/")
    public String home(@RequestParam(required = false) String category,
                       Model model,
                       HttpServletRequest req,
                       HttpServletResponse res) {
        String sessionId = sessionId(req, res);

        List<Map<String, Object>> products = catalog.get()
                .uri(uriBuilder -> {
                    uriBuilder.path("/products");
                    if (category != null && !category.isBlank()) uriBuilder.queryParam("category", category);
                    return uriBuilder.build();
                })
                .retrieve()
                .bodyToMono(new ParameterizedTypeReference<List<Map<String, Object>>>() {})
                .onErrorReturn(Collections.emptyList())
                .block();

        List<String> categories = catalog.get().uri("/categories")
                .retrieve()
                .bodyToMono(new ParameterizedTypeReference<List<String>>() {})
                .onErrorReturn(Collections.emptyList())
                .block();

        Map<String, Object> cartObj = fetchCart(sessionId);

        model.addAttribute("products", products);
        model.addAttribute("categories", categories);
        model.addAttribute("activeCategory", category);
        model.addAttribute("cartCount", cartCount(cartObj));
        return "index";
    }

    @GetMapping("/product/{id}")
    public String detail(@PathVariable int id, Model model, HttpServletRequest req, HttpServletResponse res) {
        String sessionId = sessionId(req, res);
        Map<String, Object> product = catalog.get().uri("/products/{id}", id)
                .retrieve()
                .bodyToMono(new ParameterizedTypeReference<Map<String, Object>>() {})
                .onErrorResume(e -> Mono.empty())
                .block();
        if (product == null) return "redirect:/";
        model.addAttribute("product", product);
        model.addAttribute("cartCount", cartCount(fetchCart(sessionId)));
        return "product";
    }

    @PostMapping("/cart/add")
    public String addToCart(@RequestParam int productId,
                            @RequestParam(defaultValue = "1") int quantity,
                            HttpServletRequest req,
                            HttpServletResponse res) {
        String sessionId = sessionId(req, res);
        cart.post().uri("/carts/{sid}/items", sessionId)
                .bodyValue(Map.of("productId", productId, "quantity", quantity))
                .retrieve().toBodilessEntity()
                .onErrorResume(e -> Mono.empty())
                .block();
        return "redirect:/cart";
    }

    @GetMapping("/cart")
    public String viewCart(Model model, HttpServletRequest req, HttpServletResponse res) {
        String sessionId = sessionId(req, res);
        Map<String, Object> cartObj = fetchCart(sessionId);
        model.addAttribute("cart", cartObj);
        model.addAttribute("cartCount", cartCount(cartObj));
        return "cart";
    }

    @PostMapping("/cart/remove")
    public String removeFromCart(@RequestParam int productId,
                                 HttpServletRequest req,
                                 HttpServletResponse res) {
        String sessionId = sessionId(req, res);
        cart.delete().uri("/carts/{sid}/items/{pid}", sessionId, productId)
                .retrieve().toBodilessEntity()
                .onErrorResume(e -> Mono.empty())
                .block();
        return "redirect:/cart";
    }

    @GetMapping("/checkout")
    public String checkoutForm(Model model, HttpServletRequest req, HttpServletResponse res) {
        String sessionId = sessionId(req, res);
        Map<String, Object> cartObj = fetchCart(sessionId);
        model.addAttribute("cart", cartObj);
        model.addAttribute("cartCount", cartCount(cartObj));
        return "checkout";
    }

    @PostMapping("/checkout")
    public String placeOrder(@RequestParam String name,
                             @RequestParam String address,
                             @RequestParam String city,
                             @RequestParam String postal,
                             @RequestParam String country,
                             HttpServletRequest req,
                             HttpServletResponse res,
                             Model model) {
        String sessionId = sessionId(req, res);
        Map<String, Object> payload = Map.of(
                "sessionId", sessionId,
                "shipping", Map.of(
                        "name", name, "address", address, "city", city,
                        "postal", postal, "country", country));

        Map<String, Object> result = checkout.post().uri("/checkout")
                .bodyValue(payload)
                .retrieve()
                .bodyToMono(new ParameterizedTypeReference<Map<String, Object>>() {})
                .onErrorResume(e -> Mono.just(Map.of("error", e.getMessage())))
                .block();

        model.addAttribute("result", result);
        model.addAttribute("cartCount", 0);
        return "confirmation";
    }

    // --- helpers ---

    private String sessionId(HttpServletRequest req, HttpServletResponse res) {
        if (req.getCookies() != null) {
            for (Cookie c : req.getCookies()) {
                if ("ecom_sid".equals(c.getName())) return c.getValue();
            }
        }
        String sid = UUID.randomUUID().toString();
        Cookie c = new Cookie("ecom_sid", sid);
        c.setPath("/");
        c.setHttpOnly(true);
        c.setMaxAge(60 * 60 * 24 * 30);
        res.addCookie(c);
        return sid;
    }

    private Map<String, Object> fetchCart(String sessionId) {
        return cart.get().uri("/carts/{sid}", sessionId)
                .retrieve()
                .bodyToMono(new ParameterizedTypeReference<Map<String, Object>>() {})
                .onErrorReturn(Map.of("items", Collections.emptyList(), "total", 0.0))
                .block();
    }

    @SuppressWarnings("unchecked")
    private int cartCount(Map<String, Object> cartObj) {
        if (cartObj == null) return 0;
        List<Map<String, Object>> items = (List<Map<String, Object>>) cartObj.getOrDefault("items", List.of());
        return items.stream()
                .mapToInt(i -> ((Number) i.getOrDefault("quantity", 0)).intValue())
                .sum();
    }
}
