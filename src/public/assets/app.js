function copyText(text){navigator.clipboard.writeText(text).then(()=>showToast('Скопировано'));}
document.addEventListener('click', function(e){
  const btn = e.target.closest('[data-copy]');
  if(!btn) return;
  copyText(btn.getAttribute('data-copy') || '');
});
function copyValue(id){const el=document.getElementById(id); if(el){el.select(); copyText(el.value);}}
function showToast(message){let t=document.createElement('div');t.className='position-fixed bottom-0 end-0 m-4 alert alert-success shadow';t.style.zIndex=9999;t.innerText=message;document.body.appendChild(t);setTimeout(()=>t.remove(),1800)}

// HYPER-HOST v12: keep Bootstrap modals stable even if old browser/table layout glitches happen.
document.addEventListener('click', function(e){
  const trigger = e.target.closest('[data-bs-toggle="modal"][data-bs-target]');
  if(!trigger || !window.bootstrap) return;
  const selector = trigger.getAttribute('data-bs-target');
  const modal = document.querySelector(selector);
  if(!modal) return;
  if(modal.parentElement !== document.body) document.body.appendChild(modal);
}, true);

// HYPER-HOST v50: явный визуальный фидбек на долгих формах (например создание бота),
// чтобы не было ощущения "зависло, не пойму сработало или нет". Кнопка блокируется
// сразу по клику и меняет текст на data-loading-text, плюс показывается подсказка
// рядом с формой (data-async-hint), если она есть.
(function(){
  function init(){
    document.querySelectorAll('form[data-async-submit]').forEach(function(form){
      form.addEventListener('submit', function(){
        const btn = form.querySelector('button[type="submit"], button:not([type])');
        if(btn && !btn.disabled){
          btn.dataset.originalHtml = btn.innerHTML;
          const loadingText = btn.getAttribute('data-loading-text') || 'Выполняется...';
          btn.innerHTML = '<span class="spinner-border spinner-border-sm me-2" role="status" aria-hidden="true"></span>' + loadingText;
          btn.disabled = true;
        }
        const hint = form.parentElement ? form.parentElement.querySelector('[data-async-hint]') : null;
        if(hint) hint.style.display = '';
      });
    });
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();

// HYPER-HOST v45: мобильное меню — бургер открывает/закрывает sidebar как off-canvas drawer.
(function(){
  function init(){
    const toggle = document.getElementById('mobileNavToggle');
    const backdrop = document.getElementById('mobileNavBackdrop');
    const closeButton = document.getElementById('mobileNavClose');
    const shell = document.getElementById('appShell');
    if(!toggle || !shell) return;
    function close(){
      shell.classList.remove('nav-open');
      document.body.classList.remove('nav-open');
      toggle.setAttribute('aria-expanded','false');
    }
    function open(){
      shell.classList.add('nav-open');
      document.body.classList.add('nav-open');
      toggle.setAttribute('aria-expanded','true');
    }
    toggle.addEventListener('click', function(){
      shell.classList.contains('nav-open') ? close() : open();
    });
    if(backdrop) backdrop.addEventListener('click', close);
    if(closeButton) closeButton.addEventListener('click', close);
    document.querySelectorAll('.sidebar .nav-link').forEach(function(link){
      link.addEventListener('click', close);
    });
    window.addEventListener('resize', function(){
      if(window.innerWidth > 1100) close();
    });
    window.addEventListener('keydown', function(e){
      if(e.key === 'Escape') close();
    });
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();

// HYPER-HOST v79: новое компактное боковое меню без вертикальной прокрутки.
(function(){
  function init(){
    const buttons = Array.from(document.querySelectorAll('[data-sidebar-category]'));
    const panels = Array.from(document.querySelectorAll('[data-sidebar-panel]'));
    if(!buttons.length || !panels.length) return;

    function activate(category){
      buttons.forEach(button => {
        const active = button.dataset.sidebarCategory === category;
        button.classList.toggle('active', active);
        button.setAttribute('aria-selected', active ? 'true' : 'false');
      });
      panels.forEach(panel => {
        const active = panel.dataset.sidebarPanel === category;
        panel.classList.toggle('active', active);
        panel.hidden = !active;
      });
    }

    buttons.forEach(button => button.addEventListener('click', () => {
      activate(String(button.dataset.sidebarCategory || 'main'));
    }));
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();

// HYPER-HOST v31: icon-rail sidebar — sliding indicator + animated flyout switch.
(function(){
  function init(){
    const rail = document.querySelector('.rail');
    if(!rail) return;
    const indicator = rail.querySelector('.rail-indicator');
    const buttons = Array.from(rail.querySelectorAll('.rail-btn[data-cat]'));
    const panels = Array.from(document.querySelectorAll('.flyout-panel'));

    function moveIndicator(btn){
      if(!indicator || !btn || !rail) return;
      const railBox = rail.getBoundingClientRect();
      const btnBox = btn.getBoundingClientRect();
      const y = Math.round(btnBox.top - railBox.top + rail.scrollTop);
      indicator.style.transform = `translateY(${y}px)`;
      const accent = getComputedStyle(btn).getPropertyValue('--cat-accent').trim();
      if(accent) indicator.style.setProperty('--cat-color', accent);
    }
    function setActive(cat){
      buttons.forEach(b => b.classList.toggle('active', b.dataset.cat === cat));
      panels.forEach(p => p.classList.toggle('active', p.dataset.panel === cat));
      const activeBtn = buttons.find(b => b.dataset.cat === cat);
      moveIndicator(activeBtn);
    }
    buttons.forEach(b => b.addEventListener('click', () => setActive(b.dataset.cat)));
    window.addEventListener('resize', () => {
      const activeBtn = buttons.find(b => b.classList.contains('active'));
      if(activeBtn) requestAnimationFrame(() => moveIndicator(activeBtn));
    });
    rail.addEventListener('scroll', () => {
      const activeBtn = buttons.find(b => b.classList.contains('active'));
      if(activeBtn) requestAnimationFrame(() => moveIndicator(activeBtn));
    }, {passive:true});
    // initial position (server already marks correct .active button/panel for current page)
    const initial = buttons.find(b => b.classList.contains('active')) || buttons[0];
    if(initial) requestAnimationFrame(() => moveIndicator(initial));
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();


// HYPER-HOST v77: SSL запускается в отдельном системном задании.
// Даже если Nginx понадобится перечитать конфиг, HTTP-запрос панели уже завершён,
// а интерфейс продолжает опрашивать статус и переживает короткий сетевой разрыв.
(function(){
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

  function setBusy(form, busy){
    form.querySelectorAll('input,button').forEach(el => {
      if(el.matches('input[type="hidden"]')) return;
      el.disabled = busy;
    });
    const close = form.closest('.modal')?.querySelector('.btn-close');
    if(close) close.disabled = busy;
  }

  function renderState(form, state, message, details=''){
    const panel = form.querySelector('[data-ssl-job-panel]');
    const title = form.querySelector('[data-ssl-job-title]');
    const text = form.querySelector('[data-ssl-job-message]');
    const icon = form.querySelector('.ssl-job-icon i');
    const error = form.querySelector('[data-ssl-job-error]');
    if(!panel) return;

    panel.hidden = false;
    panel.classList.toggle('success', state === 'success');
    panel.classList.toggle('failed', state === 'failed');

    if(state === 'queued'){
      if(title) title.textContent = 'Задание поставлено в очередь';
      if(icon) icon.className = 'fa-solid fa-clock';
    }else if(state === 'running'){
      if(title) title.textContent = 'Выпускаю и подключаю SSL';
      if(icon) icon.className = 'fa-solid fa-rotate fa-spin';
    }else if(state === 'success'){
      if(title) title.textContent = 'SSL успешно выпущен';
      if(icon) icon.className = 'fa-solid fa-circle-check';
    }else if(state === 'failed'){
      if(title) title.textContent = 'Не удалось выпустить SSL';
      if(icon) icon.className = 'fa-solid fa-triangle-exclamation';
    }else{
      if(title) title.textContent = 'Запускаю выпуск SSL';
      if(icon) icon.className = 'fa-solid fa-rotate fa-spin';
    }
    if(text) text.textContent = message || 'Ожидаю ответ сервера…';
    if(error){
      error.hidden = !details;
      error.textContent = details || '';
    }
  }

  async function fetchJsonRetry(url, attempts=4){
    let lastError = null;
    for(let i=0;i<attempts;i++){
      try{
        const res = await fetch(url + (url.includes('?') ? '&' : '?') + '_=' + Date.now(), {
          cache:'no-store',
          credentials:'same-origin',
          headers:{'Accept':'application/json','X-Requested-With':'fetch'}
        });
        const raw = await res.text();
        let data = {};
        try{ data = raw ? JSON.parse(raw) : {}; }catch(_){ throw new Error(raw || ('HTTP ' + res.status)); }
        if(!res.ok && !data.message && !data.error) throw new Error('HTTP ' + res.status);
        return data;
      }catch(error){
        lastError = error;
        if(i < attempts - 1) await sleep(1100 + i * 650);
      }
    }
    throw lastError || new Error('Нет ответа от сервера');
  }

  async function pollJob(form, jobId){
    let networkFails = 0;
    for(let i=0;i<600;i++){
      await sleep(i === 0 ? 700 : 1400);
      try{
        const data = await fetchJsonRetry('/?api=ssl-job&job=' + encodeURIComponent(jobId), 2);
        networkFails = 0;
        const state = String(data.state || 'running');
        const message = String(data.message || (state === 'queued' ? 'Ожидаю запуска задания…' : 'Проверяю сертификат и конфигурацию Nginx…'));
        const details = String(data.error || data.log_tail || '');
        renderState(form, state, message, details);

        if(state === 'success'){
          sessionStorage.removeItem('hh_ssl_job');
          showToast('SSL выпущен и подключён');
          await sleep(1400);
          window.location.assign('/?page=ssl');
          return;
        }
        if(state === 'failed'){
          sessionStorage.removeItem('hh_ssl_job');
          setBusy(form, false);
          const button = form.querySelector('[data-ssl-button] span');
          if(button) button.textContent = 'Повторить выпуск';
          return;
        }
      }catch(error){
        networkFails++;
        renderState(form, 'running', networkFails < 4
          ? 'Nginx обновляется, переподключаюсь к панели…'
          : 'Панель временно не отвечает, задание SSL продолжает работать.', '');
        if(networkFails > 45){
          renderState(form, 'failed', 'Не удалось получить статус задания.', String(error?.message || error));
          setBusy(form, false);
          return;
        }
      }
    }
    renderState(form, 'failed', 'Превышено время ожидания SSL.', 'Проверь журнал certbot на сервере.');
    setBusy(form, false);
  }

  function normalizeSslEmail(value){
    return String(value || '').replace(/[\u200B-\u200D\uFEFF]/g, '').trim();
  }

  function updateSslCommands(form){
    const domain = String(form.dataset.domain || '').trim();
    const emailInput = form.querySelector('[data-ssl-email]');
    const email = normalizeSslEmail(emailInput?.value || '') || 'email@example.com';
    form.querySelectorAll('[data-ssl-command-template]').forEach(button => {
      const template = String(button.dataset.sslCommandTemplate || '');
      const command = template.replaceAll('{domain}', domain).replaceAll('{email}', email);
      button.dataset.copy = command;
      const code = button.querySelector('code');
      if(code) code.textContent = command;
    });
  }

  async function submitSsl(form){
    const buttonText = form.querySelector('[data-ssl-button] span');
    const email = form.querySelector('[data-ssl-email]');
    if(email) email.value = normalizeSslEmail(email.value);
    if(email && !email.reportValidity()) return;

    // ВАЖНО: FormData создаётся до блокировки полей. Disabled-поля браузер
    // не добавляет в FormData — именно из-за этого корректный email раньше
    // исчезал из POST и сервер отвечал «Укажи нормальный email».
    const payload = new FormData(form);
    if(email) localStorage.setItem('hh_ssl_email', email.value);

    setBusy(form, true);
    if(buttonText) buttonText.textContent = 'Запускаю…';
    renderState(form, 'starting', 'Создаю безопасное фоновое задание…');

    try{
      const res = await fetch('/?page=ssl', {
        method:'POST',
        body:payload,
        credentials:'same-origin',
        cache:'no-store',
        headers:{'Accept':'application/json','X-Requested-With':'fetch'}
      });
      const raw = await res.text();
      let data = {};
      try{ data = raw ? JSON.parse(raw) : {}; }catch(_){ throw new Error(raw || ('HTTP ' + res.status)); }
      if(!res.ok || !data.ok) throw new Error(data.message || data.error || ('HTTP ' + res.status));
      if(!data.job_id) throw new Error('Сервер не вернул ID SSL-задания');

      sessionStorage.setItem('hh_ssl_job', JSON.stringify({
        id:data.job_id,
        domain:data.domain || form.dataset.domain || '',
        started:Date.now()
      }));
      renderState(form, data.state || 'queued', data.message || 'Задание запущено. Можно не закрывать страницу.');
      if(buttonText) buttonText.textContent = 'SSL выпускается';
      await pollJob(form, data.job_id);
    }catch(error){
      renderState(form, 'failed', 'Не удалось запустить SSL-задание.', String(error?.message || error));
      setBusy(form, false);
      if(buttonText) buttonText.textContent = 'Повторить выпуск';
    }
  }

  function init(){
    document.querySelectorAll('form[data-ssl-submit]').forEach(form => {
      form.addEventListener('submit', event => {
        event.preventDefault();
        submitSsl(form);
      });
      const email = form.querySelector('[data-ssl-email]');
      if(email){
        const saved = localStorage.getItem('hh_ssl_email');
        if(!email.value && saved) email.value = normalizeSslEmail(saved);
        email.value = normalizeSslEmail(email.value);
        updateSslCommands(form);
        email.addEventListener('input', () => {
          updateSslCommands(form);
        });
        email.addEventListener('change', () => {
          email.value = normalizeSslEmail(email.value);
          localStorage.setItem('hh_ssl_email', email.value);
          updateSslCommands(form);
        });
      }else{
        updateSslCommands(form);
      }
    });
  }

  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();


(function(){
  const fmtBytes = (bytes) => {
    bytes = Number(bytes || 0);
    const units = ['B','KB','MB','GB','TB'];
    let i = 0;
    while(bytes >= 1024 && i < units.length - 1){ bytes /= 1024; i++; }
    return (Math.round(bytes * 10) / 10) + ' ' + units[i];
  };
  const pct = (used,total) => total > 0 ? Math.max(0, Math.min(100, Math.round((used/total)*100))) : 0;
  const q = (sel,root=document) => root.querySelector(sel);
  const qa = (sel,root=document) => Array.from(root.querySelectorAll(sel));
  const setNode = (el, value) => {
    if(!el || el.textContent === value) return;
    el.textContent = value;
    el.classList.remove('flash');
    void el.offsetWidth; // restart animation
    el.classList.add('flash');
  };
  const setText = (name, value) => setNode(q(`[data-stat="${name}"]`), value);
  const setBar = (name, value) => { const el=q(`[data-stat-bar="${name}"]`); if(el) el.style.width = Math.max(0, Math.min(100, Number(value)||0)) + '%'; };

  async function fetchJson(url, controllerRef){
    if(controllerRef.current) controllerRef.current.abort();
    const controller = new AbortController();
    controllerRef.current = controller;
    const res = await fetch(url + (url.includes('?')?'&':'?') + '_=' + Date.now(), {
      cache:'no-store', credentials:'same-origin', signal: controller.signal
    });
    if(!res.ok) throw new Error('HTTP ' + res.status);
    return await res.json();
  }

  const statsRef = {current:null};
  const botsRef = {current:null};

  async function updateDashboard(){
    // Живой опрос работает на ВСЕХ страницах: даже если дашборда нет,
    // мини-виджет CPU/RAM в меню (data-live-rail) обновляется в реальном времени.
    const hasDash = !!q('[data-live-stats]');
    const hasRail = !!q('[data-live-rail]');
    if(!hasDash && !hasRail) return true;
    try{
      const d = await fetchJson('/?api=stats', statsRef);
      if(d._error) return false;
      const memP = Number(d.mem_percent ?? pct(d.mem_used,d.mem_total));
      const diskP = Number(d.disk_percent ?? pct(d.disk_used,d.disk_total));
      const cpuP = Number(d.cpu_percent || 0);
      // мини-виджет в меню — real-time RAM/CPU везде
      if(hasRail){
        setText('railCpuPercent', Math.round(cpuP) + '%');
        setText('railMemPercent', Math.round(memP) + '%');
        setBar('railCpu', cpuP);
        setBar('railMem', memP);
      }
      if(!hasDash) return true;
      setText('cpuPercent', cpuP.toFixed(1).replace('.0','') + '%');
      setText('cpuModel', d.cpu_model || 'unknown');
      setText('cpuCores', String(d.cpu_cores || 0));
      setText('loadText', `${d.load1 ?? 0} / ${d.load5 ?? 0} / ${d.load15 ?? 0}`);
      setBar('cpu', cpuP);
      setText('memPercent', Math.round(memP) + '%');
      setText('memText', `${fmtBytes(d.mem_used)} / ${fmtBytes(d.mem_total)}`);
      setText('memAvailable', fmtBytes(d.mem_available));
      setText('memCached', fmtBytes(d.mem_cached));
      setBar('mem', memP);
      setText('diskPercent', Math.round(diskP) + '%');
      setText('diskText', `${fmtBytes(d.disk_used)} / ${fmtBytes(d.disk_total)}`);
      setText('diskFree', fmtBytes(d.disk_free));
      setBar('disk', diskP);
      setText('uptime', d.uptime || '—');
      setText('hostname', d.hostname || '—');
      setText('hostnameShort', d.hostname || '—');
      setText('pm2Version', d.pm2_version || 'not installed');
      setText('kernel', d.kernel || '');
      if(d.disks){
        Object.entries(d.disks).forEach(([key,val])=>{
          const row=q(`[data-disk-path="${key}"]`);
          if(!row) return;
          const text=q('[data-disk-field="text"]', row);
          const free=q('[data-disk-field="free"]', row);
          const bar=q('[data-disk-field="bar"]', row);
          setNode(text, `${fmtBytes(val.used)} / ${fmtBytes(val.total)}`);
          setNode(free, `свободно ${fmtBytes(val.free)}`);
          if(bar) bar.style.width = Math.max(0, Math.min(100, Number(val.percent)||0)) + '%';
        });
      }
      if(d.services){
        Object.entries(d.services).forEach(([name,st])=>{
          const chip=q(`[data-service="${name}"]`);
          if(!chip) return;
          chip.classList.toggle('ok', st === 'active');
          chip.classList.toggle('bad', st !== 'active');
          chip.innerHTML = `<i class="fa-solid fa-circle"></i>${name}: ${st}`;
        });
      }
      return true;
    }catch(e){ if(e.name !== 'AbortError') console.debug('dashboard live update failed', e); return false; }
  }

  // v92: панель показывает реальную долю ресурсов сервера, а не абстрактные МБ.
  async function updateBots(){
    const page = q('[data-live-bots]');
    if(!page) return true;
    try{
      const data = await fetchJson('/?api=bots', botsRef);
      const list = Array.isArray(data) ? data : (data && Array.isArray(data.bots) ? data.bots : null);
      if(!list) return false;
      const server = (data && data.server) || {};
      const totals = (data && data.totals) || {};
      const memTotal = Number(server.mem_total || page.dataset.memTotal || 0);
      const cores = Number(server.cpu_cores || page.dataset.cpuCores || 0);
      const botMem = Number(totals.memory != null ? totals.memory : list.reduce((sum,b)=>sum+Number(b.memory||0),0));
      const botCpu = Number(totals.cpu != null ? totals.cpu : list.reduce((sum,b)=>sum+Number(b.cpu||0),0));
      const online = totals.online != null ? Number(totals.online) : list.filter(b=>b.status==='online').length;
      const count = totals.count != null ? Number(totals.count) : list.length;
      const round1 = v => Math.round(Number(v||0) * 10) / 10;

      setNode(q('[data-bots-online]'), online + ' / ' + count);
      if(server.load1 != null) setNode(q('[data-bots-load]'), 'load ' + server.load1);
      setNode(q('[data-bots-mem]'), fmtBytes(botMem));
      setNode(q('[data-bots-mem-pct]'),
        (totals.memory_percent != null ? totals.memory_percent : pct(botMem, memTotal)) + '% от ' + fmtBytes(memTotal));
      setNode(q('[data-bots-cpu]'), round1(botCpu) + '%');
      setNode(q('[data-bots-cpu-pct]'),
        (totals.cpu_of_server != null ? totals.cpu_of_server : (cores ? round1(botCpu/cores) : 0)) + '% от ' + cores + ' ядер');
      if(totals.disk_bytes != null) setNode(q('[data-bots-disk]'), fmtBytes(totals.disk_bytes));

      const map = new Map(list.map(b => [String(b.name || ''), b]));
      qa('.bot-card-live').forEach(card => {
        const name = card.getAttribute('data-bot-name') || '';
        const b = map.get(name) || {status:'not_found', memory:0, cpu_percent:0, uptime:'—', restarts:0};
        const isOnline = b.status === 'online';
        const crash = !!b.crash_loop;

        card.classList.toggle('is-down', !isOnline);
        card.classList.toggle('is-warn', isOnline && crash);

        const state = q('[data-bot-status]', card);
        if(state){
          state.textContent = b.status || 'not_found';
          state.classList.toggle('ok', isOnline);
          state.classList.toggle('bad', !isOnline);
        }

        const mem = Number(b.memory || 0);
        const cpu = Number(b.cpu_percent != null ? b.cpu_percent : (b.cpu || 0));
        const memPct = b.memory_percent != null ? Number(b.memory_percent) : pct(mem, memTotal);
        const cpuServer = b.cpu_of_server != null ? Number(b.cpu_of_server) : (cores ? round1(cpu/cores) : 0);
        const memShare = botMem > 0 ? round1(mem / botMem * 100) : 0;

        setNode(q('[data-bot-mem]', card), fmtBytes(mem));
        setNode(q('[data-bot-mem-pct]', card), memPct + '% сервера');
        setNode(q('[data-bot-mem-share]', card), 'доля среди ботов ' + memShare + '%');
        setNode(q('[data-bot-cpu]', card), round1(cpu) + '% ядра');
        setNode(q('[data-bot-cpu-pct]', card), cpuServer + '% сервера');
        setNode(q('[data-bot-cputime]', card), 'CPU time ' + (b.cpu_seconds != null ? b.cpu_seconds : 0) + 'с');
        setNode(q('[data-bot-uptime]', card), b.uptime || '—');
        setNode(q('[data-bot-threads]', card), b.threads ? String(b.threads) : '—');
        setNode(q('[data-bot-pid]', card), b.pid ? String(b.pid) : '—');
        if(b.disk_bytes != null) setNode(q('[data-bot-disk]', card), fmtBytes(b.disk_bytes));

        const restarts = Number(b.restarts || 0);
        const restartsNode = q('[data-bot-restarts]', card);
        if(restartsNode){
          setNode(restartsNode, String(restarts));
          restartsNode.classList.toggle('bad', restarts > 50);
          restartsNode.classList.toggle('warn', restarts > 5 && restarts <= 50);
        }

        const memBar = q('[data-bot-mem-bar]', card);
        if(memBar) memBar.style.width = Math.max(0, Math.min(100, memShare)) + '%';
        const cpuBar = q('[data-bot-cpu-bar]', card);
        if(cpuBar) cpuBar.style.width = Math.max(0, Math.min(100, cpu)) + '%';
        const cpuRow = cpuBar ? cpuBar.closest('.bot-load-row-v92') : null;
        if(cpuRow) cpuRow.classList.toggle('hot', cpu >= 70);

        const alert = q('[data-bot-alert]', card);
        const alertText = q('[data-bot-alert-text]', card);
        if(alert){
          let message = '';
          if(crash) message = 'Бот в цикле перезапусков: ' + restarts + ' рестартов и нулевой uptime. Смотри Logs — процесс падает сразу после старта.';
          else if(!isOnline && b.status !== 'not_found') message = 'Процесс не запущен. Нажми Start или проверь логи.';
          else if(!isOnline) message = 'PM2 не видит этот процесс. Нажми Start, чтобы поднять его заново.';
          alert.hidden = !message;
          if(alertText && message) alertText.textContent = message;
        }

        const filesNode = q('[data-bot-files]', card);
        if(filesNode && Array.isArray(b.files)){
          const next = b.files.length
            ? b.files.map(f => '<span>' + String(f).replace(/[<>&]/g, '') + '</span>').join('')
            : '<em>файлы не прочитаны</em>';
          if(filesNode.innerHTML !== next) filesNode.innerHTML = next;
        }
      });
      return true;
    }catch(e){ if(e.name !== 'AbortError') console.debug('bot live update failed', e); return false; }
  }

  // Планировщик с паузой на скрытой вкладке и мягким backoff при ошибках.
  // Это снимает лишнюю нагрузку с sudo hyper-host-ctl (он запускается как отдельный
  // процесс на каждый опрос) — если панель открыта в фоновой вкладке, поллинг стоит.
  function scheduler(fn, baseDelay, hasTarget){
    if(!hasTarget()) return;
    let timer = null;
    let failCount = 0;
    const tick = async () => {
      if(document.hidden){ arm(baseDelay); return; }
      const ok = await fn();
      failCount = ok ? 0 : Math.min(failCount + 1, 5);
      arm(baseDelay * Math.pow(1.6, failCount));
    };
    const arm = (delay) => { if(timer) clearTimeout(timer); timer = setTimeout(tick, delay); };
    document.addEventListener('visibilitychange', function(){
      if(!document.hidden){ if(timer) clearTimeout(timer); tick(); }
    });
    tick();
  }

  function initFtpScopeSelect(){
    const scope = q('#ftpScopeSelect');
    const site = q('#ftpSiteSelect');
    if(!scope || !site) return;
    const sync = () => {
      const oneSite = scope.value === 'site';
      site.style.display = oneSite ? '' : 'none';
      site.disabled = !oneSite;
      if(!oneSite) site.value = '';
    };
    scope.addEventListener('change', sync);
    sync();
  }

  function startLive(){
    initFtpScopeSelect();
    scheduler(updateDashboard, 2500, () => !!q('[data-live-stats]') || !!q('[data-live-rail]'));
    scheduler(updateBots, 3000, () => !!q('[data-live-bots]'));
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', startLive); else startLive();
})();


/* ============================================================
   HYPER-HOST v92 — честная проверка домена перед выпуском SSL
   powered by memes4u1337
   ============================================================ */
(function(){
  const esc = value => String(value == null ? '' : value)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');

  function line(state, title, detail){
    const icon = state === 'ok' ? 'fa-circle-check' : (state === 'warn' ? 'fa-triangle-exclamation' : 'fa-circle-xmark');
    return '<div class="ssl-check-line-v92 ' + state + '"><i class="fa-solid ' + icon + '"></i>'
      + '<div><b>' + esc(title) + '</b>' + (detail ? '<span>' + esc(detail) + '</span>' : '') + '</div></div>';
  }

  function render(box, data){
    if(!data || data.ok === false){
      box.innerHTML = line('bad', 'Проверка не выполнена', (data && (data.problem || data._error)) || 'Сервер не ответил');
      return;
    }
    const rows = [];
    const dnsState = String(data.dns_state || '');
    const aList = (data.a || []).join(', ') || 'нет A-записей';
    const aaaaList = (data.aaaa || []).join(', ');

    if(dnsState === 'ok'){
      rows.push(line('ok', 'DNS указывает на этот сервер', aList));
    }else if(dnsState === 'extra_a'){
      rows.push(line('warn', 'Несколько A-записей', aList + ' — нужен только ' + (data.expected_ip || '')));
    }else if(dnsState === 'aaaa'){
      rows.push(line('bad', 'Есть AAAA-запись, а IPv6 у сервера нет', aaaaList));
    }else if(dnsState === 'wrong_ip'){
      rows.push(line('bad', 'A-запись смотрит не сюда', aList + ' вместо ' + (data.expected_ip || '')));
    }else{
      rows.push(line('bad', 'A-записи нет', 'Добавь A ' + (data.host || '') + ' → ' + (data.expected_ip || '')));
    }

    rows.push(data.site
      ? line(data.attached ? 'ok' : 'warn',
             data.attached ? 'Привязан к сайту ' + data.site : 'Будет привязан к сайту ' + data.site,
             data.root || '')
      : line('bad', 'Сайта для этого домена нет', 'Создай сайт с базовым доменом на вкладке «Сайты»'));

    rows.push(data.acme_ok
      ? line('ok', 'ACME challenge отдаётся', '/.well-known/acme-challenge доступен локально')
      : line('warn', 'ACME challenge пока не отдаётся', 'Панель пересоберёт vhost при выпуске'));

    rows.push(data.cert_ok
      ? line('ok', 'Живой сертификат уже есть', data.cert_path || '')
      : line('warn', 'Сертификата пока нет', 'Нажми «Выпустить SSL»'));

    let html = rows.join('');
    if(data.problem){
      html += '<div class="ssl-fix-hint-v92"><b>' + esc(data.problem) + '</b>'
        + (data.fix ? '<br>' + esc(data.fix) : '') + '</div>';
    }else if(data.can_issue){
      html += '<div class="ssl-fix-hint-v92">Всё готово. Жми «Выпустить SSL» — сертификат закроет домен и его www одним разом.</div>';
    }
    box.innerHTML = html;
  }

  function init(){
    document.querySelectorAll('[data-ssl-check]').forEach(button => {
      const form = button.closest('form');
      if(!form) return;
      const box = form.parentElement ? form.parentElement.querySelector('[data-ssl-report]') : null;
      button.addEventListener('click', async () => {
        const input = form.querySelector('[data-ssl-host]');
        const host = String(input && input.value || '').trim().toLowerCase().replace(/\.$/, '');
        if(!host){ if(input) input.reportValidity(); return; }
        if(!box) return;
        button.disabled = true;
        const original = button.innerHTML;
        button.innerHTML = '<i class="fa-solid fa-rotate fa-spin me-2"></i>Проверяю…';
        box.innerHTML = '<div class="placeholder">Спрашиваю публичные DNS-резолверы и проверяю Nginx…</div>';
        try{
          const res = await fetch('/?api=ssl-host&host=' + encodeURIComponent(host) + '&_=' + Date.now(), {
            cache:'no-store', credentials:'same-origin', headers:{'Accept':'application/json'}
          });
          const raw = await res.text();
          let data = {};
          try{ data = raw ? JSON.parse(raw) : {}; }catch(_){ data = {ok:false, problem: raw || ('HTTP ' + res.status)}; }
          render(box, data);
        }catch(error){
          render(box, {ok:false, problem:String(error && error.message || error)});
        }finally{
          button.disabled = false;
          button.innerHTML = original;
        }
      });
    });
  }

  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
