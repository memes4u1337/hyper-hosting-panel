#!/usr/bin/env bash
set -Eeuo pipefail

SID="${1:-25}"
ROOT="/srv/hyper-cs16/servers/${SID}"
CFG="/var/lib/hyper-cs16/servers/${SID}.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/root/hyper-cs16-ftp-write-fix-${SID}-${STAMP}.log"

exec > >(tee -a "$LOG") 2>&1

echo "================================================================"
echo " HYPER-HOST CS16 FTP WRITE FIX v1"
echo " Server: #${SID}"
echo " Root:   ${ROOT}"
echo " Log:    ${LOG}"
echo "================================================================"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] Run as root."
  exit 1
fi

if [[ ! -d "$ROOT" ]]; then
  echo "[ERROR] Server root not found: $ROOT"
  exit 2
fi

echo "[1/7] Fixing ownership and recursive write permissions..."
chown -R cs16:www-data "$ROOT"

# Directories: owner/group rwx + setgid, others rx
find "$ROOT" -type d -exec chmod 2775 {} +

# Regular files: owner/group rw, others r
find "$ROOT" -type f -exec chmod 0664 {} +

# Runtime executables
for f in hlds_run hlds_linux hltv; do
  [[ -e "$ROOT/$f" ]] && chmod 0775 "$ROOT/$f" || true
done

# Shared objects and scripts that need execute bit
find "$ROOT" -type f \( -name '*.so' -o -name '*.sh' \) -exec chmod 0775 {} + 2>/dev/null || true

echo "[2/7] Checking target directory permissions..."
TARGET="$ROOT/cstrike/addons/amxmodx/plugins"
mkdir -p "$TARGET"
chown cs16:www-data "$TARGET"
chmod 2775 "$TARGET"

namei -l "$TARGET" || true
ls -ld "$ROOT" "$ROOT/cstrike" "$ROOT/cstrike/addons" "$ROOT/cstrike/addons/amxmodx" "$TARGET"

echo "[3/7] Testing direct write as www-data..."
TEST_DIRECT="$TARGET/.hyper-direct-write-test"
runuser -u www-data -- bash -c "printf 'ok\n' > '$TEST_DIRECT'"
if [[ ! -f "$TEST_DIRECT" ]]; then
  echo "[ERROR] www-data still cannot create files in $TARGET"
  exit 10
fi
rm -f "$TEST_DIRECT"
echo "[OK] Direct filesystem write as www-data works."

echo "[4/7] Ensuring ProFTPD permits STOR/overwrite..."
mkdir -p /etc/proftpd/conf.d
cat > /etc/proftpd/conf.d/99-hyper-cs16-write.conf <<'EOF'
<Global>
  AllowOverwrite on
  AllowStoreRestart on
  Umask 002 002
</Global>
EOF

if command -v proftpd >/dev/null 2>&1; then
  proftpd -t
fi
systemctl restart proftpd
sleep 2

echo "[5/7] Running real LOCAL FTP STOR test..."
if [[ ! -f "$CFG" ]]; then
  echo "[ERROR] Server config not found: $CFG"
  exit 11
fi

python3 - "$CFG" <<'PY'
import ftplib, io, json, sys

cfg=json.load(open(sys.argv[1],encoding="utf-8"))
user=str(cfg.get("ftp_user") or "")
pw=str(cfg.get("ftp_password") or "")
if not user or not pw:
    raise SystemExit("[ERROR] FTP credentials missing in server config")

def test(passive):
    ftp=ftplib.FTP()
    ftp.connect("127.0.0.1",21,timeout=10)
    ftp.login(user,pw)
    ftp.set_pasv(passive)
    ftp.cwd("/cstrike/addons/amxmodx/plugins")
    name=".hyper-ftp-stor-test-pasv" if passive else ".hyper-ftp-stor-test-active"
    data=io.BytesIO(b"HYPER FTP WRITE OK\n")
    resp=ftp.storbinary("STOR "+name,data)
    names=ftp.nlst()
    if name not in names:
        raise RuntimeError("STOR returned but uploaded file is not visible")
    ftp.delete(name)
    ftp.quit()
    return resp

for passive in (False, True):
    mode="PASV" if passive else "ACTIVE"
    try:
        r=test(passive)
        print(f"[OK] Local FTP {mode} STOR works: {r}")
    except Exception as exc:
        print(f"[FAIL] Local FTP {mode} STOR failed: {exc}")
        raise
PY

echo "[6/7] Checking ProFTPD write restrictions..."
grep -RniE 'DenyAll|AllowOverwrite|<Limit[[:space:]]+(WRITE|STOR)|PassivePorts|MasqueradeAddress' \
  /etc/proftpd 2>/dev/null | tail -n 100 || true

echo "[7/7] Final FileZilla-ready permissions..."
ls -ld "$TARGET"
find "$TARGET" -maxdepth 1 -type f -printf '%M %u:%g %f\n' | head -n 20 || true

echo
echo "================================================================"
echo " [SUCCESS] FTP WRITE PATH WORKS LOCALLY"
echo "================================================================"
echo "The FTP account can perform a real STOR upload on this server."
echo
echo "If FileZilla STILL fails while this script ends with SUCCESS,"
echo "the remaining issue is external FTP data-channel/NAT/firewall."
echo "Copy the red FileZilla log lines containing 425/426/450/550 and we can"
echo "identify that layer immediately."
echo
echo "Log: $LOG"
