# HYPER-HOST v82 — restore old sites + beta only

- Restores the exact Nginx/site configuration captured before v79 global site rebuilds.
- Restores only the `sites` table metadata from that backup; users, bots and other panel data are untouched.
- Removes the v81 global managed site config.
- Restores the pre-v79 `hhctl` site behavior while keeping Deploy Manager v78 fixes.
- Adds only one dedicated vhost for `beta.mystockbot.xyz`.
- `beta.mystockbot.xyz` always serves `/var/www/hyper-host-sites/beta.mystockbot.xyz/public_html`.
- `index.html` has priority over old `index.php` placeholders for beta only.
- Existing SSL is reused only when the certificate actually matches beta.
- Verifies the panel, beta and every restored site before completing.
- Does not modify FTP, bot files, site content or the admin password.
