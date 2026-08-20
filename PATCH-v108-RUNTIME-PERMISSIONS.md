# HYPER CLOUD v108 — runtime permissions repair

## Причина падения v107

На конкретной установке пользователь `hypercloud` не мог пройти по одному из
родительских каталогов / ACL и прочитать:

`/var/www/hyper-host-cloud-app/app/bootstrap.php`

Сам файл был установлен, но CLI-проверка под `hypercloud` получила EACCES.

## Что исправлено

- Сбрасываются только старые ACL внутри `/var/www/hyper-host-cloud-app`.
- PHP-файлы остаются `root:hypercloud 0640`: runtime может читать, но не менять.
- `app/` остаётся закрытым от посторонних, public-каталог доступен nginx для stat/static.
- На `/var/www` для `hypercloud` добавляется только traverse (`--x`), а не чтение списка.
- На `/etc/hyper-host` добавляется только traverse, доступ выдаётся только к `cloud.php`.
- До DB init выполняются реальные `runuser -u hypercloud -- test -r ...`.
- При проблеме выводятся `namei -l` и `getfacl` с конкретным узлом.
- DB init и smoke-tests выполняются через `runuser`, без зависимости от общей sudo-policy.
- Сохраняются изоляция panel DB, read-only application code, отдельный FPM pool,
  editor/site smoke-test и vhost persistence.

## Данные

Cloud DB, аккаунты, личные файлы, shared и публичные ссылки не сбрасываются.
