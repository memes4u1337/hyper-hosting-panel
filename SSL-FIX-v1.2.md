# HYPER-HOST v1.2 — SSL One-Click Final

Исправление возвращает старые сертификаты в Nginx и делает выпуск SSL для новых сайтов однокнопочным.

## Что изменено

- Certbot использует только `/opt/hyper-host/letsencrypt`.
- Существующие сертификаты автоматически переподключаются к Nginx.
- Выбирается самый свежий подходящий сертификат, а не первый найденный.
- Основной домен и его aliases/www проверяются отдельно.
- Для aliases с правильным DNS выпускаются отдельные сертификаты, поэтому один неверный alias не ломает основной домен.
- После выпуска выполняются `nginx -t`, reload и локальная SNI-проверка реально отдаваемого сертификата.
- Значки SSL в панели синхронизируются с фактическим состоянием сертификатов.
- Время ожидания выпуска через веб-панель увеличено до 1200 секунд.
- FTP, базы и файлы сайтов не изменяются.

## Установка

```bash
cd /root && \
rm -rf /root/hyper-hosting-panel && \
git clone --depth 1 --branch main https://github.com/memes4u1337/hyper-hosting-panel.git /root/hyper-hosting-panel && \
cd /root/hyper-hosting-panel && \
chmod +x apply-v1.2-ssl-oneclick-final.sh && \
sudo ./apply-v1.2-ssl-oneclick-final.sh /root/hyper-hosting-panel
```

## Восстановить и выпустить SSL на всех сайтах

```bash
sudo hyper ssl repair-all EMAIL
sudo hyper ssl status
sudo nginx -t
```
