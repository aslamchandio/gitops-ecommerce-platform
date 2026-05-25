package com.ecom.ui.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.bind.annotation.ModelAttribute;

/**
 * Adds {@code appVersion} (the build SHA, or "dev" locally) to every view's
 * model. The Thymeleaf layout fragment appends it as {@code ?v=<sha>} to
 * static asset links so a new release invalidates browser caches.
 */
@ControllerAdvice
public class ViewModelAdvice {

    private final String appVersion;

    public ViewModelAdvice(@Value("${app.version}") String appVersion) {
        this.appVersion = appVersion;
    }

    @ModelAttribute("appVersion")
    public String appVersion() {
        return appVersion;
    }
}
