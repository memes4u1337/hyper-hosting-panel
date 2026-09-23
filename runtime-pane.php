<div class="tab-pane fade" id="runtime">
  <?php
    $rtTargets=is_array($runtime['targets']??null)?$runtime['targets']:[];
    $rtInstalled=is_array($runtime['installed']??null)?$runtime['installed']:[];
    $rtHealth=is_array($runtime['health']??null)?$runtime['health']:[];
    $rtBackups=is_array($runtime['backups']??null)?$runtime['backups']:[];
  ?>
  <section class="panel-card mb-3">
    <div class="panel-head"><div>
      <h2><i class="fa-solid fa-microchip me-2"></i>Runtime / обновления движка</h2>
      <p>Обновляет системный слой сервера без замены твоей игровой сборки. Перед каждой операцией создаётся полный backup; после обновления проверяются systemd, UDP, Metamod и AMXX. При регрессии выполняется автоматический rollback.</p>
    </div><span class="status-badge <?=!empty($runtime['legacy_4419'])?'bg-danger':'bg-success'?>"><?=!empty($runtime['legacy_4419'])?'LEGACY BUILD 4419':'RUNTIME CONTROL'?></span></div>

    <?php if(!empty($runtime['legacy_4419'])):?><div class="alert alert-danger"><b>Обнаружен старый HLDS BUILD 4419.</b> Рекомендуемая миграция заменит только engine/runtime на SteamCMD steam_legacy + ReHLDS. <b>cstrike, Zombie Plague, AMXX plugins, configs, модели, звуки, карты и SQL не удаляются.</b></div><?php endif;?>

    <div class="d-flex flex-wrap gap-2">
      <form method="post" onsubmit="return confirm('Перевести сервер на современный SteamCMD + ReHLDS runtime? Перед изменениями будет создан полный backup и при ошибке всё автоматически вернётся назад.')"><?=csrf_field()?><input type="hidden" name="action" value="runtime_update"><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="component" value="recommended"><button class="btn btn-primary"><i class="fa-solid fa-wand-magic-sparkles me-2"></i>Обновить рекомендуемый Runtime</button></form>
      <form method="post" onsubmit="return confirm('Обновить весь уже установленный runtime, включая ReUnion/YaPB и текущую ветку AMXX? Конфиги и плагины сохраняются; есть автоматический rollback.')"><?=csrf_field()?><input type="hidden" name="action" value="runtime_update"><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="component" value="all"><button class="btn btn-soft"><i class="fa-solid fa-arrows-rotate me-2"></i>Обновить всё установленное</button></form>
    </div>
  </section>

  <div class="detail-grid">
    <section class="panel-card">
      <div class="panel-head"><div><h2>HLDS / SteamCMD base</h2><p>Официальная база <code>steam_legacy</code>. Обновляются только файлы движка в корне сервера; каталог <code>cstrike</code> не заменяется.</p></div><span class="status-badge bg-info">ENGINE BASE</span></div>
      <div class="readonly-settings mb-3"><div><small>Источник</small><b>SteamCMD App 90</b></div><div><small>Ветка</small><b>steam_legacy</b></div></div>
      <form method="post" onsubmit="return confirm('Обновить официальную HLDS-базу? Если сервер уже ReHLDS, Runtime Manager затем повторно наложит ReHLDS/ReGameDLL. Полный backup создаётся заранее.')"><?=csrf_field()?><input type="hidden" name="action" value="runtime_update"><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="component" value="hlds"><button class="btn btn-soft">Обновить HLDS base</button></form>
    </section>

    <?php
      $cards=[
        ['rehlds','ReHLDS','Движок GoldSrc','rehlds'],
        ['regamedll','ReGameDLL_CS','Игровая DLL Counter-Strike','regamedll'],
        ['metamod','Metamod-R','Загрузчик серверных модулей','metamod'],
        ['reapi','ReAPI','API для ReHLDS/ReGameDLL AMXX-плагинов','reapi'],
      ];
      foreach($cards as [$key,$name,$desc,$component]):
        $cur=(string)($rtInstalled[$key]??'');$target=(string)($rtTargets[$key]??'');
    ?>
    <section class="panel-card">
      <div class="panel-head"><div><h2><?=e($name)?></h2><p><?=e($desc)?></p></div><span class="status-badge <?=$cur!==''?'bg-success':'bg-secondary'?>"><?=$cur!==''?'УСТАНОВЛЕН':'НЕ ОПРЕДЕЛЁН'?></span></div>
      <div class="readonly-settings mb-3"><div><small>Текущий</small><b><?=e($cur!==''?$cur:'не определён')?></b></div><div><small>Цель</small><b><?=e($target)?></b></div></div>
      <?php if($key==='reapi'&&!empty($runtime['needs_reapi'])):?><div class="callout mb-3"><i class="fa-solid fa-link"></i><div><b>ReAPI нужен этой сборке</b><p>Активные плагины/модули используют ReAPI.</p></div></div><?php endif;?>
      <form method="post" onsubmit="return confirm('Обновить <?=e($name)?>? Перед изменением будет полный backup и проверка запуска.')"><?=csrf_field()?><input type="hidden" name="action" value="runtime_update"><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="component" value="<?=e($component)?>"><button class="btn btn-soft">Обновить <?=e($name)?></button></form>
    </section>
    <?php endforeach; ?>

    <section class="panel-card">
      <div class="panel-head"><div><h2>AMX Mod X</h2><p>Плагины, configs, users.ini, data/lang и кастомные скрипты не удаляются.</p></div><span class="status-badge <?=!empty($rtInstalled['amxx'])?'bg-success':'bg-secondary'?>"><?=e((string)($rtInstalled['amxx']??'НЕ ОПРЕДЕЛЁН'))?></span></div>
      <div class="readonly-settings mb-3"><div><small>Совместимый вариант</small><b><?=e((string)($rtTargets['amxx19']??''))?></b></div><div><small>Новая ветка</small><b><?=e((string)($rtTargets['amxx110']??''))?></b></div></div>
      <div class="d-flex flex-wrap gap-2">
        <form method="post" onsubmit="return confirm('Обновить только AMXX runtime до 1.9, сохранив плагины и конфиги?')"><?=csrf_field()?><input type="hidden" name="action" value="runtime_update"><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="component" value="amxx19"><button class="btn btn-soft">AMXX 1.9 — совместимость</button></form>
        <form method="post" onsubmit="return confirm('Перейти на AMXX 1.10? Старые плагины могут оказаться несовместимы. Если количество running-плагинов уменьшится или сервер не запустится, Runtime Manager автоматически откатит полный backup.')"><?=csrf_field()?><input type="hidden" name="action" value="runtime_update"><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="component" value="amxx110"><button class="btn btn-primary">AMXX 1.10</button></form>
      </div>
    </section>

    <section class="panel-card">
      <div class="panel-head"><div><h2>ReUnion</h2><p>Steam/Non-Steam протокол для ReHLDS. Текущий активный reunion.cfg сохраняется.</p></div><span class="status-badge <?=!empty($rtInstalled['reunion'])?'bg-success':'bg-secondary'?>"><?=!empty($rtInstalled['reunion'])?e((string)$rtInstalled['reunion']):'НЕ УСТАНОВЛЕН'?></span></div>
      <div class="mb-3"><small class="text-secondary">Стабильная цель: <?=e((string)($rtTargets['reunion']??''))?></small></div>
      <form method="post" onsubmit="return confirm('Установить/обновить ReUnion? Если сервер ещё legacy, сначала безопасно установится ReHLDS.')"><?=csrf_field()?><input type="hidden" name="action" value="runtime_update"><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="component" value="reunion"><button class="btn btn-soft">Установить / обновить ReUnion</button></form>
    </section>

    <section class="panel-card">
      <div class="panel-head"><div><h2>YaPB</h2><p>Обновляется бинарная часть ботов, твой каталог <code>addons/yapb/conf</code> сохраняется.</p></div><span class="status-badge <?=!empty($rtInstalled['yapb'])?'bg-success':'bg-secondary'?>"><?=!empty($rtInstalled['yapb'])?'УСТАНОВЛЕН':'НЕ УСТАНОВЛЕН'?></span></div>
      <form method="post" onsubmit="return confirm('Обновить YaPB, сохранив текущие конфиги ботов?')"><?=csrf_field()?><input type="hidden" name="action" value="runtime_update"><input type="hidden" name="id" value="<?=$id?>"><input type="hidden" name="component" value="yapb"><button class="btn btn-soft">Обновить YaPB</button></form>
    </section>

    <section class="panel-card zm-mod-card">
      <div class="panel-head"><div><h2>Твоя игровая сборка</h2><p>Zombie Plague, VIP/Admin, оружия, ножи и остальные кастомные AMXX.</p></div><span class="status-badge bg-success">СОХРАНЯЕТСЯ 1:1</span></div>
      <div class="callout"><i class="fa-solid fa-shield-halved"></i><div><b>Runtime Manager не заменяет игровой мод</b><p><code>cstrike/models</code>, <code>sound</code>, <code>sprites</code>, <code>maps</code>, <code>addons/amxmodx/plugins</code>, <code>configs</code>, SQL-настройки и твои игровые файлы остаются на месте. Меняется только выбранный runtime-компонент.</p></div></div>
      <div class="readonly-settings mt-3"><div><small>AMXX в конфиге</small><b><?=(int)($runtime['configured_plugins']??0)?> плагинов</b></div><div><small>Runtime</small><b><?=(int)($rtHealth['runtime_plugin_running']??0)?> running</b></div></div>
    </section>
  </div>

  <section class="panel-card mt-3">
    <div class="panel-head"><div><h2><i class="fa-solid fa-clock-rotate-left me-2"></i>Rollback Runtime</h2><p>Полные снимки игрового сервера до обновлений Runtime. Откат возвращает всю сборку в точное предыдущее состояние.</p></div></div>
    <?php if($rtBackups):?>
    <form method="post" class="row g-2 align-items-end" onsubmit="return confirm('Полностью вернуть сервер из выбранного Runtime backup?')"><?=csrf_field()?><input type="hidden" name="action" value="runtime_rollback"><input type="hidden" name="id" value="<?=$id?>"><label class="col-md-8"><span>Backup</span><select class="form-select" name="backup" required><?php foreach($rtBackups as $b):?><option value="<?=e((string)($b['name']??''))?>"><?=e((string)($b['name']??''))?><?=!empty($b['component'])?' · '.e((string)$b['component']):''?></option><?php endforeach;?></select></label><div class="col-md-4"><button class="btn btn-danger w-100"><i class="fa-solid fa-rotate-left me-2"></i>Откатить</button></div></form>
    <?php else:?><p class="text-secondary mb-0">Runtime backup ещё не создавался.</p><?php endif;?>
  </section>

  <section class="panel-card mt-3">
    <div class="panel-head"><div><h2>Живая проверка</h2><p>То, что реально отвечает сейчас, а не только версия файла на диске.</p></div></div>
    <div class="readonly-settings"><div><small>systemd</small><b><?=!empty($rtHealth['service_active'])?'active':'down'?></b></div><div><small>UDP</small><b><?=!empty($rtHealth['udp_listening'])?'listening':'down'?></b></div><div><small>AMXX running</small><b><?=(int)($rtHealth['runtime_plugin_running']??0)?> / <?=(int)($rtHealth['runtime_plugin_total']??0)?></b></div></div>
    <?php if(!empty($rtHealth['version'])):?><pre class="console log-console mt-3"><?=e((string)$rtHealth['version'])?></pre><?php endif;?>
  </section>
</div>
