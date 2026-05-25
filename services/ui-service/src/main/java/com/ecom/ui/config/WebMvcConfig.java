package com.ecom.ui.config;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.http.CacheControl;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.servlet.config.annotation.ResourceHandlerRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

import java.io.IOException;
import java.time.Duration;

/**
 * Cache-control policy:
 *
 *   /css/**, /js/**          → immutable, 1 year. Safe because the layout
 *                              appends ?v={appVersion} to every asset URL,
 *                              so a new deploy gives a new URL and the
 *                              old cache entry is naturally bypassed.
 *
 *   Everything else (HTML)   → no-cache, must-revalidate (set by Filter).
 *                              Without this, Spring Boot ships HTML with no
 *                              Cache-Control header and browsers cache it for
 *                              hours via heuristics — meaning a user who
 *                              visited before a deploy keeps seeing the old
 *                              HTML (which references the old asset URLs)
 *                              until their cache expires. Forcing
 *                              revalidation makes deploys instantly visible.
 */
@Configuration
public class WebMvcConfig implements WebMvcConfigurer {

    @Override
    public void addResourceHandlers(ResourceHandlerRegistry registry) {
        CacheControl staticCC = CacheControl.maxAge(Duration.ofDays(365))
                                            .cachePublic()
                                            .immutable();
        registry.addResourceHandler("/css/**")
                .addResourceLocations("classpath:/static/css/")
                .setCacheControl(staticCC);
        registry.addResourceHandler("/js/**")
                .addResourceLocations("classpath:/static/js/")
                .setCacheControl(staticCC);
    }

    /**
     * Servlet filter (not MVC interceptor) so headers are set BEFORE the
     * view renders and the response gets committed. Interceptors run after
     * the controller but before view rendering, where {@code Content-Type}
     * isn't set yet, so we can't reliably content-type-sniff there.
     */
    @Bean
    public FilterRegistrationBean<OncePerRequestFilter> htmlNoCacheFilter() {
        OncePerRequestFilter filter = new OncePerRequestFilter() {
            @Override
            protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
                    throws ServletException, IOException {
                String path = req.getRequestURI();
                if (!path.startsWith("/css/")
                        && !path.startsWith("/js/")
                        && !path.startsWith("/actuator/")) {
                    res.setHeader("Cache-Control", "no-cache, no-store, must-revalidate");
                    res.setHeader("Pragma", "no-cache");
                    res.setHeader("Expires", "0");
                }
                chain.doFilter(req, res);
            }
        };
        FilterRegistrationBean<OncePerRequestFilter> reg = new FilterRegistrationBean<>(filter);
        reg.setOrder(Ordered.HIGHEST_PRECEDENCE);
        return reg;
    }
}
