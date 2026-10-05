cat > /tmp/apply-cs16-ftp-write-fix-v2.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
ROOT="/srv/hyper-cs16/servers/${SID}"
CFG="/var/lib/hyper-cs16/servers/${SID}.json"
TARGET="${ROOT}/cstrike/addons/amxmodx/plugins"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/root/hyper-cs16-ftp-write-fix-v2-${SID}-${STAMP}.log"

exec > >(tee -a "$LOG") 2>&1

echo "================================================================"
echo " HYPER-HOST CS16 FTP WRITE FIX v2"
echo " Server: #${SID}"
echo " Root:   ${ROOT}"
echo "================================================================"

[[ "$EUID" -eq 0 ]] || { echo "[ERROR] Run as root."; exit 1; }
[[ -d "$ROOT" ]] || { echo "[ERROR] Missing $ROOT"; exit 2; }
[[ -f "$CFG" ]] || { echo "[ERROR] Missing $CFG"; exit 3; }

echo "[1/8] Normalize server permissions..."
chown -R cs16:www-data "$ROOT"
find "$ROOT" -type d -exec chmod 2775 {} +
find "$ROOT" -type f -exec chmod 0664 {} +

for f in hlds_run hlds_linux hltv; do
  [[ -e "$ROOT/$f" ]] && chmod 0775 "$ROOT/$f" || true
done

find "$ROOT" -type f \( -name '*.so' -o -name '*.sh' \) -exec chmod 0775 {} + 2>/dev/null || true

mkdir -p "$TARGET"
chown cs16:www-data "$TARGET"
chmod 2775 "$TARGET"

echo "[2/8] ProFTPD write settings..."
mkdir -p /etc/proftpd/conf.d

cat > /etc/proftpd/conf.d/99-hyper-cs16-write.conf <<'PROFTPD'
<Global>
  AllowOverwrite on
  AllowStoreRestart on
  Umask 002 002
  ListOptions "-a"
</Global>
PROFTPD

proftpd -t
systemctl restart proftpd
sleep 2

echo "[3/8] Verify filesystem write using both likely identities..."

for u in www-data cs16; do
  if id "$u" >/dev/null 2>&1; then
    f="$TARGET/hyper_fs_test_${u}"

    if runuser -u "$u" -- bash -c "printf 'ok\n' > '$f'"; then
      echo "[OK] filesystem write as $u"
      rm -f "$f"
    else
      echo "[FAIL] filesystem write as $u"
    fi
  fi
done

echo "[4/8] Real FTP STOR test with VISIBLE filename..."

python3 - "$CFG" "$ROOT" <<'PY'
import ftplib
import io
import json
import os
import sys
import time

cfg = json.load(open(sys.argv[1], encoding="utf-8"))
root = sys.argv[2]

user = str(cfg.get("ftp_user") or "")
pw = str(cfg.get("ftp_password") or "")

if not user or not pw:
    raise SystemExit("[ERROR] FTP credentials missing")

remote_dir = "/cstrike/addons/amxmodx/plugins"
local_dir = os.path.join(root, "cstrike/addons/amxmodx/plugins")

def test(passive):
    mode = "PASV" if passive else "ACTIVE"
    name = f"hyper_ftp_stor_test_{mode.lower()}.txt"
    local = os.path.join(local_dir, name)

    try:
        os.unlink(local)
    except FileNotFoundError:
        pass

    ftp = ftplib.FTP()
    ftp.connect("127.0.0.1", 21, timeout=10)
    ftp.login(user, pw)
    ftp.set_pasv(passive)
    ftp.cwd(remote_dir)

    payload = b"HYPER FTP WRITE TEST\n"

    resp = ftp.storbinary(
        "STOR " + name,
        io.BytesIO(payload)
    )

    print(f"[{mode}] STOR response: {resp}")

    time.sleep(0.2)

    exists = os.path.isfile(local)
    size = os.path.getsize(local) if exists else -1

    print(f"[{mode}] filesystem: exists={exists} size={size}")

    names = ftp.nlst()

    print(f"[{mode}] NLST contains test file: {name in names}")

    if not exists or size != len(payload):
        raise RuntimeError(
            f"{mode}: STOR completed but file not found at {local}"
        )

    ftp.delete(name)
    ftp.quit()

    if os.path.exists(local):
        os.unlink(local)

    print(f"[OK] Local FTP {mode} STOR/DELETE works")

for passive in (False, True):
    test(passive)
PY

echo "[5/8] Show effective ProFTPD restrictions..."

grep -RniE '^(.*)(PassivePorts|MasqueradeAddress|AllowOverwrite|AllowStoreRestart|DefaultRoot|DefaultChdir)|<Limit|DenyAll|AllowAll' \
  /etc/proftpd 2>/dev/null | tail -n 160 || true

echo "[6/8] Show ProFTPD listening sockets..."

ss -lntp | grep -E '(:21[[:space:]]|proftpd)' || true

echo "[7/8] Recent transfer log..."

tail -n 80 /var/log/proftpd/proftpd.log 2>/dev/null || true
tail -n 80 /var/log/proftpd/xferlog 2>/dev/null || true

echo "[8/8] Final permissions..."

namei -l "$TARGET" || true
ls -ld "$TARGET"

find "$TARGET" -maxdepth 1 -type f \
  -printf '%M %u:%g %f\n' | head -n 30 || true

echo
echo "================================================================"
echo " [SUCCESS] LOCAL FTP UPLOAD IS WORKING"
echo "================================================================"
echo
echo "Both ACTIVE and PASV STOR were tested with a normal visible filename."
echo
echo "If FileZilla still fails after this:"
echo "  1. Open FileZilla -> View -> Message log"
echo "  2. Upload ONE small .txt file"
echo "  3. Copy the lines from 'STOR filename' through the error."
echo
echo "Log: $LOG"
EOF