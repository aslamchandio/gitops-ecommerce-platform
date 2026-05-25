import express from 'express';
import morgan from 'morgan';

const PORT = process.env.PORT || 8083;
const CART_URL = process.env.CART_SERVICE_URL || 'http://localhost:8082';
const ORDER_URL = process.env.ORDER_SERVICE_URL || 'http://localhost:8084';

const app = express();
app.use(express.json());
app.use(morgan('tiny'));

app.get('/health', (_req, res) => res.json({ status: 'up' }));

// POST /checkout { sessionId, shipping: { name, address, city, postal, country } }
app.post('/checkout', async (req, res) => {
  const { sessionId, shipping } = req.body || {};
  if (!sessionId || !shipping?.name || !shipping?.address) {
    return res.status(400).json({ error: 'sessionId and shipping.name/address required' });
  }

  try {
    // 1. Fetch the cart
    const cartRes = await fetch(`${CART_URL}/carts/${sessionId}`);
    if (!cartRes.ok) throw new Error(`cart fetch failed: ${cartRes.status}`);
    const cart = await cartRes.json();
    if (!cart.items?.length) {
      return res.status(400).json({ error: 'cart is empty' });
    }

    // 2. Create the order
    const orderRes = await fetch(`${ORDER_URL}/orders`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        sessionId,
        items: cart.items,
        total: cart.total,
        shipping
      })
    });
    if (!orderRes.ok) {
      const txt = await orderRes.text();
      throw new Error(`order create failed: ${orderRes.status} ${txt}`);
    }
    const order = await orderRes.json();

    // 3. Clear the cart on success
    await fetch(`${CART_URL}/carts/${sessionId}`, { method: 'DELETE' });

    res.status(201).json({ status: 'ok', orderId: order.id, total: cart.total });
  } catch (err) {
    console.error('checkout error:', err);
    res.status(502).json({ error: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`checkout-service listening on :${PORT}`);
});
