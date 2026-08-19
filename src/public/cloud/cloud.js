(() => {
  'use strict';

  const $ = (s, root = document) => root.querySelector(s);
  const $$ = (s, root = document) => Array.from(root.querySelectorAll(s));
  const uploadDialog = $('#uploadDialog');
  const folderDialog = $('#folderDialog');
  const renameDialog = $('#renameDialog');
  const filesInput = $('#hcFilesInput');
  const uploadZone = $('#hcUploadZone');
  const uploadForm = $('#hcUploadForm');
  const queue = $('#hcUploadQueue');
  const queueFiles = $('#hcQueueFiles');
  const queueCount = $('#hcQueueCount');
  const queueSize = $('#hcQueueSize');
  const uploadSubmit = $('#hcUploadSubmit');
  const dropOverlay = $('#hcDropOverlay');
  const main = $('#hcMain');
  const grid = $('#hcFilesGrid');
  const list = $('#hcFilesList');
  const viewToggle = $('#hcViewToggle');
  const search = $('#hcSearch');
  const itemCount = $('#hcItemCount');
  const searchEmpty = $('#hcSearchEmpty');

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

  $$('dialog').forEach(dlg => {
    dlg.addEventListener('click', e => {
      const rect = dlg.getBoundingClientRect();
      const inside = e.clientX >= rect.left && e.clientX <= rect.right && e.clientY >= rect.top && e.clientY <= rect.bottom;
      if (!inside) dlg.close();
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

  uploadForm?.addEventListener('submit', () => {
    if (!filesInput?.files?.length) return;
    uploadSubmit.disabled = true;
    uploadSubmit.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i>Загрузка…';
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

  // ESC closes context menus first; native dialogs handle themselves.
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') $$('.hc-context-menu.open').forEach(m => m.classList.remove('open'));
  });
})();
