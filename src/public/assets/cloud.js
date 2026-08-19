(() => {
  'use strict';

  const form = document.getElementById('cloudUploadForm');
  const zone = document.getElementById('cloudDropzone');
  const input = document.getElementById('cloudFiles');
  const browse = document.getElementById('cloudBrowseButton');
  const queue = document.getElementById('cloudUploadQueue');
  const queueFiles = document.getElementById('cloudUploadFiles');
  const queueTitle = document.getElementById('cloudQueueTitle');
  const queueSize = document.getElementById('cloudQueueSize');
  const submit = document.getElementById('cloudUploadSubmit');
  const target = document.getElementById('cloudUploadTarget');

  if (!form || !zone || !input) return;

  const humanBytes = (bytes) => {
    let value = Number(bytes || 0);
    const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
    let i = 0;
    while (value >= 1024 && i < units.length - 1) {
      value /= 1024;
      i += 1;
    }
    return `${value >= 10 || i === 0 ? value.toFixed(0) : value.toFixed(1)} ${units[i]}`;
  };

  const renderFiles = () => {
    const files = Array.from(input.files || []);
    if (!queue || !queueFiles) return;
    queueFiles.replaceChildren();
    if (!files.length) {
      queue.classList.remove('has-files');
      return;
    }
    let total = 0;
    files.slice(0, 20).forEach((file) => {
      total += file.size || 0;
      const row = document.createElement('div');
      row.className = 'cloud-upload-file';
      const name = document.createElement('span');
      name.textContent = file.name;
      const size = document.createElement('small');
      size.textContent = humanBytes(file.size);
      row.append(name, size);
      queueFiles.append(row);
    });
    if (files.length > 20) {
      const more = document.createElement('div');
      more.className = 'cloud-meta';
      more.textContent = `+ ещё ${files.length - 20} файлов`;
      queueFiles.append(more);
    }
    if (queueTitle) queueTitle.textContent = `${files.length} файл(ов) готовы`;
    if (queueSize) queueSize.textContent = humanBytes(total);
    queue.classList.add('has-files');
  };

  const applyDroppedFiles = (files) => {
    if (!files || !files.length) return;
    try {
      const transfer = new DataTransfer();
      Array.from(files).forEach((file) => transfer.items.add(file));
      input.files = transfer.files;
      renderFiles();
    } catch (_) {
      // Very old browsers may not allow assigning FileList. Click input remains available.
      input.click();
    }
  };

  ['dragenter', 'dragover'].forEach((eventName) => {
    zone.addEventListener(eventName, (event) => {
      event.preventDefault();
      event.stopPropagation();
      zone.classList.add('is-dragover');
      if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy';
    });
  });

  ['dragleave', 'dragend'].forEach((eventName) => {
    zone.addEventListener(eventName, (event) => {
      event.preventDefault();
      event.stopPropagation();
      zone.classList.remove('is-dragover');
    });
  });

  zone.addEventListener('drop', (event) => {
    event.preventDefault();
    event.stopPropagation();
    zone.classList.remove('is-dragover');
    applyDroppedFiles(event.dataTransfer?.files);
  });

  zone.addEventListener('click', (event) => {
    if (event.target.closest('#cloudBrowseButton')) return;
    input.click();
  });
  zone.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      input.click();
    }
  });
  browse?.addEventListener('click', (event) => {
    event.stopPropagation();
    input.click();
  });
  input.addEventListener('change', renderFiles);

  form.addEventListener('submit', (event) => {
    if (!input.files || input.files.length === 0) {
      event.preventDefault();
      input.click();
      return;
    }
    if (submit) {
      submit.disabled = true;
      const destination = target?.selectedOptions?.[0]?.textContent?.trim() || 'облако';
      submit.innerHTML = `<span class="spinner-border spinner-border-sm me-2" aria-hidden="true"></span>Загружаю → ${destination}`;
    }
  });
})();
