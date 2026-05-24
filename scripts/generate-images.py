#!/usr/bin/env python3
"""
Generate AI product images for the storefront at build time.

For each product returned by https://fakestoreapi.com/products this script
generates a clean, on-brand product photo using OpenAI's image API and writes
it to ui-service/src/main/resources/static/images/products/<id>.png.

The Catalog service can then be configured to rewrite image URLs from the
upstream API to these local copies (see scripts/rewrite-image-urls.sql).

Usage:
    export OPENAI_API_KEY=sk-...
    python scripts/generate-images.py                # all 20 products
    python scripts/generate-images.py --only 1 5 7   # specific IDs only
    python scripts/generate-images.py --dry-run      # preview prompts
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

FAKESTORE_URL = "https://fakestoreapi.com/products"
OUT_DIR = Path(__file__).resolve().parent.parent / "ui-service" / "src" / "main" / "resources" / "static" / "images" / "products"
OPENAI_IMAGE_URL = "https://api.openai.com/v1/images/generations"
MODEL = "gpt-image-1"  # high quality, supports b64_json
SIZE = "1024x1024"


def fetch_products() -> list[dict]:
    with urlopen(FAKESTORE_URL, timeout=30) as r:
        return json.loads(r.read())


def prompt_for(product: dict) -> str:
    title = product["title"]
    category = product["category"]
    return (
        f"Product photography of: {title}. "
        f"Category: {category}. "
        "Clean, modern e-commerce product shot. Soft studio lighting, "
        "subtle violet-to-cyan gradient background, slight floor reflection. "
        "Centered, full product visible, no text, no watermark, photorealistic, "
        "premium catalog aesthetic, 1:1 square framing."
    )


def generate(api_key: str, prompt: str) -> bytes:
    body = json.dumps({
        "model": MODEL,
        "prompt": prompt,
        "size": SIZE,
        "n": 1,
        "response_format": "b64_json",
    }).encode()
    req = Request(
        OPENAI_IMAGE_URL,
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urlopen(req, timeout=120) as r:
        payload = json.loads(r.read())
    return base64.b64decode(payload["data"][0]["b64_json"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", type=int, nargs="*", help="Generate only these product IDs")
    parser.add_argument("--dry-run", action="store_true", help="Print prompts without calling the API")
    parser.add_argument("--force", action="store_true", help="Overwrite existing images")
    args = parser.parse_args()

    api_key = os.environ.get("OPENAI_API_KEY")
    if not args.dry_run and not api_key:
        print("ERROR: OPENAI_API_KEY is not set", file=sys.stderr)
        return 2

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    products = fetch_products()
    if args.only:
        wanted = set(args.only)
        products = [p for p in products if p["id"] in wanted]

    print(f"Processing {len(products)} products → {OUT_DIR}")

    for p in products:
        out = OUT_DIR / f"{p['id']}.png"
        if out.exists() and not args.force:
            print(f"  skip #{p['id']} (exists; use --force to regenerate)")
            continue

        prompt = prompt_for(p)
        if args.dry_run:
            print(f"  #{p['id']:>2}  [{p['category']}]  {prompt[:80]}...")
            continue

        print(f"  gen  #{p['id']:>2}  {p['title'][:50]}...")
        try:
            data = generate(api_key, prompt)
            out.write_bytes(data)
        except HTTPError as e:
            print(f"     ! HTTP {e.code}: {e.read().decode()[:200]}", file=sys.stderr)
        except Exception as e:
            print(f"     ! {e}", file=sys.stderr)

        # Stay under OpenAI's image rate limits.
        time.sleep(1)

    print("done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
