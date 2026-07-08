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

**Live:** https://firmament-tau.vercel.app

## Repository layout

```
Firmament/
  README.md
  docs/
    SPEC.md          # the build specification — the constitution of the build
  site/              # the landing page (static, zero-build)
    index.html
    styles.css
    sky.js           # canvas sky, THE FOLD scroll-scrub, ledger spine, form
    fonts.css        # self-hosted @font-face (Spectral / Hanken / IBM Plex Mono)
    fonts/           # latin-subset woff2
  app/               # the Swift app (later)
```

## The landing page — "The Ledger Made Law"

An editorial constitution rendered on a live night sky. Static HTML/CSS/vanilla JS —
no framework, no build step, no runtime dependencies (fonts are self-hosted). The
concept: the page obeys its own product's first law. As you scroll, an append-only
**ledger spine** writes itself down the left margin; the centerpiece, **THE FOLD**, is
a scroll-scrubbed split screen that enacts *"one breath → a star with a history"* — an
agent's terminal and a human's igniting star reading the same event stream two ways;
and **THE REFUSAL** shows the Gate withhold a Sanctum memory, where no star ignites.

Type system, strict roles: **Spectral** (serif) = law/display, **Hanken Grotesk** =
UI/human voice, **IBM Plex Mono** = machine voice. Palette: cream on midnight with
low-saturation star-kind tints and a periwinkle accent. Accessible (WCAG AA,
keyboard-operable, `aria-live`), reduced-motion-equal, and compositor-only for 120 fps.

### Run it locally

Any static server works:

```sh
python3 -m http.server 4000 --directory site
# open http://localhost:4000
```

Or open `site/index.html` directly in a browser.

### Wire up the waitlist

The "request access" form works with zero backend. Open `site/sky.js` and set one of
the two config values at the top (`const WAITLIST = { endpoint: "", mailto: "" }`):

- `WAITLIST.endpoint` — a [Formspree](https://formspree.io) (or similar) POST URL.
  Submissions are sent there and the visitor sees the append-confirmation.
- `WAITLIST.mailto` — an email address. With no endpoint set, submitting opens the
  visitor's mail client, pre-filled to this address.

With neither set, the form validates and honestly reports that the waitlist isn't
collecting yet — it never fabricates a signup.

### Deploy

It's static, so anything serves it. Currently on **Vercel** (project `firmament`,
production alias `firmament-tau.vercel.app`):

```sh
vercel deploy --cwd site --prod
```

GitHub Pages (point at `/site`), Netlify, or Cloudflare Pages work with no config.

## Design language: Nocturne

Near-black field with a barely-perceptible blue-violet radial breath. Stars with soft
bloom, hued by kind within a narrow saturation band — a night sky, not a dashboard.
Serif with real italics for law and manifesto text; a quiet grotesk for the human
voice; monospace for the machine. Motion eases with strong, snappy curves, is
compositor-only, and respects `prefers-reduced-motion`.
