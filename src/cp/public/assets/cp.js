/* HYPER-HOST CP — интерфейс клиентского портала. powered by memes4u1337 */
(function () {
  'use strict';

  // ---------------------------------------------------- мобильное меню
  var burger = document.getElementById('cpBurger');
  var backdrop = document.getElementById('cpBackdrop');
  function closeNav() { document.body.classList.remove('cp-nav-open'); }
  if (burger) {
    burger.addEventListener('click', function () {
      document.body.classList.toggle('cp-nav-open');
    });
  }
  if (backdrop) backdrop.addEventListener('click', closeNav);
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') closeNav();
  });

  // ---------------------------------------------------- вкладки "свой домен / поддомен"
  document.querySelectorAll('[data-tabs]').forEach(function (tabs) {
    var form = tabs.closest('form');
    if (!form) return;
    var modeInput = form.querySelector('[data-mode]');
    tabs.querySelectorAll('button[data-tab]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var tab = btn.getAttribute('data-tab');
        tabs.querySelectorAll('button').forEach(function (b) { b.classList.toggle('is-active', b === btn); });
        if (modeInput) modeInput.value = tab;
        form.querySelectorAll('[data-pane]').forEach(function (pane) {
          var active = pane.getAttribute('data-pane') === tab;
          pane.hidden = !active;
          // Скрытое поле не должно оставаться обязательным, иначе форма не отправится.
          pane.querySelectorAll('input').forEach(function (i) { i.disabled = !active; });
        });
      });
    });
    // Стартовое состояние: активна первая вкладка.
    var first = tabs.querySelector('button.is-active') || tabs.querySelector('button');
    if (first) first.click();
  });

  // ---------------------------------------------------- копирование реквизитов
  function toast(text) {
    var t = document.createElement('div');
    t.textContent = text;
    t.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);z-index:999;' +
      'padding:12px 22px;border-radius:12px;background:#121a2e;color:#eaf0ff;font:600 13.5px sans-serif;' +
      'border:1px solid rgba(150,170,220,.2);box-shadow:0 12px 40px rgba(0,0,0,.5)';
    document.body.appendChild(t);
    setTimeout(function () { t.remove(); }, 1600);
  }

  document.addEventListener('click', function (e) {
    var el = e.target.closest('[data-copy]');
    if (!el) return;
    var value = el.getAttribute('data-copy') || el.textContent.trim();
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(value).then(function () { toast('Скопировано'); });
    } else {
      var ta = document.createElement('textarea');
      ta.value = value;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); toast('Скопировано'); } catch (err) {}
      ta.remove();
    }
  });

  // ---------------------------------------------------- фидбек на долгих операциях
  // Выпуск SSL и установка зависимостей идут десятки секунд — без этого
  // клиент жмёт кнопку повторно и создаёт параллельные задания.
  document.querySelectorAll('form').forEach(function (form) {
    form.addEventListener('submit', function () {
      var btn = form.querySelector('button[type="submit"], button:not([type])');
      if (!btn || btn.disabled) return;
      var action = (form.querySelector('[name="action"]') || {}).value || '';
      var slow = ['issue_ssl', 'bot_install', 'create_site', 'create_bot'];
      btn.dataset.original = btn.innerHTML;
      btn.innerHTML = slow.indexOf(action) >= 0 ? 'Выполняется…' : '…';
      btn.disabled = true;
      // Если браузер вернёт страницу из кэша (кнопка "назад") — вернём кнопку.
      setTimeout(function () {
        if (btn.dataset.original) { btn.innerHTML = btn.dataset.original; btn.disabled = false; }
      }, 120000);
    });
  });

  window.addEventListener('pageshow', function (e) {
    if (!e.persisted) return;
    document.querySelectorAll('button[data-original]').forEach(function (btn) {
      btn.innerHTML = btn.dataset.original;
      btn.disabled = false;
    });
  });
})();

/* v95 bot deploy UX */
document.addEventListener('DOMContentLoaded', function () {
  document.querySelectorAll('[data-file-input]').forEach(function (input) {
    input.addEventListener('change', function () {
      var card = input.closest('.cp-upload-card');
      if (!card) return;
      card.classList.toggle('has-file', !!(input.files && input.files[0]));
      var label = card.querySelector('[data-file-label]');
      if (label && input.files && input.files[0]) label.textContent = input.files[0].name;
    });
  });
  var runtime = document.querySelector('[data-runtime]');
  if (runtime) {
    function syncRuntimeHints() {
      var node = runtime.value === 'node';
      var main = document.querySelector('[data-main-hint]');
      var deps = document.querySelector('[data-deps-hint]');
      var botInput = document.querySelector('input[name="bot_file"]');
      if (main) main.textContent = node ? 'index.js' : 'bot.py';
      if (deps) deps.textContent = node ? 'package.json' : 'requirements.txt';
      if (botInput) botInput.setAttribute('accept', node ? '.js' : '.py');
    }
    runtime.addEventListener('change', syncRuntimeHints);
    syncRuntimeHints();
  }
});
