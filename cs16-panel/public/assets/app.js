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
  let currentMap = String(cfg.currentMap || '');
  const setHealthPill=(id,state,text)=>{const el=$(id);if(!el)return;el.classList.remove('ok','warn','bad');el.classList.add(state);el.innerHTML=`<i></i>${text}`;};
  async function loadStatus(){
    try{
      const j=await api('status'); const q=j.query||{};
      if($('#livePlayers')) $('#livePlayers').textContent=`${q.players ?? (j.players||[]).length} / ${q.max_players ?? j.slots}`;
      currentMap = q.map || currentMap || j.start_map || '';
      if($('#liveMap')) $('#liveMap').textContent=currentMap || '—';
      if($('#currentMapLabel')) $('#currentMapLabel').textContent=currentMap || '—';
      ['#mapSelector','#settingsMapSelector','#quickMapSelector'].forEach(sel=>{const el=$(sel);if(el&&currentMap&&[...el.options].some(o=>o.value===currentMap))el.value=currentMap;});
      if($('#liveCpu')) $('#liveCpu').textContent=`${Number(j.cpu_percent||0).toFixed(1)}%`;
      if($('#liveRam')) $('#liveRam').textContent=mb(j.memory_mb||0);
      if($('#liveDisk')) $('#liveDisk').textContent=mb(j.disk_mb||0);
      if($('#livePing') && q.ping_ms!=null) $('#livePing').textContent=`${Number(q.ping_ms).toFixed(1)} ms`;
      if($('#livePing') && q.ping_ms==null && j.udp_listening) $('#livePing').textContent='ожидание';
      if($('#liveUptime')) $('#liveUptime').textContent=dur(j.uptime_seconds||0);
      setHealthPill('#healthService',j.running?'ok':'bad',`Процесс ${j.running?'ON':'OFF'}`);
      setHealthPill('#healthUdp',j.udp_listening?'ok':'bad',`UDP ${j.udp_listening?'ON':'OFF'}`);
      setHealthPill('#healthQuery',j.query_state==='ok'?'ok':(j.udp_listening?'warn':'bad'),`A2S ${j.query_state==='ok'?'OK':(j.udp_listening?'RETRY':'OFF')}`);
      const badge=$('#liveStatusBadge');
      if(badge){
        let state='FAILED', cls='danger';
        if(j.running&&j.udp_listening){state='ONLINE';cls='success'}
        else if(j.running){state='STARTING';cls='warning'}
        else if(['inactive','deactivating'].includes(String(j.service||''))){state='OFFLINE';cls='secondary'}
        badge.innerHTML=`<span class="badge text-bg-${cls} status-badge">${state}</span>`;
      }
    }catch(e){ /* keep cached values */ }
  }
  loadStatus(); setInterval(loadStatus, 10000);

  const ADMIN_FLAGS = [
    ['a','Иммунитет','Админ не кикается/не банится другими плагинами'],['b','Резерв','Резервный слот'],['c','Kick','Отключение игроков'],['d','Ban','Блокировка игроков'],
    ['e','Slay/Slap','Убить / ударить игрока'],['f','Карта','Смена карты'],['g','CVAR','Изменение серверных cvar'],['h','Конфиги','Запуск cfg'],
    ['i','Чат','Админ-чат'],['j','Голосования','Запуск голосований'],['k','sv_password','Управление паролем сервера'],['l','RCON','Полный RCON-доступ'],
    ['m','Custom A','Пользовательский уровень A'],['n','Custom B','Пользовательский уровень B'],['o','Custom C','Пользовательский уровень C'],['p','Custom D','Пользовательский уровень D'],
    ['q','Custom E','Пользовательский уровень E'],['r','Custom F','Пользовательский уровень F'],['s','Custom G','Пользовательский уровень G'],['t','Custom H','Пользовательский уровень H'],['u','AMXX меню','Доступ к меню администратора']
  ];
  const ADMIN_PRESETS = {
    full:'abcdefghijklmnopqrstu',
    admin:'bcdefghiju',
    moderator:'bcdeiu',
    maps:'bfiju'
  };
  let adminRows=[];
  const isSteamId = v => /^(STEAM|VALVE)_\d+:\d+:\d+$/i.test(String(v||''));
  const adminByIdentity = id => adminRows.find(a=>String(a.identity||'').toLowerCase()===String(id||'').toLowerCase());

  function renderAdminFlags(){
    const root=$('#adminFlags'); if(!root)return;
    root.innerHTML=ADMIN_FLAGS.map(([flag,label,desc])=>`<label class="admin-flag" title="${esc(desc)}"><input type="checkbox" value="${flag}"><span><b>${flag}</b><em>${esc(label)}</em><small>${esc(desc)}</small></span></label>`).join('');
  }
  function setAdminFlags(flags=''){
    const wanted=new Set(String(flags));
    $$('#adminFlags input[type=checkbox]').forEach(x=>x.checked=wanted.has(x.value));
  }
  function getAdminFlags(){return $$('#adminFlags input[type=checkbox]:checked').map(x=>x.value).join('');}
  function applyAdminPreset(name){if(ADMIN_PRESETS[name])setAdminFlags(ADMIN_PRESETS[name]);}

  const adminModalEl=$('#adminModal');
  const adminModal = adminModalEl && window.bootstrap ? new bootstrap.Modal(adminModalEl) : null;
  function openAdminModal(opts={}){
    if(!adminModal)return;
    const row=opts.row||null;
    $('#adminIndex').value=row?Number(row.index):-1;
    $('#adminIdentity').value=opts.identity ?? row?.identity ?? '';
    const inferred=opts.authType || row?.auth_type || (isSteamId(opts.identity)?'steamid':'name');
    $('#adminAuthType').value=inferred;
    $('#adminPassword').value='';
    $('#adminPassword').placeholder=row?.has_password?'Оставь пустым, чтобы сохранить текущий':'Пусто = без пароля для SteamID/IP';
    $('#adminGeneratePassword').checked=!row && inferred==='steamid';
    const flags=row?.access_flags || ADMIN_PRESETS.admin;
    $('#adminPreset').value=row?'custom':'admin'; setAdminFlags(flags);
    const r=$('#adminSaveResult');r.classList.add('d-none');r.innerHTML='';
    adminModal.show();
  }

  async function loadAdmins(){
    const body=$('#adminsBody');
    try{
      const j=await api('admins'); adminRows=j.admins||[];
      if(body){
        body.innerHTML=adminRows.map(a=>`<tr><td><code>${esc(a.identity)}</code></td><td><span class="admin-auth">${esc(a.auth_type==='steamid'?'SteamID':a.auth_type==='ip'?'IP':'Ник')}</span></td><td><div class="admin-rights">${String(a.access_flags||'').split('').map(f=>`<span title="${esc((a.access_labels||[])[String(a.access_flags).indexOf(f)]||f)}">${esc(f)}</span>`).join('')}</div></td><td>${a.has_password?'<span class="password-set"><i class="fa-solid fa-lock"></i> задан</span>':'<span class="text-secondary">без пароля</span>'}</td><td class="text-end"><button type="button" class="btn btn-sm btn-soft admin-edit" data-index="${Number(a.index)}"><i class="fa-solid fa-pen"></i></button> <button type="button" class="btn btn-sm btn-danger-soft admin-delete" data-index="${Number(a.index)}"><i class="fa-solid fa-trash"></i></button></td></tr>`).join('')||'<tr><td colspan="5" class="text-secondary">Администраторов пока нет</td></tr>';
        $$('.admin-edit',body).forEach(b=>b.onclick=()=>{const row=adminRows.find(a=>Number(a.index)===Number(b.dataset.index));if(row)openAdminModal({row})});
        $$('.admin-delete',body).forEach(b=>b.onclick=async()=>{const row=adminRows.find(a=>Number(a.index)===Number(b.dataset.index));if(!row||!confirm(`Удалить администратора ${row.identity}?`))return;try{await api('admin-delete',{index:b.dataset.index},'POST');toast('Администратор удалён');await loadAdmins();await loadPlayers();}catch(e){toast(e.message,true)}});
      }
      return adminRows;
    }catch(e){if(body)body.innerHTML=`<tr><td colspan="5" class="text-danger">${esc(e.message)}</td></tr>`;return adminRows;}
  }

  async function loadPlayers(){
    const body=$('#playersBody'); if(!body)return;
    body.innerHTML='<tr><td colspan="9">Загрузка...</td></tr>';
    try{
      const [j]=await Promise.all([api('players'),loadAdmins()]); const rows=j.players||[];
      if(!rows.length){body.innerHTML='<tr><td colspan="9" class="text-secondary">На сервере никого нет</td></tr>';return;}
      body.innerHTML=rows.map((p,i)=>{
        const ident=isSteamId(p.steam_id)?p.steam_id:(p.name||''); const adm=adminByIdentity(ident);
        const rights=adm?`<span class="admin-online"><i class="fa-solid fa-shield-halved"></i> ${esc(adm.access_flags)}</span>`:'<span class="text-secondary">игрок</span>';
        const adminBtn=adm?`<button class="btn btn-sm btn-soft player-admin-edit" data-admin-index="${Number(adm.index)}" title="Изменить права"><i class="fa-solid fa-user-shield"></i></button>`:`<button class="btn btn-sm btn-primary player-admin-add" data-identity="${esc(ident)}" data-name="${esc(p.name||'')}" data-auth="${isSteamId(p.steam_id)?'steamid':'name'}" title="Сделать админом"><i class="fa-solid fa-user-plus"></i></button>`;
        return `<tr><td>${esc(p.slot ?? p.index ?? i+1)}</td><td><b>${esc(p.name||'Player')}</b></td><td><code>${esc(p.steam_id||'—')}</code></td><td><code>${esc(p.address||'—')}</code></td><td>${esc(p.score??0)}</td><td>${esc(p.ping??'—')}</td><td>${esc(p.time||dur(p.duration||0))}</td><td>${rights}</td><td class="text-end">${adminBtn} ${p.userid!==undefined?`<button class="btn btn-sm btn-soft player-kick" data-userid="${Number(p.userid)}">Kick</button> <button class="btn btn-sm btn-danger-soft player-ban" data-userid="${Number(p.userid)}">Ban 30m</button>`:'<span class="text-secondary">userid нет</span>'}</td></tr>`;
      }).join('');
      $$('.player-admin-add',body).forEach(b=>b.onclick=()=>openAdminModal({identity:b.dataset.identity,authType:b.dataset.auth}));
      $$('.player-admin-edit',body).forEach(b=>b.onclick=()=>{const row=adminRows.find(a=>Number(a.index)===Number(b.dataset.adminIndex));if(row)openAdminModal({row})});
      $$('.player-kick',body).forEach(b=>b.onclick=async()=>{if(!confirm('Кикнуть игрока?'))return;try{await api('kick',{userid:b.dataset.userid},'POST');toast('Игрок отключён');loadPlayers()}catch(e){toast(e.message,true)}});
      $$('.player-ban',body).forEach(b=>b.onclick=async()=>{if(!confirm('Забанить игрока на 30 минут?'))return;try{await api('ban',{userid:b.dataset.userid,minutes:30},'POST');toast('Игрок забанен');loadPlayers()}catch(e){toast(e.message,true)}});
    }catch(e){body.innerHTML=`<tr><td colspan="9" class="text-danger">${esc(e.message)}</td></tr>`;}
  }
  async function loadPlayerHistory(){
    const body=$('#historyPlayersBody'); if(!body)return;
    try{
      const j=await api('player-history');const rows=j.rows||[];
      body.innerHTML=rows.map(r=>{const can=isSteamId(r.steam_id);const adm=can?adminByIdentity(r.steam_id):null;return `<tr><td><b>${esc(r.name||'Player')}</b></td><td><code>${esc(r.steam_id||'—')}</code></td><td>${esc(r.first_seen||'—')}</td><td>${esc(r.last_seen||'—')}</td><td>${esc(r.visits??1)}</td><td class="text-end">${adm?`<button type="button" class="btn btn-sm btn-soft history-admin-edit" data-index="${Number(adm.index)}"><i class="fa-solid fa-user-shield me-1"></i>Права</button>`:can?`<button type="button" class="btn btn-sm btn-primary history-admin-add" data-steam="${esc(r.steam_id)}"><i class="fa-solid fa-user-plus me-1"></i>Админ</button>`:'<span class="text-secondary">SteamID нет</span>'}</td></tr>`}).join('')||'<tr><td colspan="6" class="text-secondary">История пока пуста</td></tr>';
      $$('.history-admin-add',body).forEach(b=>b.onclick=()=>openAdminModal({identity:b.dataset.steam,authType:'steamid'}));
      $$('.history-admin-edit',body).forEach(b=>b.onclick=()=>{const row=adminRows.find(a=>Number(a.index)===Number(b.dataset.index));if(row)openAdminModal({row})});
    }catch(e){body.innerHTML=`<tr><td colspan="6" class="text-danger">${esc(e.message)}</td></tr>`;}
  }
  renderAdminFlags(); applyAdminPreset('admin');
  $('#adminPreset')?.addEventListener('change',e=>{if(e.target.value!=='custom')applyAdminPreset(e.target.value)});
  $('#adminFlags')?.addEventListener('change',()=>{$('#adminPreset').value='custom'});
  $('#addAdminManual')?.addEventListener('click',()=>openAdminModal());
  $('#refreshAdmins')?.addEventListener('click',async()=>{await loadAdmins();await loadPlayerHistory();});
  $('#refreshPlayers')?.addEventListener('click',async()=>{await loadPlayers();await loadPlayerHistory();});
  $('#saveAdmin')?.addEventListener('click',async()=>{
    const identity=$('#adminIdentity').value.trim(), auth_type=$('#adminAuthType').value, access_flags=getAdminFlags();
    if(!identity){toast('Укажи SteamID / ник / IP',true);return} if(!access_flags){toast('Выбери права администратора',true);return}
    const btn=$('#saveAdmin');btn.disabled=true;
    try{
      const j=await api('admin-save',{index:$('#adminIndex').value,identity,auth_type,access_flags,password:$('#adminPassword').value,generate_password:$('#adminGeneratePassword').checked?'1':'0'},'POST');
      const result=$('#adminSaveResult');
      if(j.client_command){result.classList.remove('d-none');result.innerHTML=`<b>Администратор сохранён.</b><div class="admin-command"><span>Команда игроку:</span><code>${esc(j.client_command)}</code><button type="button" class="btn btn-sm btn-soft" id="copyAdminCommand"><i class="fa-regular fa-copy"></i></button></div>${j.generated_password?`<div class="mt-2">Пароль: <code>${esc(j.generated_password)}</code></div>`:''}<small>Игрок вводит команду один раз в своей CS-консоли перед подключением.</small>`;$('#copyAdminCommand')?.addEventListener('click',()=>navigator.clipboard?.writeText(j.client_command).then(()=>toast('Команда скопирована')).catch(()=>{}));
      }else{toast('Администратор сохранён');adminModal.hide();}
      await loadAdmins();await loadPlayers();await loadPlayerHistory();
    }catch(e){toast(e.message,true)}finally{btn.disabled=false}
  });
  $('#networkCheck')?.addEventListener('click', async()=>{
    const out=$('#networkCheckResult'); if(out){out.className='network-check-result';out.textContent='Проверяю...';}
    try{
      const j=await api('network');
      const good=!!(j.service==='active' && j.udp_listening);
      if(out){out.className='network-check-result '+(good?'ok':'bad');out.textContent=good?(j.a2s_local?`HLDS работает: UDP ${j.port} слушается, A2S отвечает. LAN: ${j.lan_address}.`:`HLDS работает: UDP ${j.port} слушается. A2S временно не ответил — панель повторит запрос автоматически.`):`Ошибка: service=${j.service}, UDP=${j.udp_listening?'OK':'NO'} ${j.query_error||''}`;}
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

  const mapGroup = m => {
    const x=String(m).toLowerCase();
    if(x.startsWith('de_'))return 'DE — Bomb/Defuse'; if(x.startsWith('cs_'))return 'CS — Hostage';
    if(x.startsWith('zm_'))return 'ZM — Zombie'; if(x.startsWith('fy_'))return 'FY — Fight Yard';
    if(x.startsWith('awp_'))return 'AWP'; if(x.startsWith('aim_'))return 'AIM'; if(x.startsWith('ka_'))return 'KA — Knife'; if(x.startsWith('surf_'))return 'SURF';
    return 'Другие карты';
  };
  function fillMapSelector(maps){
    const sel=$('#mapSelector'); if(!sel)return;
    const groups=new Map(); maps.forEach(m=>{const g=mapGroup(m);if(!groups.has(g))groups.set(g,[]);groups.get(g).push(m)});
    sel.innerHTML=[...groups].map(([g,items])=>`<optgroup label="${esc(g)}">${items.map(m=>`<option value="${esc(m)}" ${m===currentMap?'selected':''}>${esc(m)}</option>`).join('')}</optgroup>`).join('');
  }
  let mapBusy=false;
  async function changeMap(map,ask=false){
    map=String(map||'').trim(); if(!map||map===currentMap||mapBusy)return;
    if(ask&&!confirm(`Переключить сервер на ${map}?`))return;
    mapBusy=true;
    const previous=currentMap; const selectors=[$('#mapSelector'),$('#settingsMapSelector'),$('#quickMapSelector')].filter(Boolean); selectors.forEach(s=>s.disabled=true);
    const state=$('#mapChangeState');if(state){state.className='busy';state.textContent=`Запускаю ${map}...`;}
    toast(`Запускаю карту ${map}...`);
    try{
      const r=await api('change-map',{map},'POST');currentMap=r.current_map||map;
      if($('#liveMap'))$('#liveMap').textContent=currentMap;if($('#currentMapLabel'))$('#currentMapLabel').textContent=currentMap;
      selectors.forEach(s=>{if([...s.options].some(o=>o.value===currentMap))s.value=currentMap;});
      if(state){state.className='ok';state.textContent=`${currentMap} запущена`;setTimeout(()=>{state.textContent='';state.className='';},3000);}
      toast(`Карта уже запущена: ${currentMap}${r.mode==='restart_fallback'?' (через перезапуск)':''}`);setTimeout(loadStatus,700);
    }catch(e){selectors.forEach(s=>{if(previous&&[...s.options].some(o=>o.value===previous))s.value=previous;});if(state){state.className='bad';state.textContent=e.message;}toast(e.message,true)}
    finally{mapBusy=false;selectors.forEach(s=>s.disabled=false);}
  }
  async function loadMaps(){
    const g=$('#mapGrid'); if(!g)return; g.innerHTML='<span>Загрузка...</span>';
    try{
      const j=await api('maps'); const maps=(j.maps||[]).slice().sort((a,b)=>a.localeCompare(b)); fillMapSelector(maps);
      const render=()=>{const q=String($('#mapFilter')?.value||'').trim().toLowerCase();const list=q?maps.filter(m=>m.toLowerCase().includes(q)):maps;g.innerHTML=list.map(m=>`<button class="map-card ${m===currentMap?'active-map':''}" data-map="${esc(m)}"><i class="fa-solid fa-map"></i><b>${esc(m)}</b><span>${m===currentMap?'Сейчас запущена':'Сменить карту'}</span></button>`).join('')||'<span class="text-secondary">Карты не найдены</span>';$$('[data-map]',g).forEach(b=>b.onclick=()=>changeMap(b.dataset.map,false));};
      render(); if($('#mapFilter'))$('#mapFilter').oninput=render;
      if($('#mapSelector'))$('#mapSelector').onchange=()=>changeMap($('#mapSelector').value,false);
      if($('#changeMapSelected'))$('#changeMapSelected').onclick=()=>changeMap($('#mapSelector')?.value,false);
    }catch(e){g.innerHTML=`<span class="text-danger">${esc(e.message)}</span>`}
  }

  $('#settingsMapSelector')?.addEventListener('change',e=>changeMap(e.currentTarget.value,false));
  $('#quickMapApply')?.addEventListener('click',()=>changeMap($('#quickMapSelector')?.value,false));
  $('#quickMapSelector')?.addEventListener('change',()=>{const state=$('#mapChangeState');if(state){state.className='';state.textContent='Нажми «Запустить»';}});

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

  function onTab(target){if(target==='#players'){loadPlayers().then(loadPlayerHistory);}if(target==='#maps')loadMaps();if(target==='#plugins')loadPlugins();if(target==='#configs')loadConfig();if(target==='#logs')loadLogs();if(target==='#overview')loadChart();}
  $$('#serverTabs button').forEach(b=>b.addEventListener('shown.bs.tab',()=>onTab(b.dataset.bsTarget)));
  loadChart();
  if(location.hash){const btn=$(`#serverTabs button[data-bs-target="${location.hash}"]`);if(btn){bootstrap.Tab.getOrCreateInstance(btn).show();}}
})();
