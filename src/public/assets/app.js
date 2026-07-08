function copyText(text){navigator.clipboard.writeText(text).then(()=>showToast('Скопировано'));}
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

// HYPER-HOST v16: animated sidebar groups
(function(){
  document.addEventListener('click', function(e){
    const btn=e.target.closest('.nav-group-toggle');
    if(!btn) return;
    const group=btn.closest('.nav-group');
    if(!group) return;
    group.classList.toggle('open');
  });
})();

// HYPER-HOST v29: live dashboard + PM2 stats without page reload.
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
  const setText = (name, value) => { const el=q(`[data-stat="${name}"]`); if(el) el.textContent = value; };
  const setBar = (name, value) => { const el=q(`[data-stat-bar="${name}"]`); if(el) el.style.width = Math.max(0, Math.min(100, Number(value)||0)) + '%'; };

  async function fetchJson(url){
    const res = await fetch(url + (url.includes('?')?'&':'?') + '_=' + Date.now(), {cache:'no-store', credentials:'same-origin'});
    if(!res.ok) throw new Error('HTTP ' + res.status);
    return await res.json();
  }

  async function updateDashboard(){
    if(!q('[data-live-stats]')) return;
    try{
      const d = await fetchJson('/?api=stats');
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
      setText('pm2Version', d.pm2_version || 'not installed');
      setText('kernel', d.kernel || '');
      if(d.disks){
        Object.entries(d.disks).forEach(([key,val])=>{
          const row=q(`[data-disk-path="${key}"]`);
          if(!row) return;
          const text=q('[data-disk-field="text"]', row);
          const free=q('[data-disk-field="free"]', row);
          const bar=q('[data-disk-field="bar"]', row);
          if(text) text.textContent = `${fmtBytes(val.used)} / ${fmtBytes(val.total)}`;
          if(free) free.textContent = `свободно ${fmtBytes(val.free)}`;
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
    }catch(e){ console.debug('dashboard live update failed', e); }
  }

  async function updateBots(){
    if(!q('[data-live-bots]')) return;
    try{
      const data = await fetchJson('/?api=bots');
      if(!Array.isArray(data)) return;
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
        const memEl = q('[data-bot-memory]', card); if(memEl) memEl.textContent = fmtBytes(mem);
        const cpuEl = q('[data-bot-cpu]', card); if(cpuEl) cpuEl.textContent = cpu.toFixed(1).replace('.0','') + '%';
        const upEl = q('[data-bot-uptime]', card); if(upEl) upEl.textContent = b.uptime || '—';
        const reEl = q('[data-bot-restarts]', card); if(reEl) reEl.textContent = String(b.restarts ?? 0);
        const bar = q('[data-bot-memory-bar]', card); if(bar) bar.style.width = Math.max(2, Math.min(100, mem / 1024 / 1024 / 10)) + '%';
      });
    }catch(e){ console.debug('bot live update failed', e); }
  }

  function startLive(){
    updateDashboard(); updateBots();
    if(q('[data-live-stats]')) setInterval(updateDashboard, 3000);
    if(q('[data-live-bots]')) setInterval(updateBots, 3000);
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', startLive); else startLive();
})();
