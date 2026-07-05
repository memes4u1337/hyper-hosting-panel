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
