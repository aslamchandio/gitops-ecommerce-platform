// IntersectionObserver fades cards in as they scroll into view.
// Cards already have a staggered animation-delay from server-rendered inline style;
// this just ensures the animation only runs once scrolled past.
(() => {
  const cards = document.querySelectorAll('.card');
  if (!('IntersectionObserver' in window) || !cards.length) return;

  const io = new IntersectionObserver((entries) => {
    entries.forEach(e => {
      if (e.isIntersecting) {
        e.target.style.animationPlayState = 'running';
        io.unobserve(e.target);
      }
    });
  }, { threshold: 0.05 });

  cards.forEach(c => {
    c.style.animationPlayState = 'paused';
    io.observe(c);
  });

  // 3D tilt on hover (subtle)
  cards.forEach(card => {
    card.addEventListener('mousemove', (ev) => {
      const r = card.getBoundingClientRect();
      const x = (ev.clientX - r.left) / r.width - 0.5;
      const y = (ev.clientY - r.top) / r.height - 0.5;
      card.style.transform = `translateY(-6px) rotateX(${-y * 4}deg) rotateY(${x * 4}deg)`;
    });
    card.addEventListener('mouseleave', () => {
      card.style.transform = '';
    });
  });
})();
