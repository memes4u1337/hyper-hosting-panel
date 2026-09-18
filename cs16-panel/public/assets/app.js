(() => {
  const cfg = window.CS16 || {};
  const sid = cfg.serverId;
  const $ = (s, root=document) => root.querySelector(s);
  const $$ = (s, root=document) => [...root.querySelectorAll(s)];
  const esc = (s='') => String(s).replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
  const api = async (view, data=null, method='GET') => {
    let url = `/api.php?view=${encodeURIComponent(view)}` + (sid ? `&server_id=${sid}` : '');
    const opt = {method, credentials:'same-origin'};
    if (data) {
      const body = new URLSearchParams({...data, _csrf: cfg.csrf});
      opt.body = body;
      opt.headers = {'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'};
    }
    const r = await fetch(url, opt);
    const j = await r.json().catch(()=>({ok:false,error:`HTTP ${r.status}`}));
    if (!r.ok || j.ok === false) throw new Error(j.error || `HTTP ${r.status}`);
    return j;
  };
  const toast = (message, bad=false) => {
    const el = document.createElement('div'); el.className=`floating-toast ${bad?'bad':''}`; el.textContent=message;
    document.body.appendChild(el); setTimeout(()=>el.classList.add('show'),20); setTimeout(()=>{el.classList.remove('show');setTimeout(()=>el.remove(),250)},2600);
  };
  const dur = (sec=0) => { sec=Math.max(0,Number(sec)||0); const h=Math.floor(sec/3600),m=Math.floor((sec%3600)/60); return h?`${h}ч ${m}м`:`${m}м`; };
  const mb = n => Number(n)>=1024 ? `${(Number(n)/1024).toFixed(1)} ГБ` : `${Math.round(Number(n)||0)} МБ`;

  $$('[data-copy]').forEach(b=>b.addEventListener('click', async()=>{
    const el=$(b.dataset.copy); if(!el)return; try{await navigator.clipboard.writeText(el.textContent.trim());toast('Скопировано');}catch{toast('Не удалось скопировать',true)}
  }));

  if (!sid) return;

  let chart;
  async function loadStatus(){
    try{
      const j=await api('status'); const q=j.query||{};
      if($('#livePlayers')) $('#livePlayers').textContent=`${q.players ?? (j.players||[]).length} / ${q.max_players ?? j.slots}`;
      if($('#liveMap')) $('#liveMap').textContent=q.map || j.start_map || '—';
      if($('#liveCpu')) $('#liveCpu').textContent=`${Number(j.cpu_percent||0).toFixed(1)}%`;
      if($('#liveRam')) $('#liveRam').textContent=mb(j.memory_mb||0);
      if($('#liveDisk')) $('#liveDisk').textContent=mb(j.disk_mb||0);
      if($('#livePing')) $('#livePing').textContent=`${Number((q.ping_ms ?? 0)).toFixed(1)} ms`;
      if($('#liveUptime')) $('#liveUptime').textContent=dur(j.uptime_seconds||0);
    }catch(e){ /* keep cached values */ }
  }
  loadStatus(); setInterval(loadStatus, 10000);

  async function loadPlayers(){
    const body=$('#playersBody'); if(!body)return;
    body.innerHTML='<tr><td colspan="8">Загрузка...</td></tr>';
    try{
      const j=await api('players'); const rows=j.players||[];
      if(!rows.length){body.innerHTML='<tr><td colspan="8" class="text-secondary">На сервере никого нет</td></tr>';return;}
      body.innerHTML=rows.map((p,i)=>`<tr><td>${esc(p.slot ?? p.index ?? i+1)}</td><td><b>${esc(p.name||'Player')}</b></td><td><code>${esc(p.steam_id||'—')}</code></td><td><code>${esc(p.address||'—')}</code></td><td>${esc(p.score??0)}</td><td>${esc(p.ping??'—')}</td><td>${esc(p.time||dur(p.duration||0))}</td><td class="text-end">${p.userid!==undefined?`<button class="btn btn-sm btn-soft player-kick" data-userid="${Number(p.userid)}">Kick</button> <button class="btn btn-sm btn-danger-soft player-ban" data-userid="${Number(p.userid)}">Ban 30m</button>`:'<span class="text-secondary">userid недоступен</span>'}</td></tr>`).join('');
      $$('.player-kick',body).forEach(b=>b.onclick=async()=>{if(!confirm('Кикнуть игрока?'))return;try{await api('kick',{userid:b.dataset.userid},'POST');toast('Игрок отключён');loadPlayers()}catch(e){toast(e.message,true)}});
      $$('.player-ban',body).forEach(b=>b.onclick=async()=>{if(!confirm('Забанить игрока на 30 минут?'))return;try{await api('ban',{userid:b.dataset.userid,minutes:30},'POST');toast('Игрок забанен');loadPlayers()}catch(e){toast(e.message,true)}});
    }catch(e){body.innerHTML=`<tr><td colspan="8" class="text-danger">${esc(e.message)}</td></tr>`;}
  }
  async function loadPlayerHistory(){
    const body=$('#historyPlayersBody'); if(!body)return;
    try{const j=await api('player-history');const rows=j.rows||[];body.innerHTML=rows.map(r=>`<tr><td><b>${esc(r.name||'Player')}</b></td><td><code>${esc(r.steam_id||'—')}</code></td><td>${esc(r.first_seen||'—')}</td><td>${esc(r.last_seen||'—')}</td><td>${esc(r.visits??1)}</td></tr>`).join('')||'<tr><td colspan="5" class="text-secondary">История пока пуста</td></tr>';}catch(e){body.innerHTML=`<tr><td colspan="5" class="text-danger">${esc(e.message)}</td></tr>`;}
  }
  $('#refreshPlayers')?.addEventListener('click',loadPlayers);

  $('#networkCheck')?.addEventListener('click', async()=>{
    const out=$('#networkCheckResult'); if(out){out.className='network-check-result';out.textContent='Проверяю...';}
    try{
      const j=await api('network');
      const good=!!(j.service==='active' && j.udp_listening && j.a2s_local);
      if(out){out.className='network-check-result '+(good?'ok':'bad');out.textContent=good?`HLDS работает: UDP ${j.port} слушается, A2S отвечает. Для LAN: ${j.lan_address}.`:`Ошибка: service=${j.service}, UDP=${j.udp_listening?'OK':'NO'}, A2S=${j.a2s_local?'OK':'NO'} ${j.query_error||''}`;}
    }catch(e){if(out){out.className='network-check-result bad';out.textContent=e.message;}}
  });

  async function runConsole(command){
    const out=$('#consoleOut'); if(!out)return;
    out.textContent += `\n> ${command}\n`; out.scrollTop=out.scrollHeight;
    try{const j=await api('rcon',{command},'POST');out.textContent += (j.output||'[OK]')+'\n';}
    catch(e){out.textContent += `[ERROR] ${e.message}\n`;}
    out.scrollTop=out.scrollHeight;
  }
  $('#consoleForm')?.addEventListener('submit',e=>{e.preventDefault();const i=$('#consoleCommand');const c=i.value.trim();if(c){runConsole(c);i.value='';}});
  $$('[data-command]').forEach(b=>b.onclick=()=>runConsole(b.dataset.command));

  async function loadMaps(){
    const g=$('#mapGrid'); if(!g)return; g.innerHTML='<span>Загрузка...</span>';
    try{const j=await api('maps');const maps=j.maps||[];g.innerHTML=maps.map(m=>`<button class="map-card" data-map="${esc(m)}"><i class="fa-solid fa-map"></i><b>${esc(m)}</b><span>Сменить карту</span></button>`).join('')||'<span class="text-secondary">Карты не найдены</span>';$$('[data-map]',g).forEach(b=>b.onclick=async()=>{if(!confirm(`Переключить сервер на ${b.dataset.map}?`))return;try{await api('change-map',{map:b.dataset.map},'POST');toast('Команда смены карты отправлена');}catch(e){toast(e.message,true)}})}catch(e){g.innerHTML=`<span class="text-danger">${esc(e.message)}</span>`}
  }

  async function loadPlugins(){
    const box=$('#pluginList');if(!box)return;box.textContent='Загрузка...';
    try{const j=await api('plugins');const files=j.files||[], enabled=new Set(j.enabled||[]);box.innerHTML=files.map(p=>`<div class="plugin-row"><div><i class="fa-solid fa-puzzle-piece"></i><b>${esc(p)}</b><small>${enabled.has(p)?'Включён':'Выключен'}</small></div><label class="switch"><input type="checkbox" data-plugin="${esc(p)}" ${enabled.has(p)?'checked':''}><span></span></label></div>`).join('')||'<div class="text-secondary">.amxx файлы не найдены</div>';$$('[data-plugin]',box).forEach(ch=>ch.onchange=async()=>{try{await api('plugin-toggle',{plugin:ch.dataset.plugin,state:ch.checked?'on':'off'},'POST');toast(ch.checked?'Плагин включён':'Плагин выключен')}catch(e){ch.checked=!ch.checked;toast(e.message,true)}})}catch(e){box.innerHTML=`<span class="text-danger">${esc(e.message)}</span>`}
  }

  async function loadConfig(){const sel=$('#configSelect'),ed=$('#configEditor');if(!sel||!ed)return;ed.value='Загрузка...';try{const j=await fetch(`/api.php?view=config&server_id=${sid}&name=${encodeURIComponent(sel.value)}`,{credentials:'same-origin'}).then(r=>r.json());if(j.ok===false)throw new Error(j.error);ed.value=j.content||'';}catch(e){ed.value=`// ERROR: ${e.message}`}}
  $('#configSelect')?.addEventListener('change',loadConfig);
  $('#saveConfig')?.addEventListener('click',async()=>{const sel=$('#configSelect'),ed=$('#configEditor');try{await api('config-save',{name:sel.value,content:ed.value},'POST');toast('Файл сохранён')}catch(e){toast(e.message,true)}});

  async function loadLogs(){const out=$('#logOut');if(!out)return;out.textContent='Загрузка...';try{const j=await api('logs');out.textContent=j.output||'Лог пуст';out.scrollTop=out.scrollHeight}catch(e){out.textContent=e.message}}
  $('#refreshLogs')?.addEventListener('click',loadLogs);

  async function loadChart(){const canvas=$('#statsChart');if(!canvas||!window.Chart)return;try{const j=await api('history');const rows=j.rows||[];const labels=rows.map(r=>String(r.recorded_at).slice(11,16));if(chart)chart.destroy();chart=new Chart(canvas,{type:'line',data:{labels,datasets:[{label:'Игроки',data:rows.map(r=>Number(r.players)),tension:.28,yAxisID:'y'},{label:'CPU %',data:rows.map(r=>Number(r.cpu_percent)),tension:.28,yAxisID:'y1'}]},options:{responsive:true,interaction:{mode:'index',intersect:false},plugins:{legend:{labels:{color:'#9aa9bd'}}},scales:{x:{ticks:{color:'#718096',maxTicksLimit:12},grid:{color:'rgba(130,150,180,.08)'}},y:{beginAtZero:true,ticks:{color:'#718096'},grid:{color:'rgba(130,150,180,.08)'}},y1:{beginAtZero:true,position:'right',ticks:{color:'#718096'},grid:{drawOnChartArea:false}}}}});}catch(e){console.warn(e)}}

  function onTab(target){if(target==='#players'){loadPlayers();loadPlayerHistory();}if(target==='#maps')loadMaps();if(target==='#plugins')loadPlugins();if(target==='#configs')loadConfig();if(target==='#logs')loadLogs();if(target==='#overview')loadChart();}
  $$('#serverTabs button').forEach(b=>b.addEventListener('shown.bs.tab',()=>onTab(b.dataset.bsTarget)));
  loadChart();
  if(location.hash){const btn=$(`#serverTabs button[data-bs-target="${location.hash}"]`);if(btn){bootstrap.Tab.getOrCreateInstance(btn).show();}}
})();
