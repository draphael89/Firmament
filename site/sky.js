/* ═══════════════════════════════════════════════════════════════════════════
   FIRMAMENT — "The Ledger Made Law"
   Seeded star field · the append-only transit spine · THE FOLD scroll-scrub ·
   the request-access seal. Deterministic before intelligent: the sky is a pure
   function of a fixed seed; the Fold is a pure function of scroll.
   Vanilla JS, no dependencies.
   ═══════════════════════════════════════════════════════════════════════════ */

/* Waitlist: set ONE to actually collect (see README). Empty = validate + confirm. */
const WAITLIST = { endpoint: "", mailto: "" };

(() => {
  "use strict";
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
  const lerp = (a, b, t) => a + (b - a) * t;
  const smooth = (t) => { t = clamp(t, 0, 1); return t * t * (3 - 2 * t); };
  const range = (v, a, b) => smooth((v - a) / (b - a));

  /* ── Seeded PRNG ─────────────────────────────────────────────────────────── */
  function mulberry32(seed) {
    return function () {
      seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
      let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  /* ── Star field ──────────────────────────────────────────────────────────── */
  const HUES = [
    [246, 248, 255], [255, 250, 242], [255, 217, 160],
    [217, 244, 255], [226, 210, 255], [213, 255, 230], [238, 240, 255],
  ];
  const HUE_W = [30, 20, 8, 8, 6, 4, 24]; // weighted toward blue/near-white
  const canvas = document.getElementById("sky");
  const ctx = canvas && canvas.getContext("2d", { alpha: true });
  let W = 0, H = 0, dpr = 1, stars = [], sprites = [];
  const pointer = { x: 0, y: 0, active: false };
  const focus = { x: 0, y: 0 };

  function buildSprites() {
    sprites = HUES.map((rgb) => {
      const s = 64, c = document.createElement("canvas");
      c.width = c.height = s;
      const g = c.getContext("2d");
      const r = s / 2, grad = g.createRadialGradient(r, r, 0, r, r, r);
      grad.addColorStop(0, "rgba(255,255,255,1)");
      grad.addColorStop(0.16, `rgba(${rgb[0]},${rgb[1]},${rgb[2]},0.95)`);
      grad.addColorStop(0.42, `rgba(${rgb[0]},${rgb[1]},${rgb[2]},0.22)`);
      grad.addColorStop(1, `rgba(${rgb[0]},${rgb[1]},${rgb[2]},0)`);
      g.fillStyle = grad; g.fillRect(0, 0, s, s);
      return c;
    });
  }
  function pickHue(rnd) {
    const tot = HUE_W.reduce((a, b) => a + b, 0); let r = rnd() * tot;
    for (let i = 0; i < HUE_W.length; i++) { if ((r -= HUE_W[i]) <= 0) return i; }
    return 0;
  }
  function seedStars() {
    const rnd = mulberry32(0x9173);
    const cores = navigator.hardwareConcurrency || 8;
    const density = W < 760 ? 0.00006 : 0.00009;
    let n = Math.round(clamp(W * H * density, 60, cores < 6 ? 110 : 190));
    stars = [];
    for (let i = 0; i < n; i++) {
      const b = rnd();
      stars.push({
        x: rnd() * W, y: rnd() * H,
        r: 0.5 + b * b * 2.2, hue: pickHue(rnd),
        base: 0.22 + b * 0.6, tw: 0.14 + rnd() * 0.34, sp: 0.4 + rnd() * 1.1,
        ph: rnd() * 6.283, depth: 0.3 + rnd() * 0.7,
        vx: (rnd() - 0.5) * 0.035, vy: (rnd() - 0.5) * 0.035, fixed: false,
      });
    }
    for (let i = 0; i < 6; i++) {
      stars.push({
        x: 60 + rnd() * (W - 120), y: 60 + rnd() * (H - 120),
        r: 1.9 + rnd() * 1.0, hue: 0, base: 0.86, tw: 0.05, sp: 0.3,
        ph: rnd() * 6.283, depth: 0.22, vx: 0, vy: 0, fixed: true,
      });
    }
  }
  function resizeSky() {
    if (!canvas) return;
    dpr = Math.min(devicePixelRatio || 1, 2);
    W = innerWidth; H = innerHeight;
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    canvas.style.width = W + "px"; canvas.style.height = H + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    pointer.x = focus.x = W / 2; pointer.y = focus.y = H / 2;
    seedStars();
    if (reduce) drawSky(0);
  }
  function drawSky(t) {
    if (!ctx) return;
    ctx.clearRect(0, 0, W, H);
    focus.x += (pointer.x - focus.x) * 0.05;
    focus.y += (pointer.y - focus.y) * 0.05;
    const ox = pointer.active ? ((focus.x - W / 2) / (W / 2)) * 6 : 0;
    const oy = pointer.active ? ((focus.y - H / 2) / (H / 2)) * 6 : 0;
    ctx.globalCompositeOperation = "lighter";
    for (const s of stars) {
      if (!reduce) {
        s.x += s.vx; s.y += s.vy;
        const m = 34;
        if (s.x < -m) s.x = W + m; else if (s.x > W + m) s.x = -m;
        if (s.y < -m) s.y = H + m; else if (s.y > H + m) s.y = -m;
      }
      const px = s.x + ox * s.depth, py = s.y + oy * s.depth;
      s._x = px; s._y = py;
      const tw = reduce ? s.base : s.base + s.tw * Math.sin(t * 0.001 * s.sp + s.ph);
      const a = clamp(tw, 0, 1), size = s.r * 7.2;
      ctx.globalAlpha = a;
      ctx.drawImage(sprites[s.hue], px - size / 2, py - size / 2, size, size);
      ctx.globalAlpha = Math.min(1, a + 0.14);
      ctx.beginPath(); ctx.arc(px, py, s.r * 0.7, 0, 6.283); ctx.fillStyle = "#fff"; ctx.fill();
      if (s.fixed) {
        ctx.globalAlpha = 0.2; ctx.beginPath(); ctx.arc(px, py, s.r * 3, 0, 6.283);
        ctx.strokeStyle = "rgba(174,184,255,.9)"; ctx.lineWidth = 1; ctx.stroke();
      }
    }
    // focus edges near cursor
    if (pointer.active && !reduce) {
      const near = [];
      for (const s of stars) {
        const dx = s._x - pointer.x, dy = s._y - pointer.y;
        if (dx * dx + dy * dy < 12100) near.push(s);
      }
      ctx.lineWidth = 1;
      for (let i = 0; i < near.length; i++) {
        const a = near[i], ad = Math.hypot(a._x - pointer.x, a._y - pointer.y), af = 1 - ad / 110;
        for (let j = i + 1; j < near.length; j++) {
          const b = near[j], d = Math.hypot(a._x - b._x, a._y - b._y);
          if (d > 116) continue;
          const al = af * (1 - d / 116) * 0.45; if (al < 0.02) continue;
          ctx.globalAlpha = al; ctx.strokeStyle = "rgba(174,184,255,.9)";
          ctx.beginPath(); ctx.moveTo(a._x, a._y); ctx.lineTo(b._x, b._y); ctx.stroke();
        }
      }
    }
    ctx.globalAlpha = 1; ctx.globalCompositeOperation = "source-over";
  }

  /* ── The ledger spine — nodes + transit ──────────────────────────────────── */
  const rail = document.getElementById("rail");
  const page = document.querySelector(".page");
  const sectionEls = Array.from(document.querySelectorAll("[data-node]"));
  const nodeFor = new Map();
  function hex6(i) { // deterministic pseudo-hash per node
    const r = mulberry32(0x51ed + i * 977); let s = "";
    for (let k = 0; k < 6; k++) s += "0123456789abcdef"[Math.floor(r() * 16)];
    return s;
  }
  function layoutRail() {
    if (!rail || !page || reduce) return;
    nodeFor.forEach((n) => n.remove()); nodeFor.clear();
    const pageTop = page.offsetTop, pageH = page.offsetHeight;
    sectionEls.forEach((sec, i) => {
      const top = sec.offsetTop - pageTop;
      const node = document.createElement("div");
      node.className = "rail__node";
      node.style.top = (top / pageH) * 100 + "%";
      node.innerHTML = `<span class="rail__hash">${sec.dataset.node} · ${hex6(i)}</span>`;
      rail.appendChild(node); nodeFor.set(sec, node);
    });
  }

  /* ── THE FOLD scrub ──────────────────────────────────────────────────────── */
  const fold = document.getElementById("fold");
  const foldStar = document.getElementById("fold-star");
  const foldWave = document.getElementById("fold-wave");
  const foldEdges = document.getElementById("fold-edges");
  const foldLineage = document.getElementById("fold-lineage");
  const foldCap = document.getElementById("fold-caption");
  const foldProg = document.getElementById("fold-progress");
  const foldConduit = document.getElementById("fold-conduit");
  const dawn = document.getElementById("dawn");
  const termLines = Array.from(document.querySelectorAll(".fold__line, .term__line[data-beat]"));
  const progBars = foldProg ? Array.from(foldProg.children) : [];
  const edgePaths = foldEdges ? Array.from(foldEdges.querySelectorAll("path")) : [];
  const CAPTIONS = ["06:41 — one breath", "the words settle", "a claim is made", "the night re-weaves it", "A star with a history."];
  let foldTop = 0, foldH = 0, disp = 0, lastBeat = -1, maxScroll = 0;
  function measureFold() {
    maxScroll = document.documentElement.scrollHeight - innerHeight;  // cached — no per-frame reflow
    if (!fold) return;
    const r = fold.getBoundingClientRect();
    foldTop = r.top + scrollY; foldH = fold.offsetHeight;
  }
  function updateFold() {
    if (!fold || reduce) return;
    const p = clamp((scrollY - foldTop) / Math.max(1, foldH - innerHeight), 0, 1);
    disp += (p - disp) * 0.11;
    const d = disp;
    // star ignite: brighten first (.34–.52), then finish growing (.36–.62) — no muddy middle
    const igScale = range(d, 0.36, 0.62), igOp = range(d, 0.34, 0.52);
    if (foldStar) { foldStar.style.transform = `scale(${(0.06 + igScale * 0.98).toFixed(3)})`; foldStar.style.opacity = igOp.toFixed(3); }
    // waveform: full 0–.18, collapses .18–.36, fades by .40
    if (foldWave) {
      const collapse = 1 - range(d, 0.18, 0.36) * 0.94;
      foldWave.style.transform = `scaleY(${collapse.toFixed(3)})`;
      foldWave.style.opacity = (1 - range(d, 0.30, 0.42)).toFixed(3);
    }
    // dream edges draw toward faint elder stars .58–.80
    const draw = range(d, 0.58, 0.80);
    if (foldEdges) foldEdges.style.opacity = draw.toFixed(3);
    edgePaths.forEach((pp) => { pp.style.strokeDasharray = "1"; pp.style.strokeDashoffset = (1 - draw).toFixed(3); });
    // lineage resolves .82–1
    if (foldLineage) foldLineage.style.opacity = range(d, 0.82, 1).toFixed(3);
    // dawn: rise to ≤.08 by .74, hold, settle to .05 by 1
    if (dawn) { const rise = range(d, 0.58, 0.74) * 0.08; const settle = range(d, 0.94, 1) * 0.03; dawn.style.opacity = Math.max(0, rise - settle).toFixed(3); }
    // the conduit: the event crossing from the agent's read to the human's star during ignite
    if (foldConduit) {
      const cp = range(d, 0.40, 0.58);
      foldConduit.style.left = (38 + cp * 34).toFixed(2) + "%";
      foldConduit.style.opacity = (cp > 0 && cp < 1 ? Math.sin(cp * Math.PI) : 0).toFixed(3);
    }
    // beat index
    const beat = d < 0.18 ? 0 : d < 0.38 ? 1 : d < 0.58 ? 2 : d < 0.80 ? 3 : 4;
    if (beat !== lastBeat) {
      lastBeat = beat;
      termLines.forEach((l) => {
        l.classList.toggle("is-on", +l.dataset.beat <= beat);
        l.classList.toggle("is-active", +l.dataset.beat === beat);  // bind the line being read to the star
      });
      progBars.forEach((b, i) => b.classList.toggle("on", i <= beat));
      if (foldCap) foldCap.textContent = CAPTIONS[beat];
    }
  }

  /* ── Reveal + nav + node lighting ────────────────────────────────────────── */
  const revealIO = new IntersectionObserver((es) => {
    for (const e of es) if (e.isIntersecting) { e.target.classList.add("is-visible"); revealIO.unobserve(e.target); }
  }, { threshold: 0.12, rootMargin: "0px 0px -7% 0px" });
  document.querySelectorAll(".reveal").forEach((el) => revealIO.observe(el));

  const nav = document.getElementById("nav");
  const litIO = new IntersectionObserver((es) => {
    for (const e of es) { const n = nodeFor.get(e.target); if (n) n.classList.toggle("is-lit", e.isIntersecting); }
  }, { rootMargin: "-42% 0px -52% 0px" });
  sectionEls.forEach((s) => litIO.observe(s));

  // Gate: announce the Sanctum withhold when reached (aria-live only fires on mutation)
  const gateAnnounce = document.getElementById("gate-announce");
  const gateSection = document.querySelector(".gate");
  if (gateAnnounce && gateSection && "IntersectionObserver" in window) {
    const gIO = new IntersectionObserver((es) => {
      for (const e of es) if (e.isIntersecting) { gateAnnounce.textContent = "1 event withheld — Sanctum tier."; gIO.disconnect(); }
    }, { threshold: 0.4 });
    gIO.observe(gateSection);
  }
  // Organ nodes: keyboard-operable (Enter/Space toggles the definition)
  document.querySelectorAll(".organ").forEach((o) => o.addEventListener("click", () => o.classList.toggle("is-open")));

  /* ── Request access ──────────────────────────────────────────────────────── */
  const form = document.getElementById("request-form");
  const status = document.getElementById("request-status");
  const seal = document.getElementById("request-seal");
  const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  function say(m, err) { if (!status) return; status.textContent = m; status.classList.toggle("err", !!err); status.classList.add("show"); }
  function sealAnim() {
    if (!seal || reduce) return;
    const ring = seal.querySelector("circle"); if (!ring || !ring.animate) return;
    ring.animate([{ strokeDashoffset: 1 }, { strokeDashoffset: 0 }], { duration: 700, easing: "cubic-bezier(0.22,0.61,0.36,1)", fill: "forwards" });
  }
  if (form) form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const input = form.elements.email, email = (input.value || "").trim(), btn = form.querySelector("button");
    if (!EMAIL.test(email)) { say("That email doesn't look right — mind checking it?", true); input.focus(); return; }
    btn.disabled = true;
    const node = btn.querySelector(".node");
    if (node && node.animate && !reduce) node.animate([{ transform: "scale(1)" }, { transform: "scale(2.4)" }, { transform: "scale(1)" }], { duration: 500, easing: "cubic-bezier(0.34,1.4,0.64,1)" });
    sealAnim();
    try {
      if (WAITLIST.endpoint) {
        const res = await fetch(WAITLIST.endpoint, { method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json" }, body: JSON.stringify({ email }) });
        if (!res.ok) throw 0; form.reset(); say("Entry appended. You are in the ledger.");
      } else if (WAITLIST.mailto) {
        location.href = `mailto:${WAITLIST.mailto}?subject=${encodeURIComponent("Firmament — request access")}&body=${encodeURIComponent("Please add me to the waitlist: " + email)}`;
        say("Opening your mail client to finish…");
      } else {
        console.warn("[Firmament] Waitlist not wired — set WAITLIST.endpoint or WAITLIST.mailto in sky.js.");
        say("The waitlist isn't collecting yet — check back soon.");
      }
    } catch (_) { say("Something went wrong sending that. Try again in a moment?", true); }
    finally { btn.disabled = false; }
  });

  /* ── Main loop ───────────────────────────────────────────────────────────── */
  let running = false, fpsEl = document.getElementById("fps-readout"), frames = 0, fpsT = 0;
  function tick(t) {
    drawSky(t);
    updateFold();
    // transit (uses cached maxScroll — no forced reflow this frame)
    document.documentElement.style.setProperty("--transit", maxScroll > 0 ? clamp(scrollY / maxScroll, 0, 1) : 0);
    if (nav) nav.classList.toggle("is-scrolled", scrollY > 24);
    // fps — only publish the number when it actually proves the claim (≥90); else stay silent
    frames++; if (t - fpsT >= 1000) { const v = Math.round((frames * 1000) / (t - fpsT)); if (fpsEl) fpsEl.textContent = v >= 116 ? v + " fps" : ""; frames = 0; fpsT = t; }
    if (running) requestAnimationFrame(tick);
  }
  function start() { if (running) return; running = true; requestAnimationFrame(tick); }
  function stop() { running = false; }

  /* ── Wire up ─────────────────────────────────────────────────────────────── */
  addEventListener("pointermove", (e) => { pointer.x = e.clientX; pointer.y = e.clientY; pointer.active = matchMedia("(pointer:fine)").matches; }, { passive: true });
  addEventListener("pointerleave", () => { pointer.active = false; pointer.x = W / 2; pointer.y = H / 2; });
  let rt; addEventListener("resize", () => { clearTimeout(rt); rt = setTimeout(() => { resizeSky(); measureFold(); layoutRail(); }, 140); }, { passive: true });
  document.addEventListener("visibilitychange", () => { document.hidden ? stop() : start(); });

  buildSprites(); resizeSky(); measureFold(); layoutRail();
  if (reduce) {
    // one static composed frame; still show fps + transit static
    drawSky(0);
    termLines.forEach((l) => l.classList.add("is-on"));
    progBars.forEach((b) => b.classList.add("on"));
    if (foldCap) foldCap.textContent = CAPTIONS[4];
    if (foldLineage) foldLineage.style.opacity = 1;
  } else {
    start();
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { measureFold(); layoutRail(); });
    setTimeout(() => { measureFold(); layoutRail(); }, 400);
  }
})();
