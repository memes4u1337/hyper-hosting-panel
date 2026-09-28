#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
CSTRIKE="/srv/hyper-cs16/servers/$SID/cstrike"
UNP="$CSTRIKE/addons/unprecacher"
META="$CSTRIKE/addons/metamod/plugins.ini"
LIVE="/usr/local/sbin/hyper-cs16-ctl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/oldz-final-v30-${STAMP}"

fail(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
[[ -f "$UNP/unprecacher_mm_i386.so" ]] || fail "missing $UNP/unprecacher_mm_i386.so"
[[ -f "$META" ]] || fail "missing $META"

mkdir -p "$BACKUP"
cp -a "$UNP" "$BACKUP/unprecacher.before" 2>/dev/null || true
cp -a "$META" "$BACKUP/metamod-plugins.before.ini"

echo "================================================================"
echo " OLD ZOMBIE FINAL v30"
echo " Server: #$SID"
echo " Backup: $BACKUP"
echo " No compilation. No AMXX plugin changes."
echo " FastDL/nginx/site: NOT MODIFIED"
echo "================================================================"

echo "[1/5] Install correct Ultimate Unprecacher config..."

mkdir -p "$UNP"

cat > "$UNP/config.ini" <<'EOF'
// OLD ZOMBIE v30
logger_verbosity = bcde
logger_output = 3
module_checks = abcdef
EOF

echo "[2/5] Fix list.ini syntax + add stock CS sounds..."

python3 - "$UNP/list.ini" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])

existing = []

if p.exists():
    for line in p.read_text(
        encoding="utf-8",
        errors="ignore"
    ).splitlines():

        s = line.strip()

        if not s:
            continue

        if s.startswith(("//", "#", ";")):
            continue

        # Убираем кавычки из старого кривого формата
        s = s.strip().strip('"').strip("'")

        token = s.split()[0].replace("\\", "/")

        if token.lower().startswith("sound/"):
            token = token[6:]

        if token:
            existing.append(token)


stock = [
    "weapons/ric_conc-1.wav",
    "weapons/ric_conc-2.wav",
    "weapons/ric_metal-1.wav",
    "weapons/ric_metal-2.wav",
    "weapons/ric1.wav",
    "weapons/ric2.wav",
    "weapons/ric3.wav",
    "weapons/ric4.wav",
    "weapons/ric5.wav",

    "ambience/3dmbridge.wav",
    "ambience/3dmeagle.wav",
    "ambience/3dmstart.wav",
    "ambience/3dmthrill.wav",
    "ambience/alarm1.wav",
    "ambience/arabmusic.wav",
    "ambience/Birds1.wav",
    "ambience/Birds2.wav",
    "ambience/Birds3.wav",
    "ambience/Birds4.wav",
    "ambience/Birds5.wav",
    "ambience/Birds6.wav",
    "ambience/Birds7.wav",
    "ambience/Birds8.wav",
    "ambience/Birds9.wav",
    "ambience/car1.wav",
    "ambience/car2.wav",
    "ambience/cat1.wav",
    "ambience/chimes.wav",
    "ambience/cicada3.wav",
    "ambience/copter.wav",
    "ambience/cow.wav",
    "ambience/crow.wav",
    "ambience/dog1.wav",
    "ambience/dog2.wav",
    "ambience/dog3.wav",
    "ambience/dog4.wav",
    "ambience/dog5.wav",
    "ambience/dog6.wav",
    "ambience/dog7.wav",
    "ambience/doorbell.wav",
    "ambience/fallscream.wav",
    "ambience/guit1.wav",
    "ambience/kajika.wav",
    "ambience/lv1.wav",
    "ambience/lv2.wav",
    "ambience/lv3.wav",
    "ambience/lv4.wav",
    "ambience/lv5.wav",
    "ambience/lv6.wav",
    "ambience/lv_elvis.wav",
    "ambience/lv_fruit1.wav",
    "ambience/lv_fruit2.wav",
    "ambience/lv_fruitwin.wav",
    "ambience/lv_jubilee.wav",
    "ambience/lv_neon.wav",
    "ambience/Opera.wav",
    "ambience/rain.wav",
    "ambience/ratchant.wav",
    "ambience/rd_shipshorn.wav",
    "ambience/rd_waves.wav",
    "ambience/sheep.wav",
    "ambience/sparrow.wav",
    "ambience/thunder_clap.wav",
    "ambience/waterrun.wav",
    "ambience/wolfhowl01.wav",
    "ambience/wolfhowl02.wav",

    "events/enemy_died.wav",
    "events/friend_died.wav",
    "events/task_complete.wav",
    "events/tutor_msg.wav",

    "hostage/hos1.wav",
    "hostage/hos2.wav",
    "hostage/hos3.wav",
    "hostage/hos4.wav",
    "hostage/hos5.wav",

    "items/equip_nvg.wav",
    "items/kevlar.wav",
    "items/nvg_off.wav",
    "items/nvg_on.wav",
    "items/tr_kevlar.wav",

    "plats/vehicle1.wav",
    "plats/vehicle2.wav",
    "plats/vehicle3.wav",
    "plats/vehicle4.wav",
    "plats/vehicle6.wav",
    "plats/vehicle7.wav",
    "plats/vehicle_brake1.wav",
    "plats/vehicle_ignition.wav",
    "plats/vehicle_start1.wav",

    "radio/ct_affirm.wav",
    "radio/ct_backup.wav",
    "radio/ct_coverme.wav",
    "radio/ct_enemys.wav",
    "radio/ct_fireinhole.wav",
    "radio/ct_inpos.wav",
    "radio/ct_point.wav",
    "radio/ct_reportingin.wav",
    "radio/ctwin.wav",
    "radio/enemydown.wav",
    "radio/fallback.wav",
    "radio/fireassis.wav",
    "radio/flankthem.wav",
    "radio/followme.wav",
    "radio/getout.wav",
    "radio/go.wav",
    "radio/letsgo.wav",
    "radio/locknload.wav",
    "radio/matedown.wav",
    "radio/meetme.wav",
    "radio/moveout.wav",
    "radio/negative.wav",
    "radio/position.wav",
    "radio/regroup.wav",
    "radio/roger.wav",
    "radio/sticktog.wav",
    "radio/stormfront.wav",
    "radio/takepoint.wav",
]

seen = set()
out = []

for x in existing + stock:

    x = x.strip().replace("\\", "/")

    if not x:
        continue

    low = x.lower()

    if low in seen:
        continue

    seen.add(low)
    out.append(x)


header = [
    "// OLD ZOMBIE v30",
    "// Ultimate Unprecacher syntax: raw path, NO quotes.",
    "// Existing custom blocked sounds are preserved.",
    "// Stock CS sounds added to free GoldSrc precache slots.",
]

p.write_text(
    "\n".join(header + out) + "\n",
    encoding="utf-8"
)

print("unprecache entries:", len(out))

critical = [
    "weapons/ric_conc-2.wav",
    "weapons/ric_metal-2.wav",
]

for item in critical:
    print(item, "=", item.lower() in seen)

if len(out) < 250:
    raise SystemExit("not enough unprecache entries")
PY


echo "[3/5] Put Ultimate Unprecacher FIRST in Metamod..."

python3 - "$META" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])

needle = "linux addons/unprecacher/unprecacher_mm_i386.so"

lines = p.read_text(
    encoding="utf-8",
    errors="ignore"
).splitlines()

lines = [
    line
    for line in lines
    if "unprecacher" not in line.lower()
]

body = "\n".join(lines).strip()

text = needle + "\n"

if body:
    text += body + "\n"

p.write_text(
    text,
    encoding="utf-8"
)

print(p.read_text(encoding="utf-8"))
PY


echo "[4/5] Restart server..."

systemctl reset-failed \
    "hyper-cs16@${SID}.service" \
    >/dev/null 2>&1 || true

systemctl restart \
    "hyper-cs16@${SID}.service"

sleep 3


RECENT="$(
    journalctl \
        -u "hyper-cs16@${SID}.service" \
        --since "-10 seconds" \
        --no-pager \
        2>/dev/null \
        || true
)"


echo
echo "--- STATUS ---"

"$LIVE" status "$SID" || true


echo
echo "--- PRECACHE / FATAL CHECK ---"

echo "$RECENT" | \
grep -Ei \
'Ultimate Unprecacher|PF_precache|512 limit|Host_Error|FATAL ERROR|segv|core-dump' \
|| true


if echo "$RECENT" | \
grep -qiE \
'PF_precache_sound_I_internal|over the 512 limit'
then

    echo
    echo "[ERROR] 512 limit is still present"

    echo "$RECENT" | \
    grep -iE \
    'precache|512 limit|fatal' | \
    tail -n 40

    exit 2
fi


if ! systemctl is-active \
    --quiet \
    "hyper-cs16@${SID}.service"
then

    echo
    echo "[ERROR] server exited"

    journalctl \
        -u "hyper-cs16@${SID}.service" \
        -n 120 \
        --no-pager \
        || true

    exit 3
fi


echo "[5/5] Verify runtime..."

echo
echo "--- META LIST ---"

"$LIVE" rcon "$SID" "meta list" || true


echo
echo "--- AMXX PLUGINS ---"

"$LIVE" rcon "$SID" "amxx plugins" || true


echo
echo "================================================================"
echo " [SUCCESS] OLD ZOMBIE v30"
echo "================================================================"
echo " Server: ACTIVE"
echo " All AMXX plugins: UNCHANGED"
echo " Ultimate Unprecacher: ACTIVE"
echo " list.ini syntax: FIXED"
echo " FastDL/nginx/site: NOT MODIFIED"
echo " Backup: $BACKUP"
echo "================================================================"