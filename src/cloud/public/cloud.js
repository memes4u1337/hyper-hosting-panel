(() => {
  'use strict';

  const $ = (s, root = document) => root.querySelector(s);
  const $$ = (s, root = document) => Array.from(root.querySelectorAll(s));
  const uploadDialog = $('#uploadDialog');
  const folderDialog = $('#folderDialog');
  const renameDialog = $('#renameDialog');
  const deleteDialog = $('#deleteDialog');
  const filesInput = $('#hcFilesInput');
  const uploadZone = $('#hcUploadZone');
  const uploadForm = $('#hcUploadForm');
  const queue = $('#hcUploadQueue');
  const queueFiles = $('#hcQueueFiles');
  const queueCount = $('#hcQueueCount');
  const queueSize = $('#hcQueueSize');
  const uploadSubmit = $('#hcUploadSubmit');
  const uploadProgress = $('#hcUploadProgress');
  const uploadProgressBar = $('#hcUploadProgressBar');
  const uploadPercent = $('#hcUploadPercent');
  const uploadTransferred = $('#hcUploadTransferred');
  const uploadSpeed = $('#hcUploadSpeed');
  const uploadStatus = $('#hcUploadStatus');
  const dropOverlay = $('#hcDropOverlay');
  const main = $('#hcMain');
  const grid = $('#hcFilesGrid');
  const list = $('#hcFilesList');
  const viewToggle = $('#hcViewToggle');
  const search = $('#hcSearch');
  const itemCount = $('#hcItemCount');
  const searchEmpty = $('#hcSearchEmpty');

  // Bootstrap is used for polished tooltips while Cloud keeps its own visual language.
  if (window.bootstrap?.Tooltip) {
    $$('[title]').forEach(el => {
      try { new window.bootstrap.Tooltip(el, {container: 'body', delay: {show: 350, hide: 50}}); } catch (_) {}
    });
  }

  function closeDialogs(except = null) {
    $$('dialog[open]').forEach(d => {
      if (d !== except) d.close();
    });
  }

  $$('[data-open-dialog]').forEach(btn => {
    btn.addEventListener('click', () => {
      const id = btn.getAttribute('data-open-dialog');
      const dlg = document.getElementById(id);
      if (!dlg) return;
      closeDialogs(dlg);
      if (!dlg.open) dlg.showModal();
      if (dlg === folderDialog) setTimeout(() => $('input[name="name"]', dlg)?.focus(), 40);
    });
  });

  $$('[data-close-dialog]').forEach(btn => {
    btn.addEventListener('click', () => btn.closest('dialog')?.close());
  });

  // Locked modals: backdrop clicks and ESC must never dismiss them.
  // Only an explicit [data-close-dialog] control (the X button) may close a dialog.
  $$('dialog[data-modal-lock="true"]').forEach(dlg => {
    dlg.addEventListener('cancel', e => {
      e.preventDefault();
      e.stopPropagation();
    });
    dlg.addEventListener('click', e => {
      if (e.target === dlg) {
        e.preventDefault();
        e.stopPropagation();
        dlg.classList.remove('hc-modal-pulse');
        void dlg.offsetWidth;
        dlg.classList.add('hc-modal-pulse');
      }
    });
  });

  function humanBytes(bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let value = Number(bytes || 0), i = 0;
    while (value >= 1024 && i < units.length - 1) { value /= 1024; i++; }
    const digits = value >= 10 || i === 0 ? 0 : 1;
    return `${value.toFixed(digits)} ${units[i]}`;
  }

  function renderQueue(files) {
    const arr = Array.from(files || []);
    if (!arr.length) {
      if (queue) queue.hidden = true;
      if (uploadSubmit) uploadSubmit.disabled = true;
      if (queueFiles) queueFiles.innerHTML = '';
      return;
    }
    const total = arr.reduce((sum, f) => sum + (f.size || 0), 0);
    queue.hidden = false;
    uploadSubmit.disabled = false;
    if (!activeUpload && uploadProgress) uploadProgress.hidden = true;
    if (uploadProgressBar) { uploadProgressBar.style.width = '0%'; uploadProgressBar.classList.remove('is-error','is-done'); }
    queueCount.textContent = `${arr.length} ${arr.length === 1 ? 'файл' : 'файлов'}`;
    queueSize.textContent = humanBytes(total);
    queueFiles.innerHTML = arr.slice(0, 30).map(f => `<div><b>${escapeHtml(f.name)}</b><span>${humanBytes(f.size)}</span></div>`).join('') + (arr.length > 30 ? `<div><b>… ещё ${arr.length - 30}</b><span></span></div>` : '');
  }

  function escapeHtml(value) {
    return String(value).replace(/[&<>'"]/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[ch]));
  }

  function assignFiles(fileList) {
    if (!filesInput || !fileList?.length) return;
    try {
      const dt = new DataTransfer();
      Array.from(fileList).forEach(file => dt.items.add(file));
      filesInput.files = dt.files;
    } catch (_) {
      // Older browser: upload zone still supports normal picker.
    }
    renderQueue(filesInput.files?.length ? filesInput.files : fileList);
  }

  filesInput?.addEventListener('change', () => renderQueue(filesInput.files));
  uploadZone?.addEventListener('dragenter', e => { e.preventDefault(); uploadZone.classList.add('drag'); });
  uploadZone?.addEventListener('dragover', e => { e.preventDefault(); uploadZone.classList.add('drag'); });
  uploadZone?.addEventListener('dragleave', () => uploadZone.classList.remove('drag'));
  uploadZone?.addEventListener('drop', e => {
    e.preventDefault(); uploadZone.classList.remove('drag');
    assignFiles(e.dataTransfer?.files);
  });

  let dragDepth = 0;
  window.addEventListener('dragenter', e => {
    if (!Array.from(e.dataTransfer?.types || []).includes('Files')) return;
    dragDepth++;
    dropOverlay?.classList.add('active');
  });
  window.addEventListener('dragover', e => {
    if (Array.from(e.dataTransfer?.types || []).includes('Files')) e.preventDefault();
  });
  window.addEventListener('dragleave', e => {
    if (!Array.from(e.dataTransfer?.types || []).includes('Files')) return;
    dragDepth = Math.max(0, dragDepth - 1);
    if (!dragDepth) dropOverlay?.classList.remove('active');
  });
  window.addEventListener('drop', e => {
    if (!Array.from(e.dataTransfer?.types || []).includes('Files')) return;
    e.preventDefault();
    dragDepth = 0;
    dropOverlay?.classList.remove('active');
    const files = e.dataTransfer?.files;
    if (!files?.length || !uploadDialog) return;
    assignFiles(files);
    closeDialogs(uploadDialog);
    if (!uploadDialog.open) uploadDialog.showModal();
  });

  let activeUpload = false;

  function randomUploadId() {
    const b = new Uint8Array(16);
    if (window.crypto?.getRandomValues) window.crypto.getRandomValues(b);
    else for (let i=0;i<b.length;i++) b[i]=Math.floor(Math.random()*256);
    return Array.from(b, x => x.toString(16).padStart(2,'0')).join('');
  }

  function xhrForm(url, data, onProgress = null) {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', url, true);
      xhr.timeout = 0;
      xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
      xhr.setRequestHeader('Accept', 'application/json');
      if (onProgress) xhr.upload.addEventListener('progress', onProgress);
      xhr.addEventListener('error', () => reject(new Error('Ошибка соединения')));
      xhr.addEventListener('abort', () => reject(new Error('Загрузка прервана')));
      xhr.addEventListener('load', () => {
        let payload = null;
        try { payload = JSON.parse(xhr.responseText || '{}'); } catch (_) {}
        if (xhr.status < 200 || xhr.status >= 300) {
          if (xhr.status === 401 && payload?.auth === false) {
            window.location.href = '/?auth=login';
            reject(new Error(payload?.error || 'Сессия завершена'));
            return;
          }
          reject(new Error(payload?.error || `Ошибка сервера (${xhr.status || 0})`));
          return;
        }
        if (!payload || payload.ok !== true) {
          reject(new Error(payload?.error || `Некорректный ответ сервера (${xhr.status || 0})`));
          return;
        }
        resolve(payload);
      });
      xhr.send(data);
    });
  }

  uploadForm?.addEventListener('submit', async e => {
    if (!filesInput?.files?.length || activeUpload) return;
    e.preventDefault();
    activeUpload = true;
    const files = Array.from(filesInput.files);
    const csrf = $('input[name="_csrf"]', uploadForm)?.value || '';
    const currentPath = $('input[name="path"]', uploadForm)?.value || '';
    const uploadTarget = $('#hcUploadTarget')?.value || '';
    const endpoint = uploadForm.action || '/api/upload.php';
    const uploadSpace = $('input[name="space"]', uploadForm)?.value || 'private';
    const totalBytes = files.reduce((sum,f)=>sum+Number(f.size||0),0);
    const chunkSize = 4 * 1024 * 1024;
    let completedBytes = 0;
    let lastBytes = 0;
    let lastAt = performance.now();
    let finalRedirect = window.location.href;

    uploadSubmit.disabled = true;
    uploadSubmit.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i>Загрузка…';
    if (uploadProgress) uploadProgress.hidden = false;
    if (uploadProgressBar) { uploadProgressBar.classList.remove('is-error','is-done'); uploadProgressBar.style.width='0%'; }
    if (uploadPercent) uploadPercent.textContent='0%';
    if (uploadTransferred) uploadTransferred.textContent=`0 B / ${humanBytes(totalBytes)}`;
    if (uploadSpeed) uploadSpeed.textContent='Подготовка…';
    uploadForm.classList.add('is-uploading');

    const paint = (logicalBytes, status) => {
      const safe = Math.max(0, Math.min(totalBytes, logicalBytes));
      const pct = totalBytes > 0 ? Math.min(99, Math.floor((safe / totalBytes) * 100)) : 0;
      const now = performance.now();
      const dt = Math.max(.05,(now-lastAt)/1000);
      const speed = Math.max(0,(safe-lastBytes)/dt);
      if (now-lastAt > 250) { lastAt=now; lastBytes=safe; }
      if(uploadPercent) uploadPercent.textContent=`${pct}%`;
      if(uploadProgressBar) uploadProgressBar.style.width=`${pct}%`;
      if(uploadTransferred) uploadTransferred.textContent=`${humanBytes(safe)} / ${humanBytes(totalBytes)}`;
      if(uploadSpeed) uploadSpeed.textContent=speed>0?`${humanBytes(speed)}/с`:'Загрузка…';
      if(uploadStatus&&status) uploadStatus.textContent=status;
    };

    try {
      for (let fileIndex=0; fileIndex<files.length; fileIndex++) {
        const file = files[fileIndex];
        const uploadId = randomUploadId();
        const chunks = Math.max(1, Math.ceil(file.size / chunkSize));
        let fileDone = 0;
        for (let ci=0; ci<chunks; ci++) {
          const start = ci * chunkSize;
          const end = Math.min(file.size, start + chunkSize);
          const blob = file.slice(start,end);
          const fd = new FormData();
          fd.set('_csrf',csrf); fd.set('action','upload_chunk'); fd.set('ajax_upload','1'); fd.set('space',uploadSpace);
          fd.set('path',currentPath); fd.set('upload_target',uploadTarget); fd.set('upload_id',uploadId);
          fd.set('file_name',file.name); fd.set('file_size',String(file.size)); fd.set('chunk_index',String(ci)); fd.set('total_chunks',String(chunks));
          fd.set('chunk',blob,file.name+'.part');
          let lastError = null;
          for (let attempt=1; attempt<=3; attempt++) {
            try {
              await xhrForm(endpoint,fd,ev=>{
                if(!ev.lengthComputable)return;
                const currentChunk=Math.min(blob.size,ev.loaded);
                paint(completedBytes + fileDone + currentChunk, `${file.name} · часть ${ci+1}/${chunks}`);
              });
              lastError = null;
              break;
            } catch (err) {
              lastError = err;
              if (attempt < 3) {
                if(uploadStatus)uploadStatus.textContent=`${file.name} · повтор части ${ci+1}/${chunks} (${attempt+1}/3)`;
                await new Promise(r=>setTimeout(r, 500 * attempt));
              }
            }
          }
          if (lastError) throw lastError;
          fileDone += blob.size;
          paint(completedBytes + fileDone, `${file.name} · ${ci+1}/${chunks}`);
        }
        const done = new FormData();
        done.set('_csrf',csrf); done.set('action','upload_complete'); done.set('ajax_upload','1'); done.set('space',uploadSpace); done.set('path',currentPath); done.set('upload_id',uploadId);
        const payload = await xhrForm(endpoint,done);
        finalRedirect = payload.redirect || finalRedirect;
        completedBytes += file.size;
        paint(completedBytes, files.length===1?'Файл загружен':`Готово ${fileIndex+1} из ${files.length}`);
      }
      if(uploadPercent)uploadPercent.textContent='100%';
      if(uploadProgressBar){uploadProgressBar.style.width='100%';uploadProgressBar.classList.add('is-done');}
      if(uploadTransferred)uploadTransferred.textContent=`${humanBytes(totalBytes)} / ${humanBytes(totalBytes)}`;
      if(uploadSpeed)uploadSpeed.textContent='Готово';
      if(uploadStatus)uploadStatus.textContent=files.length===1?'Файл загружен':`Загружено файлов: ${files.length}`;
      uploadSubmit.innerHTML='<i class="fa-solid fa-check"></i>Готово';
      setTimeout(()=>{ window.location.href=finalRedirect; },450);
    } catch (err) {
      activeUpload=false;
      uploadForm.classList.remove('is-uploading');
      uploadSubmit.disabled=false;
      uploadSubmit.innerHTML='<i class="fa-solid fa-cloud-arrow-up"></i>Повторить';
      if(uploadStatus)uploadStatus.textContent=err?.message||'Не удалось загрузить';
      if(uploadPercent)uploadPercent.textContent='Ошибка';
      if(uploadProgressBar)uploadProgressBar.classList.add('is-error');
      if(uploadSpeed)uploadSpeed.textContent='Можно повторить загрузку';
      return;
    }
  });

  $$('[data-menu-for]').forEach(btn => {
    btn.addEventListener('click', e => {
      e.stopPropagation();
      const menu = document.getElementById(btn.getAttribute('data-menu-for'));
      $$('.hc-context-menu.open').forEach(m => { if (m !== menu) m.classList.remove('open'); });
      menu?.classList.toggle('open');
    });
  });
  document.addEventListener('click', () => $$('.hc-context-menu.open').forEach(m => m.classList.remove('open')));
  $$('.hc-context-menu').forEach(m => m.addEventListener('click', e => e.stopPropagation()));

  $$('[data-rename-target]').forEach(btn => {
    btn.addEventListener('click', () => {
      $('#hcRenameTarget').value = btn.getAttribute('data-rename-target') || '';
      $('#hcRenameName').value = btn.getAttribute('data-rename-name') || '';
      closeDialogs(renameDialog);
      renameDialog?.showModal();
      setTimeout(() => $('#hcRenameName')?.select(), 40);
    });
  });

  $$('[data-delete-target]').forEach(btn => {
    btn.addEventListener('click', () => {
      const target = btn.getAttribute('data-delete-target') || '';
      const name = btn.getAttribute('data-delete-name') || target || 'Файл';
      const targetInput = $('#hcDeleteTarget');
      const nameEl = $('#hcDeleteName');
      if (targetInput) targetInput.value = target;
      if (nameEl) nameEl.textContent = name;
      $$('.hc-context-menu.open').forEach(m => m.classList.remove('open'));
      closeDialogs(deleteDialog);
      if (deleteDialog && !deleteDialog.open) deleteDialog.showModal();
    });
  });

  function applyView(mode) {
    const useList = mode === 'list';
    if (grid) grid.hidden = useList;
    if (list) list.hidden = !useList;
    if (viewToggle) viewToggle.innerHTML = useList ? '<i class="fa-solid fa-table-cells-large"></i>' : '<i class="fa-solid fa-list"></i>';
    try { localStorage.setItem('hyperCloudView', useList ? 'list' : 'grid'); } catch (_) {}
  }
  let savedView = 'grid';
  try { savedView = localStorage.getItem('hyperCloudView') || 'grid'; } catch (_) {}
  applyView(savedView);
  viewToggle?.addEventListener('click', () => applyView(list?.hidden ? 'list' : 'grid'));

  function filterItems() {
    const q = (search?.value || '').trim().toLowerCase();
    const cardRows = $$('.hc-file-card');
    const listRows = $$('.hc-list-row');
    let visible = 0;
    cardRows.forEach(row => {
      const ok = !q || (row.dataset.fileName || '').includes(q);
      row.classList.toggle('hc-hidden', !ok);
      if (ok) visible++;
    });
    listRows.forEach(row => {
      const ok = !q || (row.dataset.fileName || '').includes(q);
      row.classList.toggle('hc-hidden', !ok);
    });
    if (itemCount) itemCount.textContent = `${q ? visible : cardRows.length} элементов`;
    if (searchEmpty) searchEmpty.hidden = !q || visible > 0;
  }
  search?.addEventListener('input', filterItems);

  const sidebar = $('#hcSidebar');
  const menuButton = $('#hcMenuButton');
  const mobileBackdrop = $('#hcMobileBackdrop');
  const setMobileMenu = open => {
    sidebar?.classList.toggle('open', open);
    mobileBackdrop?.classList.toggle('active', open);
  };
  menuButton?.addEventListener('click', () => setMobileMenu(!sidebar?.classList.contains('open')));
  mobileBackdrop?.addEventListener('click', () => setMobileMenu(false));



  const shareDialog = $('#shareDialog');
  const shareName = $('#hcShareName');
  const sharePrivate = $('#hcSharePrivate');
  const sharePublic = $('#hcSharePublic');
  const shareLinkBox = $('#hcShareLinkBox');
  const shareUrl = $('#hcShareUrl');
  const shareEnableForm = $('#hcShareEnableForm');
  const shareDisableForm = $('#hcShareDisableForm');
  const shareEnableTarget = $('#hcShareEnableTarget');
  const shareDisableTarget = $('#hcShareDisableTarget');
  const copyShare = $('#hcCopyShare');

  function absoluteShareUrl(value) {
    if (!value) return '';
    try { return new URL(value, window.location.origin).href; } catch (_) { return value; }
  }

  function openShareDialog(trigger) {
    if (!shareDialog || !trigger) return;
    const target = trigger.getAttribute('data-share-target') || '';
    const name = trigger.getAttribute('data-share-name') || 'Файл';
    const enabled = trigger.getAttribute('data-share-enabled') === '1';
    const url = absoluteShareUrl(trigger.getAttribute('data-share-url') || '');
    if (shareName) shareName.textContent = name;
    if (shareEnableTarget) shareEnableTarget.value = target;
    if (shareDisableTarget) shareDisableTarget.value = target;
    if (sharePrivate) sharePrivate.hidden = enabled;
    if (sharePublic) sharePublic.hidden = !enabled;
    if (shareLinkBox) shareLinkBox.hidden = !enabled;
    if (shareEnableForm) shareEnableForm.hidden = enabled;
    if (shareDisableForm) shareDisableForm.hidden = !enabled;
    if (shareUrl) shareUrl.value = url;
    $$('.hc-context-menu.open').forEach(m => m.classList.remove('open'));
    closeDialogs(shareDialog);
    if (!shareDialog.open) shareDialog.showModal();
    if (enabled) setTimeout(() => shareUrl?.select(), 80);
  }

  $$('[data-share-target]').forEach(btn => btn.addEventListener('click', () => openShareDialog(btn)));

  async function copyText(value) {
    if (!value) return false;
    try {
      await navigator.clipboard.writeText(value);
      return true;
    } catch (_) {
      if (!shareUrl) return false;
      shareUrl.focus(); shareUrl.select();
      try { return document.execCommand('copy'); } catch (__) { return false; }
    }
  }

  copyShare?.addEventListener('click', async () => {
    const text = shareUrl?.value || '';
    const ok = await copyText(text);
    const old = copyShare.innerHTML;
    copyShare.innerHTML = ok ? '<i class="fa-solid fa-check"></i><span>Скопировано</span>' : '<i class="fa-solid fa-triangle-exclamation"></i><span>Не удалось</span>';
    copyShare.classList.toggle('copied', ok);
    setTimeout(() => { copyShare.innerHTML = old; copyShare.classList.remove('copied'); }, 1800);
  });

  const autoShare = document.body?.getAttribute('data-share-open') || '';
  if (autoShare) {
    const trigger = $$('[data-share-target]').find(el => (el.getAttribute('data-share-target') || '') === autoShare);
    if (trigger) setTimeout(() => openShareDialog(trigger), 80);
  }

  // Built-in code editor: tabs, live line counter and Ctrl/Cmd+S.
  $$('.hc-code-editor').forEach(editor => {
    const form = editor.closest('form[data-editor-form]');
    const lines = $('#hcEditorLines', form || document);
    const updateLines = () => {
      if (!lines) return;
      const count = (editor.value.match(/\n/g) || []).length + 1;
      lines.textContent = `${count} ${count % 10 === 1 && count % 100 !== 11 ? 'строка' : (count % 10 >= 2 && count % 10 <= 4 && (count % 100 < 10 || count % 100 >= 20) ? 'строки' : 'строк')}`;
    };
    updateLines();
    editor.addEventListener('input', updateLines);
    editor.addEventListener('keydown', e => {
      if (e.key === 'Tab') {
        e.preventDefault();
        const start = editor.selectionStart;
        const end = editor.selectionEnd;
        editor.setRangeText('  ', start, end, 'end');
        updateLines();
        return;
      }
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') {
        e.preventDefault();
        if (!editor.readOnly && form) form.requestSubmit();
      }
    });
    form?.addEventListener('submit', () => {
      const save = form.querySelector('button[type="submit"]');
      if (save) {
        save.disabled = true;
        save.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i>Сохранение…';
      }
    });
  });

  $('[data-html-refresh]')?.addEventListener('click', btnEvent => {
    const frame = $('#hcHtmlFrame');
    if (!frame) return;
    const btn = btnEvent.currentTarget;
    btn?.classList.add('is-spinning');
    try {
      const url = new URL(frame.src, window.location.href);
      url.searchParams.set('_preview_refresh', Date.now().toString());
      frame.src = url.href;
    } catch (_) { frame.src = frame.src; }
    setTimeout(() => btn?.classList.remove('is-spinning'), 650);
  });

  // ESC is intentionally disabled for open Cloud modals.
  document.addEventListener('keydown', e => {
    if (e.key !== 'Escape') return;
    const locked = $('dialog[data-modal-lock="true"][open]');
    if (locked) {
      e.preventDefault();
      e.stopImmediatePropagation();
      locked.classList.remove('hc-modal-pulse');
      void locked.offsetWidth;
      locked.classList.add('hc-modal-pulse');
      return;
    }
    $$('.hc-context-menu.open').forEach(m => m.classList.remove('open'));
  }, true);
})();
