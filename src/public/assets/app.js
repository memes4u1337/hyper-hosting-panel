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
    document.querySelectorAll('.flyout-panels .nav-link').forEach(function(link){
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
    if(!q('[data-live-stats]')) return;
    try{
      const d = await fetchJson('/?api=stats', statsRef);
      if(d._error) return;
      const memP = Number(d.mem_percent ?? pct(d.mem_used,d.mem_total));
      const diskP = Number(d.disk_percent ?? pct(d.disk_used,d.disk_total));
      const cpuP = Number(d.cpu_percent || 0);
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

  async function updateBots(){
    if(!q('[data-live-bots]')) return true;
    try{
      const data = await fetchJson('/?api=bots', botsRef);
      if(!Array.isArray(data)) return true;
      const map = new Map(data.map(b => [String(b.name || ''), b]));
      qa('.bot-card-live').forEach(card => {
        const name = card.getAttribute('data-bot-name') || '';
        const b = map.get(name) || {status:'not_found',memory:0,cpu_percent:0,uptime:'—',restarts:0};
        const st = q('[data-bot-status]', card);
        if(st){
          st.textContent = b.status || 'not_found';
          st.classList.toggle('ok', b.status === 'online');
          st.classList.toggle('bad', b.status !== 'online');
        }
        const mem = Number(b.memory || 0);
        const cpu = Number(b.cpu_percent ?? b.cpu ?? 0);
        setNode(q('[data-bot-memory]', card), fmtBytes(mem));
        setNode(q('[data-bot-cpu]', card), cpu.toFixed(1).replace('.0','') + '%');
        setNode(q('[data-bot-uptime]', card), b.uptime || '—');
        setNode(q('[data-bot-restarts]', card), String(b.restarts ?? 0));
        const bar = q('[data-bot-memory-bar]', card); if(bar) bar.style.width = Math.max(2, Math.min(100, mem / 1024 / 1024 / 10)) + '%';
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
    scheduler(updateDashboard, 4000, () => !!q('[data-live-stats]'));
    scheduler(updateBots, 4000, () => !!q('[data-live-bots]'));
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', startLive); else startLive();
})();
