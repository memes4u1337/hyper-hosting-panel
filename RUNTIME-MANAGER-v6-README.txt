HYPER-HOST CS 1.6 — RUNTIME MANAGER v6
Date: 2026-09-23

PURPOSE
Adds a separate Runtime tab to each CS 1.6 server and safely migrates legacy builds such as BUILD 4419 to a modern runtime while preserving the actual game assembly.

RECOMMENDED MIGRATION
- refresh official HLDS engine baseline through SteamCMD App 90 / steam_legacy in a separate cache
- DO NOT overwrite/delete the server cstrike tree
- install ReHLDS 3.15.0.896
- install ReGameDLL_CS 5.30.0.814
- install Metamod-R 1.3.0.149
- install/update ReAPI 5.29.0.358 only when the current assembly uses it

SEPARATE RUNTIME TAB CONTROLS
- HLDS / SteamCMD base
- ReHLDS
- ReGameDLL_CS
- Metamod-R
- ReAPI
- AMX Mod X 1.9 compatibility runtime
- AMX Mod X 1.10 build 5486
- ReUnion stable 0.2.0.25
- YaPB update with current addons/yapb/conf preserved
- full rollback from Runtime backups

PRESERVED
- cstrike/models
- cstrike/sound
- cstrike/sprites
- cstrike/maps
- cstrike/addons/amxmodx/plugins
- cstrike/addons/amxmodx/configs
- users.ini, SQL settings, data/lang, custom scripts
- Zombie Plague and custom VIP/Admin/weapon/knife plugins
- current ReUnion config when ReUnion is updated
- current YaPB conf directory when YaPB is updated

TRANSACTION SAFETY
Every update:
1. reads live server/runtime/AMXX health
2. stops the automatic FastDL timer during the transaction
3. creates a FULL server backup with rsync
4. stops the game server
5. updates only the selected runtime layer
6. starts and validates systemd + UDP + Metamod + AMXX
7. checks that AMXX running plugin count did not decrease
8. automatically restores the FULL backup if validation regresses
9. syncs FastDL only after a successful update
10. restores the FastDL timer

INSTALL FOR CURRENT SERVER #25
Upload apply-cs16-runtime-manager-v6.sh to the root of the GitHub repository, then run WITHOUT git reset --hard:

cd /root/hyper-hosting-panel && \
git fetch https://github.com/memes4u1337/hyper-hosting-panel.git main && \
git show FETCH_HEAD:apply-cs16-runtime-manager-v6.sh > /tmp/apply-cs16-runtime-manager-v6.sh && \
chmod +x /tmp/apply-cs16-runtime-manager-v6.sh && \
sudo bash /tmp/apply-cs16-runtime-manager-v6.sh /root/hyper-hosting-panel 25

Passing 25 at the end installs the tab and immediately runs the safe "recommended" migration for server #25. Passing 0 installs only the panel/runtime manager without changing a game server.

WHY NO git reset --hard HERE
The current working tree may already contain the FastDL v5.1/v5.2 changes. git show fetches only this installer so those local changes are not discarded.

FILES INSTALLED
Repository:
  cs16-panel/bin/hyper-cs16-runtime-ctl
  cs16-panel/app/runtime-pane.php
  patched cs16-panel/app/bootstrap.php
  patched cs16-panel/public/index.php
  patched install-cs16-panel.sh

Node:
  /usr/local/sbin/hyper-cs16-runtime-ctl
  /var/lib/hyper-cs16/runtime-stack/<id>.json
  /srv/hyper-cs16/runtime-backups/<id>/...
  /srv/hyper-cs16/runtime-cache/steam-legacy

MANUAL CHECKS
sudo hyper-cs16-runtime-ctl status 25
sudo hyper-cs16-runtime-ctl backups 25

Manual recommended update:
sudo hyper-cs16-runtime-ctl update 25 recommended

The panel Runtime tab provides the same operations with buttons and rollback controls.
