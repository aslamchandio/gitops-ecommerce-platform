/* Nova Store · UI interactions
   - Theme toggle (persists in localStorage)
   - Mobile nav burger toggle
   - Client-side product search (filters cards by title/category)
   - "/" focuses the search input
*/
(() => {
  const root = document.documentElement;

  // ---------- Theme toggle ----------
  const themeBtn = document.getElementById('theme-toggle');
  if (themeBtn) {
    themeBtn.addEventListener('click', () => {
      const next = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      try { localStorage.setItem('nova-theme', next); } catch (e) { /* private mode */ }
    });
  }

  // ---------- Mobile nav burger ----------
  const burger = document.getElementById('nav-burger');
  const topnav = document.querySelector('.topnav');
  if (burger && topnav) {
    burger.addEventListener('click', () => topnav.classList.toggle('nav-open'));
    // Close menu when clicking a link
    topnav.querySelectorAll('.nav-links a').forEach(a =>
      a.addEventListener('click', () => topnav.classList.remove('nav-open')));
  }

  // ---------- Product search (client-side, debounced) ----------
  const search = document.getElementById('product-search');
  const cards = document.querySelectorAll('.card[data-title]');
  const noResults = document.getElementById('no-results');
  const resultCount = document.querySelector('.result-count');

  if (search && cards.length) {
    const filter = () => {
      const q = search.value.trim().toLowerCase();
      let visible = 0;
      cards.forEach(card => {
        const title = (card.dataset.title || '').toLowerCase();
        const cat = (card.dataset.category || '').toLowerCase();
        const match = !q || title.includes(q) || cat.includes(q);
        card.style.display = match ? '' : 'none';
        if (match) visible++;
      });
      if (noResults) noResults.classList.toggle('hidden', visible > 0);
      if (resultCount) resultCount.textContent = visible;
    };
    let timer;
    search.addEventListener('input', () => {
      clearTimeout(timer);
      timer = setTimeout(filter, 80);
    });

    // "/" shortcut focuses search (when not already in another input)
    document.addEventListener('keydown', (e) => {
      if (e.key === '/' && !/^(input|select|textarea)$/i.test(document.activeElement.tagName)) {
        e.preventDefault();
        search.focus();
      }
    });
  }
})();
