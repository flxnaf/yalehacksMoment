// ── Nav scroll state ────────────────────────────────────
const nav = document.getElementById('nav');
window.addEventListener('scroll', () => {
  nav.classList.toggle('scrolled', window.scrollY > 20);
}, { passive: true });

// ── Fade-up on scroll ───────────────────────────────────
const observer = new IntersectionObserver((entries) => {
  entries.forEach(el => {
    if (el.isIntersecting) {
      el.target.classList.add('visible');
      observer.unobserve(el.target);
    }
  });
}, { threshold: 0.1, rootMargin: '0px 0px -40px 0px' });

// Add fade-up to key elements after DOM load
document.querySelectorAll(
  '.pipeline-step, .feature-card, .arch-node, .hardware-card, .tech-category, .arch-layer'
).forEach((el, i) => {
  el.classList.add('fade-up');
  el.style.transitionDelay = `${(i % 4) * 0.08}s`;
  observer.observe(el);
});

// ── Smooth anchor scrolling with offset ─────────────────
document.querySelectorAll('a[href^="#"]').forEach(link => {
  link.addEventListener('click', e => {
    const target = document.querySelector(link.getAttribute('href'));
    if (!target) return;
    e.preventDefault();
    const top = target.getBoundingClientRect().top + window.scrollY - 80;
    window.scrollTo({ top, behavior: 'smooth' });
  });
});

// ── Depth bar animation reset on visibility ──────────────
const depthBars = document.querySelectorAll('.depth-bar');
const depthObserver = new IntersectionObserver(entries => {
  entries.forEach(entry => {
    depthBars.forEach(bar => {
      bar.style.animationPlayState = entry.isIntersecting ? 'running' : 'paused';
    });
  });
}, { threshold: 0.5 });
const depthViz = document.querySelector('.depth-viz');
if (depthViz) depthObserver.observe(depthViz);

// ── Ping ring animation on visibility ───────────────────
const pingRings = document.querySelectorAll('.ping-ring');
const pingObserver = new IntersectionObserver(entries => {
  entries.forEach(entry => {
    pingRings.forEach(ring => {
      ring.style.animationPlayState = entry.isIntersecting ? 'running' : 'paused';
    });
  });
}, { threshold: 0.1 });
const hudPing = document.querySelector('.hud-ping');
if (hudPing) pingObserver.observe(hudPing);

// ── Stagger arch nodes on layer visible ─────────────────
document.querySelectorAll('.arch-layer').forEach(layer => {
  const layerObs = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      const nodes = layer.querySelectorAll('.arch-node');
      nodes.forEach((node, i) => {
        setTimeout(() => node.classList.add('visible'), i * 80);
      });
      layerObs.unobserve(layer);
    });
  }, { threshold: 0.2 });
  layerObs.observe(layer);
});

// ── Tech pill hover: cycle accent color ─────────────────
const colors = ['#3b82f6', '#8b5cf6', '#22c55e', '#f97316', '#ec4899'];
document.querySelectorAll('.tech-pill').forEach(pill => {
  const color = colors[Math.floor(Math.random() * colors.length)];
  pill.addEventListener('mouseenter', () => {
    pill.style.borderColor = color + '66';
    pill.style.color = color;
  });
  pill.addEventListener('mouseleave', () => {
    pill.style.borderColor = '';
    pill.style.color = '';
  });
});
