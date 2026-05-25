/* Nova Store · UI interactions
   - Theme toggle (persists in localStorage)
   - Sidebar drawer (mobile)
   - Client-side product search (filters cards by title/category)
   - Keyboard "/" to focus search
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

  // ---------- Sidebar drawer (mobile) ----------
  const sidebar = document.getElementById('sidebar');
  const scrim = document.querySelector('.sidebar-scrim');
  const openSidebar = () => {
    if (!sidebar) return;
    sidebar.classList.add('is-open');
    if (scrim) scrim.classList.add('is-open');
    document.body.style.overflow = 'hidden';
  };
  const closeSidebar = () => {
    if (!sidebar) return;
    sidebar.classList.remove('is-open');
    if (scrim) scrim.classList.remove('is-open');
    document.body.style.overflow = '';
  };
  document.querySelectorAll('[data-sidebar-open]').forEach(el =>
    el.addEventListener('click', openSidebar));
  document.querySelectorAll('[data-sidebar-close]').forEach(el =>
    el.addEventListener('click', closeSidebar));
  // Close drawer when navigating
  document.querySelectorAll('.sidebar .side-link').forEach(el =>
    el.addEventListener('click', () => {
      if (window.innerWidth <= 768) closeSidebar();
    }));
  // Escape closes drawer
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') closeSidebar();
  });

  // ---------- Product search (client-side) ----------
  const search = document.getElementById('product-search');
  const cards = document.querySelectorAll('.card[data-title]');
  const noResults = document.getElementById('no-results');
  const resultCount = document.querySelector('.result-count strong');

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
    // Debounce so we don't thrash on every keystroke
    let timer;
    search.addEventListener('input', () => {
      clearTimeout(timer);
      timer = setTimeout(filter, 80);
    });

    // "/" focuses search (skip when typing in another input)
    document.addEventListener('keydown', (e) => {
      if (e.key === '/' && !/^(input|select|textarea)$/i.test(document.activeElement.tagName)) {
        e.preventDefault();
        search.focus();
      }
    });
  }
})();
