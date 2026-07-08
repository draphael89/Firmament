# Firmament

**A private brain for one mind. Voice-first. Agent-legible. Mac-native.**

Firmament is an *identity substrate*: it captures the raw material of a mind (voice
notes, text, fragments), compounds it into structured knowledge overnight, and serves
two clients as equals — the human who authored it, through a spatial interface worth
inhabiting, and AI agents, through a consent-gated MCP surface that injects not just
what the operator knows but who they are.

> *Firmament — the fixed vault of sky against which everything else moves.*

The full architecture lives in [`docs/SPEC.md`](docs/SPEC.md). This repository currently
holds the **landing page**; the native app (Swift, macOS 26 / iOS 26) lands in `app/`.

## Repository layout

```
Firmament/
  README.md
  docs/
    SPEC.md          # the build specification — the constitution of the build
  site/              # the landing page (static, zero-build)
    index.html
    styles.css
    constellation.js
  app/               # the Swift app (later)
```

## The landing page

Static HTML/CSS/vanilla JS. No framework, no build step, no dependencies. The hero is a
live constellation rendered on `<canvas>` — an echo of the app's Atlas — that drifts,
twinkles, parallaxes to the cursor, and draws hairline edges between nearby stars.

### Run it locally

Any static server works. From the repo root:

```sh
cd site
python3 -m http.server 4000
# open http://localhost:4000
```

Or just open `site/index.html` directly in a browser.

### Wire up the waitlist

The "request access" form works with zero backend. Open `site/index.html` and set one
of the two config values near the top of the inline `<script>`:

- `WAITLIST.endpoint` — a [Formspree](https://formspree.io) (or similar) POST URL. If
  set, submissions are sent there and the visitor sees a success state.
- `WAITLIST.mailto` — an email address. If no endpoint is set, submitting opens the
  visitor's mail client with a pre-filled message to this address.

If neither is set, the form still validates and confirms, but nothing is collected —
so set one before going live.

### Deploy

It's static, so anything serves it: GitHub Pages (point at `/site`), Vercel, Netlify,
Cloudflare Pages. No configuration required.

## Design language: Nocturne

Near-black field with a barely-perceptible blue-violet radial breath. Stars with soft
bloom, hued by kind within a narrow saturation band — a night sky, not a dashboard. A
quiet grotesk for UI; a serif with real italics for law and manifesto text. Motion eases
with strong, snappy curves and respects `prefers-reduced-motion`.
