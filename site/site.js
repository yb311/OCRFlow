// The site's only script: scroll-driven reading, loops that play when seen, the
// videos, and the lock. No third parties, nothing stored, nothing sent.
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const seg = (x, a, b) => clamp((x - a) / (b - a));
const $ = (s, root = document) => root.querySelector(s);
const $$ = (s, root = document) => [...root.querySelectorAll(s)];

// Rising into place. ---------------------------------------------------------
const seen = new IntersectionObserver((entries) => {
  for (const e of entries) if (e.isIntersecting) { e.target.classList.add('in'); seen.unobserve(e.target); }
}, { rootMargin: '0px 0px -8% 0px' });
$$('.rise').forEach((el) => seen.observe(el));

// Loops only run while on screen. ----------------------------------------------
const loops = new IntersectionObserver((entries) => {
  for (const e of entries) {
    if (e.isIntersecting) {
      if (!e.target.src && e.target.dataset.src) { e.target.src = e.target.dataset.src; e.target.load(); }
      if (!reduced) e.target.play().catch(() => {});
    } else e.target.pause();
  }
}, { rootMargin: '200px' });
$$('video[data-loop]').forEach((v) => loops.observe(v));

// The videos: one plays at a time, and stops once it is out of sight. ----------
const players = $$('.player');
const start = (player) => {
  const video = $('video', player);
  players.forEach((other) => { if (other !== player) $('video', other).pause(); });
  player.classList.add('playing');
  video.controls = true;
  video.play().catch(() => {});
};
for (const player of players) {
  const video = $('video', player);
  $('.play', player).addEventListener('click', () => start(player));
  video.addEventListener('play', () => { player.classList.add('playing'); video.controls = true; });
  new IntersectionObserver(([e]) => { if (!e.isIntersecting && !video.paused) video.pause(); }, { threshold: 0.1 }).observe(player);
}

// Scroll. ------------------------------------------------------------------------
const nav = $('.nav');
const scan = $('.scan');
const page = scan && $('.page', scan);
const blocks = page ? $$('.sheet-read .blk', page) : [];
const results = scan ? $$('.result', scan) : [];
const steps = scan ? $$('.scan-step', scan) : [];
const marks = scan ? $$('.scan-progress i', scan) : [];
const pinned = () => innerWidth > 1040;

function reading(p) {
  const scanned = seg(p, 0.08, 0.42);
  const stage = $('.scan-stage');
  stage.style.setProperty('--p', scanned);
  page.style.setProperty('--scan', scanned);
  blocks.forEach((b, i) => b.style.setProperty('--b', seg(p, 0.46 + i * 0.022, 0.5 + i * 0.022)));
  results.forEach((r, i) => r.style.setProperty('--k', (1 - (1 - seg(p, 0.62 + i * 0.03, 0.72 + i * 0.03)) ** 3).toFixed(3)));
  const at = p < 0.44 ? 0 : p < 0.61 ? 1 : 2;
  steps.forEach((s, i) => s.classList.toggle('on', i === at));
  marks.forEach((m, i) => m.classList.toggle('on', i <= at));
}

let queued = false;
function frame() {
  queued = false;
  nav.classList.toggle('solid', scrollY > 30);
  if (scan && pinned()) {
    const r = scan.getBoundingClientRect();
    reading(clamp(-r.top / (r.height - innerHeight)));
  }
}
addEventListener('scroll', () => { if (!queued) { queued = true; requestAnimationFrame(frame); } }, { passive: true });
// The results fit beside the page on any window height.
const column = scan && $('.results', scan);
function fit() {
  if (!column) return;
  column.style.setProperty('--fit', pinned() ? Math.min(1, (innerHeight - 90) / column.offsetHeight).toFixed(3) : 1);
}
addEventListener('resize', () => { fit(); frame(); });
fit();
frame();

// Below the width where the page is pinned, it reads itself when reached.
if (scan && !pinned() && !reduced) {
  const go = new IntersectionObserver(([e]) => {
    if (!e.isIntersecting) return;
    go.disconnect();
    const start = performance.now();
    const tick = (now) => {
      const k = seg(now - start, 0, 2600);
      page.style.setProperty('--scan', k);
      blocks.forEach((b, i) => b.style.setProperty('--b', seg(k, 0.55 + i * 0.05, 0.65 + i * 0.05)));
      if (k < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }, { threshold: 0.4 });
  go.observe(page);
} else if (scan && !pinned()) {
  page.style.setProperty('--scan', 1);
}

// A search for a phrase, typed out. ----------------------------------------------
const typed = $('[data-typed]');
if (typed) {
  const phrases = typed.dataset.typed.split('|');
  let phrase = 0; let n = 0; let back = false;
  const show = () => { typed.firstChild.textContent = [...phrases[phrase]].slice(0, n).join(''); };
  typed.prepend(document.createTextNode(''));
  if (reduced) { n = [...phrases[0]].length; show(); } else {
    const tick = () => {
      const length = [...phrases[phrase]].length;
      if (!back && n === length) { back = true; return setTimeout(tick, 1900); }
      if (back && n === 0) { back = false; phrase = (phrase + 1) % phrases.length; return setTimeout(tick, 300); }
      n += back ? -1 : 1;
      show();
      setTimeout(tick, back ? 26 : 80);
    };
    tick();
  }
}

// The lock: thousands of points of light that hold together around the pointer. --
const lock = $('#lock');
if (lock) {
  const g = lock.getContext('2d');
  const size = 720;
  lock.width = size; lock.height = size;
  const shape = document.createElement('canvas');
  shape.width = shape.height = size;
  const s = shape.getContext('2d', { willReadFrequently: true });
  s.fillStyle = s.strokeStyle = '#fff';
  s.lineWidth = 58; s.lineCap = 'round';
  s.beginPath(); s.arc(360, 262, 122, Math.PI, 0); s.moveTo(482, 262); s.lineTo(482, 330); s.moveTo(238, 262); s.lineTo(238, 330); s.stroke();
  s.beginPath(); s.roundRect(150, 318, 420, 330, 66); s.fill();
  s.globalCompositeOperation = 'destination-out';
  s.beginPath(); s.arc(360, 450, 44, 0, 7); s.fill();
  s.fillRect(344, 450, 32, 104);
  const data = s.getImageData(0, 0, size, size).data;
  const inside = [];
  for (let y = 0; y < size; y += 4) for (let x = 0; x < size; x += 4) if (data[(y * size + x) * 4 + 3] > 128) inside.push(x, y);
  const count = inside.length / 2;
  const px = new Float32Array(count); const py = new Float32Array(count);
  const seed = new Float32Array(count);
  for (let i = 0; i < count; i++) {
    seed[i] = Math.random();
    // With reduced motion only one frame is drawn, so the points start in place
    // rather than scattered, waiting for frames that never come.
    px[i] = reduced ? inside[i * 2] : Math.random() * size;
    py[i] = reduced ? inside[i * 2 + 1] : Math.random() * size;
  }
  let mx = -9999; let my = -9999;
  lock.addEventListener('pointermove', (e) => {
    const r = lock.getBoundingClientRect();
    mx = (e.clientX - r.left) / r.width * size; my = (e.clientY - r.top) / r.height * size;
  });
  lock.addEventListener('pointerleave', () => { mx = my = -9999; });
  let visible = false;
  new IntersectionObserver(([e]) => { const was = visible; visible = e.isIntersecting; if (visible && !was) requestAnimationFrame(draw); }).observe(lock);
  function draw(now) {
    if (!visible) return;
    g.clearRect(0, 0, size, size);
    const t = now / 1000;
    for (let i = 0; i < count; i++) {
      let tx = inside[i * 2]; let ty = inside[i * 2 + 1];
      const dx = tx - mx; const dy = ty - my;
      const d2 = dx * dx + dy * dy;
      if (d2 < 11000) { const f = (11000 - d2) / 11000 * 62; const d = Math.sqrt(d2) || 1; tx += dx / d * f; ty += dy / d * f; }
      tx += Math.sin(t * 1.2 + seed[i] * 50) * 1.3;
      ty += Math.cos(t * 1.0 + seed[i] * 70) * 1.3;
      px[i] += (tx - px[i]) * (0.05 + seed[i] * 0.05);
      py[i] += (ty - py[i]) * (0.05 + seed[i] * 0.05);
      const a = 0.42 + seed[i] * 0.58;
      g.fillStyle = seed[i] > 0.72 ? `rgba(228,255,247,${a})` : seed[i] > 0.3 ? `rgba(143,240,216,${a})` : `rgba(21,184,153,${a})`;
      g.fillRect(px[i], py[i], 2.5, 2.5);
    }
    if (reduced) return;
    requestAnimationFrame(draw);
  }
}
