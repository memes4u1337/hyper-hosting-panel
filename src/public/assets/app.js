document.addEventListener('click', async (event) => {
  const btn = event.target.closest('[data-copy]');
  if (!btn) return;
  try {
    await navigator.clipboard.writeText(btn.dataset.copy);
    const old = btn.textContent;
    btn.textContent = 'скопировано';
    setTimeout(() => btn.textContent = old, 1200);
  } catch (e) {
    alert('Не удалось скопировать');
  }
});
