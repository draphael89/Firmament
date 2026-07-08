/* ───────────────────────────────────────────────────────────────────────────
   FIRMAMENT — the sky
   A living constellation on <canvas>. Stars drift, twinkle, and parallax to the
   cursor; hairline edges fade in within a focus radius around the pointer — an
   echo of the app's Atlas. Additive blending gives the bloom. Respects
   prefers-reduced-motion: renders one calm static field, no motion.
   Vanilla JS, zero dependencies.
   ─────────────────────────────────────────────────────────────────────────── */

(() => {
  "use strict";

  const canvas = document.getElementById("sky");
  if (!canvas) return;
  const ctx = canvas.getContext("2d", { alpha: true });

  const reduceMotion = window.matchMedia(
    "(prefers-reduced-motion: reduce)"
  ).matches;

  // Star kinds → hue, mirroring the Atlas (people warm-white, concepts
  // cyan-white, projects amber, works violet, places green-white). Weighted
  // heavily toward the blue-whites so it reads as a night sky, not a dashboard.
  const PALETTE = [
    { c: "#eef1ff", w: 42 }, // blue-white
    { c: "#f5f7ff", w: 22 }, // near-white
    { c: "#fff2df", w: 12 }, // people — warm-white
    { c: "#e4fbff", w: 10 }, // concepts — cyan-white
    { c: "#ffe6b8", w: 6 },  // projects — amber
    { c: "#ece0ff", w: 5 },  // works — violet
    { c: "#e6fff2", w: 3 },  // places — green-white
  ];

  // ── Pre-rendered glow sprites (one per colour) for cheap additive draws ────
  const SPRITE = 72;
  const spriteCache = new Map();
  function glowSprite(color) {
    if (spriteCache.has(color)) return spriteCache.get(color);
    const s = document.createElement("canvas");
    s.width = s.height = SPRITE;
    const g = s.getContext("2d");
    const r = SPRITE / 2;
    const grad = g.createRadialGradient(r, r, 0, r, r, r);
    grad.addColorStop(0.0, "rgba(255,255,255,1)");
    grad.addColorStop(0.12, hexToRGBA(color, 0.95));
    grad.addColorStop(0.42, hexToRGBA(color, 0.28));
    grad.addColorStop(1.0, hexToRGBA(color, 0));
    g.fillStyle = grad;
    g.fillRect(0, 0, SPRITE, SPRITE);
    spriteCache.set(color, s);
    return s;
  }

  function hexToRGBA(hex, a) {
    const n = parseInt(hex.slice(1), 16);
    return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
  }

  function pickColor() {
    const total = PALETTE.reduce((s, p) => s + p.w, 0);
    let r = Math.random() * total;
    for (const p of PALETTE) {
      if ((r -= p.w) <= 0) return p.c;
    }
    return PALETTE[0].c;
  }

  // ── State ──────────────────────────────────────────────────────────────────
  let dpr = 1;
  let W = 0;
  let H = 0;
  let stars = [];

  // Pointer (device px) and its smoothed follower, for critically-damped
  // parallax. On load the focus sits at centre.
  const pointer = { x: 0, y: 0, active: false };
  const focus = { x: 0, y: 0 };

  const PARALLAX = 22;     // px of drift for a foreground star, edge-to-edge
  const LINK_RADIUS = 150; // px around the pointer where edges appear
  const LINK_DIST = 118;   // max px between two stars for an edge

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = Math.floor(W * dpr);
    canvas.height = Math.floor(H * dpr);
    canvas.style.width = W + "px";
    canvas.style.height = H + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    pointer.x = focus.x = W / 2;
    pointer.y = focus.y = H / 2;
    seed();
    if (reduceMotion) draw(0); // one static frame
  }

  function seed() {
    const area = W * H;
    const count = Math.round(Math.min(170, Math.max(60, area / 13500)));
    const fixedCount = Math.round(count * 0.045); // "fixed stars" — the constants
    stars = [];
    for (let i = 0; i < count; i++) {
      const fixed = i < fixedCount;
      const depth = fixed ? 0.25 : 0.35 + Math.random() * 0.65; // parallax factor
      stars.push({
        x: Math.random() * W,
        y: Math.random() * H,
        // slow drift, scaled by depth so far stars barely move
        vx: (Math.random() - 0.5) * 0.05 * depth,
        vy: (Math.random() - 0.5) * 0.05 * depth,
        depth,
        color: fixed ? "#f7f8ff" : pickColor(),
        radius: fixed ? 2.6 + Math.random() * 1.1 : 0.7 + Math.random() * 1.7,
        base: fixed ? 0.85 : 0.28 + Math.random() * 0.5,   // base brightness
        amp: fixed ? 0.05 : 0.12 + Math.random() * 0.28,    // twinkle amplitude
        speed: 0.4 + Math.random() * 1.1,                    // twinkle speed
        phase: Math.random() * Math.PI * 2,
        fixed,
      });
    }
  }

  // ── Draw ───────────────────────────────────────────────────────────────────
  function draw(t) {
    ctx.clearRect(0, 0, W, H);

    // ease the focus toward the pointer (spring-ish, frame-rate independent-ish)
    focus.x += (pointer.x - focus.x) * 0.06;
    focus.y += (pointer.y - focus.y) * 0.06;
    const offX = ((focus.x - W / 2) / (W / 2)) * PARALLAX;
    const offY = ((focus.y - H / 2) / (H / 2)) * PARALLAX;

    // Positions after drift + parallax, cached for the edge pass.
    ctx.globalCompositeOperation = "lighter";
    for (const s of stars) {
      if (!reduceMotion) {
        s.x += s.vx;
        s.y += s.vy;
        // toroidal wrap with a margin so stars never pop at the edge
        const m = 40;
        if (s.x < -m) s.x = W + m;
        else if (s.x > W + m) s.x = -m;
        if (s.y < -m) s.y = H + m;
        else if (s.y > H + m) s.y = -m;
      }
      const px = s.x + offX * s.depth;
      const py = s.y + offY * s.depth;
      s._px = px;
      s._py = py;

      const tw = reduceMotion
        ? s.base
        : s.base + s.amp * Math.sin(t * 0.001 * s.speed + s.phase);
      const bright = Math.max(0, Math.min(1, tw));

      // glow sprite
      const size = s.radius * 7.5;
      ctx.globalAlpha = bright;
      ctx.drawImage(
        glowSprite(s.color),
        px - size / 2,
        py - size / 2,
        size,
        size
      );

      // hard core for a crisp point
      ctx.globalAlpha = Math.min(1, bright + 0.15);
      ctx.beginPath();
      ctx.arc(px, py, s.radius * 0.72, 0, Math.PI * 2);
      ctx.fillStyle = "#ffffff";
      ctx.fill();

      // fixed stars carry a faint steady ring — the sky's navigational constants
      if (s.fixed) {
        ctx.globalAlpha = 0.22;
        ctx.beginPath();
        ctx.arc(px, py, s.radius * 3.2, 0, Math.PI * 2);
        ctx.strokeStyle = "rgba(174,184,255,0.9)";
        ctx.lineWidth = 1;
        ctx.stroke();
      }
    }
    ctx.globalAlpha = 1;

    // ── Edges near the pointer ────────────────────────────────────────────────
    if (pointer.active && !reduceMotion) {
      const near = [];
      for (const s of stars) {
        const dx = s._px - pointer.x;
        const dy = s._py - pointer.y;
        if (dx * dx + dy * dy < LINK_RADIUS * LINK_RADIUS) near.push(s);
      }
      ctx.lineWidth = 1;
      for (let i = 0; i < near.length; i++) {
        const a = near[i];
        // proximity of this star to the pointer → overall edge presence
        const ad = Math.hypot(a._px - pointer.x, a._py - pointer.y);
        const aFade = 1 - ad / LINK_RADIUS;
        for (let j = i + 1; j < near.length; j++) {
          const b = near[j];
          const d = Math.hypot(a._px - b._px, a._py - b._py);
          if (d > LINK_DIST) continue;
          const alpha = aFade * (1 - d / LINK_DIST) * 0.5;
          if (alpha < 0.02) continue;
          ctx.globalAlpha = alpha;
          ctx.strokeStyle = "rgba(174,184,255,0.9)";
          ctx.beginPath();
          ctx.moveTo(a._px, a._py);
          ctx.lineTo(b._px, b._py);
          ctx.stroke();
        }
      }
      ctx.globalAlpha = 1;
    }

    ctx.globalCompositeOperation = "source-over";
  }

  // ── Loop ─────────────────────────────────────────────────────────────────────
  let running = false;
  function frame(t) {
    draw(t);
    if (running) requestAnimationFrame(frame);
  }
  function start() {
    if (running || reduceMotion) return;
    running = true;
    requestAnimationFrame(frame);
  }
  function stop() {
    running = false;
  }

  // ── Events ───────────────────────────────────────────────────────────────────
  window.addEventListener("resize", debounce(resize, 150), { passive: true });

  window.addEventListener(
    "pointermove",
    (e) => {
      pointer.x = e.clientX;
      pointer.y = e.clientY;
      pointer.active = true;
    },
    { passive: true }
  );
  window.addEventListener("pointerleave", () => {
    pointer.active = false;
    // let the focus drift gently back to centre
    pointer.x = W / 2;
    pointer.y = H / 2;
  });

  // Pause when the tab is hidden — no reason to burn cycles on an unseen sky.
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) stop();
    else start();
  });

  function debounce(fn, ms) {
    let id;
    return (...a) => {
      clearTimeout(id);
      id = setTimeout(() => fn(...a), ms);
    };
  }

  // ── Go ───────────────────────────────────────────────────────────────────────
  resize();
  start();
})();
