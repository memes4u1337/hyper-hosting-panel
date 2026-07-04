document.addEventListener('click', async (event) => {
  const copyBtn = event.target.closest('[data-copy]');
  if (copyBtn) {
    try {
      await navigator.clipboard.writeText(copyBtn.dataset.copy || '');
      const old = copyBtn.textContent;
      copyBtn.textContent = 'скопировано';
      setTimeout(() => copyBtn.textContent = old, 1200);
    } catch (e) {
      alert('Не удалось скопировать');
    }
    return;
  }

  const genBtn = event.target.closest('[data-generate-password]');
  if (genBtn) {
    const form = genBtn.closest('form');
    const input = form ? form.querySelector('input[name="password"]') : null;
    if (!input) return;
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%_-';
    const bytes = new Uint32Array(18);
    crypto.getRandomValues(bytes);
    input.value = Array.from(bytes, (x) => alphabet[x % alphabet.length]).join('');
  }
});
