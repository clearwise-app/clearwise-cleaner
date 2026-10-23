// Features block: the sidebar switches panes, like the app itself.
document.querySelectorAll('[data-tabs]').forEach((root) => {
  const tabs = [...root.querySelectorAll('[role="tab"]')];
  const select = (tab) => {
    tabs.forEach((t) => {
      const on = t === tab;
      t.setAttribute('aria-selected', on);
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute('aria-controls')).hidden = !on;
    });
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => select(tab));
    tab.addEventListener('keydown', (e) => {
      const step = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[e.key];
      if (!step) return;
      e.preventDefault();
      const next = tabs[(i + step + tabs.length) % tabs.length];
      select(next);
      next.focus();
    });
  });
});

// Copy buttons on code blocks.
document.querySelectorAll('.copy').forEach((btn) => {
  btn.addEventListener('click', async () => {
    const text = btn.dataset.copy;
    const done = btn.dataset.done || 'OK';
    const label = btn.textContent;
    try {
      await navigator.clipboard.writeText(text);
      btn.textContent = done;
    } catch {
      const range = document.createRange();
      range.selectNodeContents(btn.parentElement.querySelector('code'));
      const sel = getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    }
    setTimeout(() => { btn.textContent = label; }, 1600);
  });
});
