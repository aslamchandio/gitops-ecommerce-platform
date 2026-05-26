# Project images and diagrams

Production-grade visual assets for the project — used in the repo
README, GitHub social card, LinkedIn posts, and slide decks.

```
docs/
├── diagrams/                Mermaid source (edit here)
│   ├── architecture.mmd     Full system topology
│   ├── release-flow.mmd     git tag -> live in ~3 minutes
│   └── observability.mmd    GMP + Grafana pipeline
└── images/                  Rendered PNG + SVG output (gitignored if you prefer)
    ├── architecture.{png,svg}
    ├── release-flow.{png,svg}
    └── observability.{png,svg}
```

The diagrams are written in [Mermaid](https://mermaid.js.org/) so they
stay in git (text, diffable, reviewable) and render natively in any
GitHub markdown file. The rendered PNG/SVG copies are what you upload
to LinkedIn or paste into a slide.

---

## Rendering locally

Requires Docker. No Node / npm install needed.

```bash
# Render all 3 diagrams to docs/images/*.png and *.svg
scripts/render-diagrams.sh

# Or one at a time
scripts/render-diagrams.sh architecture
scripts/render-diagrams.sh observability release-flow
```

The script pulls `minlag/mermaid-cli:latest` (the official image) on
first run and outputs 1920px-wide files with a dark background that
matches the diagram theme. Re-run after editing any `.mmd` source.

---

## Embedding in GitHub markdown

Mermaid blocks render inline on github.com — no images needed for the
repo itself:

````markdown
```mermaid
flowchart LR
  A --> B
```
````

For larger diagrams you can reference the source file directly:

````markdown
![Architecture](docs/images/architecture.png)
````

---

## LinkedIn post recipe

LinkedIn caches the OpenGraph image at first share. To get the diagram
to appear as the link preview:

1. Render PNGs: `scripts/render-diagrams.sh`
2. Pick one (architecture is usually the strongest hero image).
3. When drafting the post, click the image icon and upload the PNG
   directly — don't rely on link previews, which compress aggressively.
4. LinkedIn's preferred dimensions are **1200x627** for share images
   and **1200x1200** for inline post images. The 1920px source crops
   cleanly to either.

For carousel posts (multi-image), upload in this order:
1. `architecture.png` — the wow shot
2. `observability.png` — shows depth
3. `release-flow.png` — shows velocity
4. (optional) screenshot of Grafana dashboard or the live site

---

## Editing diagrams

Each `.mmd` file is a self-contained Mermaid document with an
`%%{init: {...}}%%` header pinning the colour theme so all three
diagrams look like a coherent set. Edit the `themeVariables` block at
the top of one file and copy it to the others if you want to re-brand.

The class definitions inside each diagram (`classDef java fill:#...`)
control which colour a node uses — keep them consistent across the
set so the same component (e.g. Spring Boot service) is always the
same colour wherever it appears.

After editing, re-render with `scripts/render-diagrams.sh <name>` and
commit both the `.mmd` source and the regenerated `images/<name>.png`
and `.svg`.

---

## Why not AI-generated artwork?

Mermaid diagrams are:

- **Deterministic** — same source, same output, every time.
- **Editable** — fix a typo with a one-line edit, not a re-prompt.
- **Source-of-truth** — the diagram and the README describe the same
  system because they live in the same repo.
- **Free** — no API key, no per-render cost.
- **Scalable** — SVG is sharp at any size; PNG renders crisply on
  retina displays.

If you specifically want a branded hero banner (illustrated, photo-
realistic, etc.), extend [`scripts/generate-images.py`](../scripts/generate-images.py)
— it already wraps the OpenAI image API for product photo generation
and can be pointed at a banner prompt.
