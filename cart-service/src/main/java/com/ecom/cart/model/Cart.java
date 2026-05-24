package com.ecom.cart.model;

import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.io.Serializable;
import java.util.ArrayList;
import java.util.List;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class Cart implements Serializable {
    private String sessionId;
    private List<CartItem> items = new ArrayList<>();
    private double total;
}
