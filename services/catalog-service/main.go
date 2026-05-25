package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Product struct {
	ID          int     `json:"id"`
	Title       string  `json:"title"`
	Price       float64 `json:"price"`
	Description string  `json:"description"`
	Category    string  `json:"category"`
	Image       string  `json:"image"`
	Discount    int     `json:"discount"`
	Rating      struct {
		Rate  float64 `json:"rate"`
		Count int     `json:"count"`
	} `json:"rating"`
}

var pool *pgxpool.Pool

func main() {
	ctx := context.Background()

	// Prefer DB_PASSWORD_FILE (Secret Manager CSI mount) over DB_PASSWORD env.
	// Falls back to env so docker-compose / local dev still works unchanged.
	password := env("DB_PASSWORD", "ecom_pw")
	if pwFile := os.Getenv("DB_PASSWORD_FILE"); pwFile != "" {
		b, err := os.ReadFile(pwFile)
		if err != nil {
			log.Fatalf("read DB_PASSWORD_FILE %q: %v", pwFile, err)
		}
		password = strings.TrimSpace(string(b))
	}

	dsn := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable",
		env("DB_USER", "ecom"),
		password,
		env("DB_HOST", "localhost"),
		env("DB_PORT", "5432"),
		env("DB_NAME", "catalog"),
	)

	var err error
	pool, err = pgxpool.New(ctx, dsn)
	if err != nil {
		log.Fatalf("db connect: %v", err)
	}
	defer pool.Close()

	if err := migrate(ctx); err != nil {
		log.Fatalf("migrate: %v", err)
	}

	// Start the FakeStore sync loop in the background. First sync runs immediately.
	go runSyncLoop(ctx)

	r := chi.NewRouter()
	r.Use(middleware.Logger, middleware.Recoverer)
	r.Get("/health", healthHandler)
	r.Get("/products", listProducts)
	r.Get("/products/{id}", getProduct)
	r.Get("/categories", listCategories)
	r.Post("/sync", manualSync) // trigger a sync on demand

	port := env("PORT", "8081")
	log.Printf("catalog-service listening on :%s", port)
	if err := http.ListenAndServe(":"+port, r); err != nil {
		log.Fatal(err)
	}
}

func migrate(ctx context.Context) error {
	_, err := pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS products (
			id           INT PRIMARY KEY,
			title        TEXT NOT NULL,
			price        NUMERIC(10,2) NOT NULL,
			description  TEXT,
			category     TEXT,
			image        TEXT,
			discount     INT DEFAULT 0,
			rating_rate  NUMERIC(3,2),
			rating_count INT,
			updated_at   TIMESTAMPTZ DEFAULT NOW()
		);
		CREATE INDEX IF NOT EXISTS idx_products_category ON products(category);
	`)
	return err
}

func runSyncLoop(ctx context.Context) {
	hours, _ := strconv.Atoi(env("SYNC_INTERVAL_HOURS", "6"))
	if hours < 1 {
		hours = 6
	}

	// initial sync (retry a few times if FakeStore is briefly unreachable)
	for i := 0; i < 5; i++ {
		if err := syncFromFakeStore(ctx); err != nil {
			log.Printf("initial sync attempt %d failed: %v", i+1, err)
			time.Sleep(time.Duration(5*(i+1)) * time.Second)
			continue
		}
		break
	}

	ticker := time.NewTicker(time.Duration(hours) * time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := syncFromFakeStore(ctx); err != nil {
				log.Printf("scheduled sync failed: %v", err)
			}
		}
	}
}

func syncFromFakeStore(ctx context.Context) error {
	url := env("FAKESTORE_URL", "https://fakestoreapi.com/products")
	log.Printf("syncing products from %s", url)

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("fetch: %w", err)
	}
	defer resp.Body.Close()

	var products []Product
	if err := json.NewDecoder(resp.Body).Decode(&products); err != nil {
		return fmt.Errorf("decode: %w", err)
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	for _, p := range products {
		discount := pseudoDiscount(p.ID) // deterministic 0-40% promo
		_, err := tx.Exec(ctx, `
			INSERT INTO products (id, title, price, description, category, image, discount, rating_rate, rating_count, updated_at)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,NOW())
			ON CONFLICT (id) DO UPDATE SET
				title=EXCLUDED.title, price=EXCLUDED.price, description=EXCLUDED.description,
				category=EXCLUDED.category, image=EXCLUDED.image, discount=EXCLUDED.discount,
				rating_rate=EXCLUDED.rating_rate, rating_count=EXCLUDED.rating_count, updated_at=NOW()
		`, p.ID, p.Title, p.Price, p.Description, p.Category, p.Image, discount, p.Rating.Rate, p.Rating.Count)
		if err != nil {
			return fmt.Errorf("upsert product %d: %w", p.ID, err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return err
	}
	log.Printf("synced %d products", len(products))
	return nil
}

// Discounts here are illustrative banner content, not pricing logic.
func pseudoDiscount(id int) int {
	buckets := []int{0, 0, 10, 15, 20, 25, 30, 40}
	return buckets[id%len(buckets)]
}

func listProducts(w http.ResponseWriter, r *http.Request) {
	category := r.URL.Query().Get("category")
	query := `SELECT id, title, price, description, category, image, discount, rating_rate, rating_count
	          FROM products`
	args := []any{}
	if category != "" {
		query += ` WHERE category=$1`
		args = append(args, category)
	}
	query += ` ORDER BY id`

	rows, err := pool.Query(r.Context(), query, args...)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()

	var out []Product
	for rows.Next() {
		var p Product
		if err := rows.Scan(&p.ID, &p.Title, &p.Price, &p.Description, &p.Category,
			&p.Image, &p.Discount, &p.Rating.Rate, &p.Rating.Count); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		out = append(out, p)
	}
	writeJSON(w, out)
}

func getProduct(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var p Product
	err := pool.QueryRow(r.Context(), `
		SELECT id, title, price, description, category, image, discount, rating_rate, rating_count
		FROM products WHERE id=$1`, id).Scan(
		&p.ID, &p.Title, &p.Price, &p.Description, &p.Category,
		&p.Image, &p.Discount, &p.Rating.Rate, &p.Rating.Count)
	if err != nil {
		http.Error(w, "not found", 404)
		return
	}
	writeJSON(w, p)
}

func listCategories(w http.ResponseWriter, r *http.Request) {
	rows, err := pool.Query(r.Context(), `SELECT DISTINCT category FROM products ORDER BY category`)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()
	var cats []string
	for rows.Next() {
		var c string
		_ = rows.Scan(&c)
		cats = append(cats, c)
	}
	writeJSON(w, cats)
}

func manualSync(w http.ResponseWriter, r *http.Request) {
	if err := syncFromFakeStore(r.Context()); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]string{"status": "ok"})
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	if err := pool.Ping(r.Context()); err != nil {
		http.Error(w, "db down", 503)
		return
	}
	writeJSON(w, map[string]string{"status": "up"})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
