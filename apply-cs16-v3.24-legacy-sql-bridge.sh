#!/usr/bin/env bash
set -Eeuo pipefail

# HYPER-HOST CS16 v3.24 — LEGACY SQL BRIDGE
# FreshBans/Admin Loader -> per-server HYPER-HOST MariaDB database.
# Existing server SQL is kept; no database/table is dropped.

SID="${1:-24}"
LIVE_CTL="${HYPER_CTL:-/usr/local/sbin/hyper-cs16-ctl}"
REPO="${HYPER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_CTL="$REPO/cs16-panel/bin/hyper-cs16-ctl"
DOMAIN="www.avito.hyper-host.pw"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hyper-cs16-v3.24-backup-${STAMP}"
LOG="/root/hyper-cs16-v3.24-${STAMP}.log"
PATCHER="$(mktemp /tmp/hh-v324.XXXXXX.py)"
ROOTS="$(mktemp /tmp/hh-v324-roots.XXXXXX)"
NGTMP="$(mktemp /tmp/hh-v324-nginx.XXXXXX)"
SQL_OUT="$(mktemp /tmp/hh-v324-sql.XXXXXX.json)"
SQL_STATUS="$(mktemp /tmp/hh-v324-status.XXXXXX.json)"

mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

cleanup() { rm -f "$PATCHER" "$ROOTS" "$NGTMP" "$SQL_OUT" "$SQL_STATUS" 2>/dev/null || true; }
trap cleanup EXIT

die() {
  echo
  echo "[ERROR] $*"
  echo "[ERROR] Log: $LOG"
  echo "[ERROR] Backup: $BACKUP"
  exit 1
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local safe
  safe="$(printf '%s' "$f" | sed 's#^/##;s#/#__#g')"
  cp -a "$f" "$BACKUP/$safe"
}

printf '%s' 'ZnJvbSBfX2Z1dHVyZV9fIGltcG9ydCBhbm5vdGF0aW9ucwoKaW1wb3J0IGFzdAppbXBvcnQgb3MKaW1wb3J0IHB5X2NvbXBpbGUKaW1wb3J0IHJlCmltcG9ydCBzeXMKZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCgpDVExfTUFSS0VSID0gJyMgPj4+IEhZUEVSLUhPU1QgdjMuMjQgTEVHQUNZIFNRTCBCUklER0UgPj4+JwoKSEVMUEVSID0gciIiIgojID4+PiBIWVBFUi1IT1NUIHYzLjI0IExFR0FDWSBTUUwgQlJJREdFID4+PgpkZWYgX3YzMjRfY2ZnX3RleHQocGF0aDpQYXRoKToKICAgIGRhdGE9cGF0aC5yZWFkX2J5dGVzKCkgaWYgcGF0aC5pc19maWxlKCkgZWxzZSBiJycKICAgIGZvciBlbmMgaW4gKCd1dGYtOCcsJ2NwMTI1MScsJ2xhdGluMScpOgogICAgICAgIHRyeToKICAgICAgICAgICAgcmV0dXJuIGRhdGEuZGVjb2RlKGVuYyksZW5jCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcGFzcwogICAgcmV0dXJuIGRhdGEuZGVjb2RlKCdsYXRpbjEnLCdpZ25vcmUnKSwnbGF0aW4xJwoKCmRlZiBfdjMyNF9jZmdfZ2V0KHBhdGg6UGF0aCxrZXk6c3RyLGRlZmF1bHQ6c3RyPScnKS0+c3RyOgogICAgaWYgbm90IHBhdGguaXNfZmlsZSgpOiByZXR1cm4gZGVmYXVsdAogICAgdGV4dCxfPV92MzI0X2NmZ190ZXh0KHBhdGgpCiAgICByeD1yZS5jb21waWxlKHInKD9pbSleXHMqJytyZS5lc2NhcGUoa2V5KStyJ1xzKyg/OiIoW14iXSopInwoW15cczsvXSspKScpCiAgICBtPXJ4LnNlYXJjaCh0ZXh0KQogICAgaWYgbm90IG06IHJldHVybiBkZWZhdWx0CiAgICByZXR1cm4gc3RyKG0uZ3JvdXAoMSkgaWYgbS5ncm91cCgxKSBpcyBub3QgTm9uZSBlbHNlIChtLmdyb3VwKDIpIG9yICcnKSkuc3RyaXAoKQoKCmRlZiBfdjMyNF9jZmdfc2V0KHBhdGg6UGF0aCxrZXk6c3RyLHZhbHVlOnN0cik6CiAgICBwYXRoLnBhcmVudC5ta2RpcihwYXJlbnRzPVRydWUsZXhpc3Rfb2s9VHJ1ZSkKICAgIHRleHQsZW5jPV92MzI0X2NmZ190ZXh0KHBhdGgpCiAgICB2YWx1ZT1zdHIodmFsdWUpLnJlcGxhY2UoJ1xcJywnLycpLnJlcGxhY2UoJyInLCInIikucmVwbGFjZSgnXHInLCcgJykucmVwbGFjZSgnXG4nLCcgJykKICAgIG5ld2xpbmU9J1xyXG4nIGlmICdcclxuJyBpbiB0ZXh0IGVsc2UgJ1xuJwogICAgbGluZXM9dGV4dC5yZXBsYWNlKCdcclxuJywnXG4nKS5yZXBsYWNlKCdccicsJ1xuJykuc3BsaXQoJ1xuJykKICAgIHJ4PXJlLmNvbXBpbGUocideXHMqJytyZS5lc2NhcGUoa2V5KStyJ1xiJyxyZS5JKQogICAgY2hhbmdlZD1GYWxzZQogICAgb3V0PVtdCiAgICBmb3IgbGluZSBpbiBsaW5lczoKICAgICAgICBzdD1saW5lLmxzdHJpcCgpCiAgICAgICAgYWN0aXZlPWJvb2woc3QgYW5kIG5vdCBzdC5zdGFydHN3aXRoKCgnOycsJy8vJywnIycpKSkKICAgICAgICBpZiBhY3RpdmUgYW5kIHJ4Lm1hdGNoKGxpbmUpOgogICAgICAgICAgICBpZiBub3QgY2hhbmdlZDoKICAgICAgICAgICAgICAgIG91dC5hcHBlbmQoZid7a2V5fSAie3ZhbHVlfSInKQogICAgICAgICAgICAgICAgY2hhbmdlZD1UcnVlCiAgICAgICAgICAgIGVsc2U6CiAgICAgICAgICAgICAgICBvdXQuYXBwZW5kKCc7IEhZUEVSLUhPU1QgdjMuMjQgZHVwbGljYXRlIGRpc2FibGVkOiAnK2xpbmUpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgb3V0LmFwcGVuZChsaW5lKQogICAgaWYgbm90IGNoYW5nZWQ6CiAgICAgICAgb3V0LmFwcGVuZChmJ3trZXl9ICJ7dmFsdWV9IicpCiAgICBwYXlsb2FkPW5ld2xpbmUuam9pbihvdXQpLnJzdHJpcCgpK25ld2xpbmUKICAgIHRyeToKICAgICAgICBwYXRoLndyaXRlX2J5dGVzKHBheWxvYWQuZW5jb2RlKGVuYykpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHBhdGgud3JpdGVfdGV4dChwYXlsb2FkLGVuY29kaW5nPSd1dGYtOCcpCgoKZGVmIF92MzI0X3NxbF9pZGVudCh2YWx1ZTpzdHIsZGVmYXVsdDpzdHIpLT5zdHI6CiAgICB2PXN0cih2YWx1ZSBvciAnJykuc3RyaXAoKQogICAgcmV0dXJuIHYgaWYgcmUuZnVsbG1hdGNoKHInW0EtWmEtejAtOV9dezEsNjR9Jyx2KSBlbHNlIGRlZmF1bHQKCgpkZWYgX3YzMjRfdXNlcnNfYmFja3VwKHBhdGg6UGF0aCktPmxpc3RbZGljdF06CiAgICBpZiBub3QgcGF0aC5pc19maWxlKCk6IHJldHVybiBbXQogICAgdGV4dCxfPV92MzI0X2NmZ190ZXh0KHBhdGgpCiAgICBvdXQ9W10KICAgIHJ4PXJlLmNvbXBpbGUocideXHMqIihbXiJdKikiXHMrIihbXiJdKikiXHMrIihbXiJdKikiXHMrIihbXiJdKikiKD86XHMrIihbXiJdKikiKT8oPzpccysiKFteIl0qKSIpPycpCiAgICBmb3IgcmF3IGluIHRleHQuc3BsaXRsaW5lcygpOgogICAgICAgIHN0PXJhdy5zdHJpcCgpCiAgICAgICAgaWYgbm90IHN0IG9yIHN0LnN0YXJ0c3dpdGgoKCc7JywnLy8nLCcjJykpOiBjb250aW51ZQogICAgICAgIG09cngubWF0Y2gocmF3KQogICAgICAgIGlmIG5vdCBtOiBjb250aW51ZQogICAgICAgIGF1dGgscGFzc3dvcmQsYWNjZXNzLGZsYWdzLG5pY2tuYW1lLGV4cGlyZWQ9bS5ncm91cHMoKQogICAgICAgIGlmIG5vdCBhdXRoOiBjb250aW51ZQogICAgICAgIGV4cD0wCiAgICAgICAgZT1zdHIoZXhwaXJlZCBvciAnJykuc3RyaXAoKS5sb3dlcigpCiAgICAgICAgaWYgZSBhbmQgZSBub3QgaW4gKCdsaWZldGltZScsJ2ZvcmV2ZXInLCduZXZlcicsJzAnKToKICAgICAgICAgICAgdHJ5OiBleHA9aW50KGUpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246IGV4cD0wCiAgICAgICAgb3V0LmFwcGVuZCh7CiAgICAgICAgICAgICdhdXRoJzphdXRoWzo2NF0sICdwYXNzd29yZCc6cGFzc3dvcmRbOjEyOF0sICdhY2Nlc3MnOmFjY2Vzc1s6NjRdLAogICAgICAgICAgICAnZmxhZ3MnOmZsYWdzWzo2NF0sICduaWNrbmFtZSc6KG5pY2tuYW1lIG9yIGF1dGgpWzo2NF0sICdleHBpcmVkJzpleHAsCiAgICAgICAgfSkKICAgIHJldHVybiBvdXQKCgpkZWYgX3YzMjRfd2lyZV9sZWdhY3lfc3FsKGM6ZGljdCxkYl9uYW1lOnN0cixkYl91c2VyOnN0cixkYl9wYXNzd29yZDpzdHIpLT5kaWN0OgogICAgcm9vdD1QYXRoKGNbJ3BhdGgnXSk7IGNzdHJpa2U9cm9vdC8nY3N0cmlrZSc7IGNmZ2Rpcj1jc3RyaWtlLydhZGRvbnMvYW14bW9keC9jb25maWdzJwogICAgZmI9Y2ZnZGlyLydmYi9tYWluLmNmZycKICAgIHVzZXJzPWNmZ2Rpci8ndXNlcnMuaW5pJwogICAgaWYgbm90IGZiLmlzX2ZpbGUoKToKICAgICAgICByZXR1cm4geydkZXRlY3RlZCc6RmFsc2UsJ3dpcmVkJzpGYWxzZSwna2luZCc6J3N0YW5kYXJkLWFteHgnLCd0YWJsZXMnOltdLCdtaWdyYXRlZF9hZG1pbnMnOjB9CgogICAgIyBLZWVwIHRoZSBhc3NlbWJseSdzIHRhYmxlIHByZWZpeCB3aGVuIGl0IGlzIHNhbmUuIEFkbWluIExvYWRlciBkZXJpdmVzCiAgICAjIGdtL2FteCBwcmVmaXggZnJvbSBmYl9zZXJ2ZXJzX3RhYmxlLCBzbyBhbGwgcmVsYXRlZCB0YWJsZXMgbXVzdCBtYXRjaCBpdC4KICAgIG9sZF9zZXJ2ZXJfdGFibGU9X3YzMjRfY2ZnX2dldChmYiwnZmJfc2VydmVyc190YWJsZScsJ2dtX3NlcnZlcmluZm8nKQogICAgc2VydmVyX3RhYmxlPV92MzI0X3NxbF9pZGVudChvbGRfc2VydmVyX3RhYmxlLCdnbV9zZXJ2ZXJpbmZvJykKICAgIGlmIHNlcnZlcl90YWJsZS5lbmRzd2l0aCgnX3NlcnZlcmluZm8nKToKICAgICAgICBwcmVmaXg9c2VydmVyX3RhYmxlWzotbGVuKCdfc2VydmVyaW5mbycpXQogICAgZWxzZToKICAgICAgICBwcmVmaXg9J2dtJzsgc2VydmVyX3RhYmxlPSdnbV9zZXJ2ZXJpbmZvJwogICAgcHJlZml4PV92MzI0X3NxbF9pZGVudChwcmVmaXgsJ2dtJykKICAgIGJhbnNfdGFibGU9X3YzMjRfc3FsX2lkZW50KF92MzI0X2NmZ19nZXQoZmIsJ2ZiX3NxbF90YWJsZScscHJlZml4KydfYmFucycpLHByZWZpeCsnX2JhbnMnKQogICAgbG9nc190YWJsZT1fdjMyNF9zcWxfaWRlbnQoX3YzMjRfY2ZnX2dldChmYiwnZmJfc3FsX2xvZ190YWJsZScscHJlZml4KydfbG9ncycpLHByZWZpeCsnX2xvZ3MnKQogICAgYWRtaW5zX3RhYmxlPXByZWZpeCsnX2FteGFkbWlucyc7IGxpbmtzX3RhYmxlPXByZWZpeCsnX2FkbWluc19zZXJ2ZXJzJwoKICAgIHB1YmxpY19pcD1zdHIoYy5nZXQoJ3B1YmxpY19pcCcpIG9yICcnKS5zdHJpcCgpCiAgICBpZiBub3QgcHVibGljX2lwOgogICAgICAgIHRyeTogcHVibGljX2lwPXN0cihsb2FkX3J1bnRpbWUoKS5nZXQoJ3B1YmxpY19pcCcpIG9yICcnKS5zdHJpcCgpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjogcHVibGljX2lwPScnCiAgICBpZiBub3QgcHVibGljX2lwOiBwdWJsaWNfaXA9JzEyNy4wLjAuMScKICAgIHBvcnQ9aW50KGMuZ2V0KCdwb3J0Jykgb3IgMjcwMTUpCiAgICBhZGRyZXNzPWYne3B1YmxpY19pcH06e3BvcnR9JwogICAgc2VydmVyX25hbWU9c3RyKGMuZ2V0KCdob3N0bmFtZScpIG9yIGMuZ2V0KCduYW1lJykgb3IgZidDUyAxLjYgI3tjLmdldCgiaWQiLCIiKX0nKVs6MTAwXQoKICAgIHRyeToKICAgICAgICBpbXBvcnQgcHlteXNxbAogICAgICAgIGNvbj1weW15c3FsLmNvbm5lY3QoaG9zdD0nMTI3LjAuMC4xJyxwb3J0PTMzMDYsdXNlcj1kYl91c2VyLHBhc3N3b3JkPWRiX3Bhc3N3b3JkLGRhdGFiYXNlPWRiX25hbWUsCiAgICAgICAgICAgIGNoYXJzZXQ9J3V0ZjhtYjQnLGF1dG9jb21taXQ9VHJ1ZSxjdXJzb3JjbGFzcz1weW15c3FsLmN1cnNvcnMuRGljdEN1cnNvcixjb25uZWN0X3RpbWVvdXQ9NSkKICAgICAgICB0cnk6CiAgICAgICAgICAgIHdpdGggY29uLmN1cnNvcigpIGFzIGN1cjoKICAgICAgICAgICAgICAgICMgRXNzZW50aWFsIEFNWEJhbnMgR00vRnJlc2hCYW5zIHNjaGVtYS4gRGVmaW5pdGlvbnMgbWlycm9yIHRoZQogICAgICAgICAgICAgICAgIyB0YWJsZSBjb250cmFjdCBleHBlY3RlZCBieSBGcmVzaEJhbnMgKyBuZXlnb21vbiBBZG1pbiBMb2FkZXIuCiAgICAgICAgICAgICAgICBjdXIuZXhlY3V0ZShmJycnQ1JFQVRFIFRBQkxFIElGIE5PVCBFWElTVFMgYHtsaW5rc190YWJsZX1gICgKICAgICAgICAgICAgICAgICAgICBgYWRtaW5faWRgIGludCgxMSkgTlVMTCwKICAgICAgICAgICAgICAgICAgICBgc2VydmVyX2lkYCBpbnQoMTEpIE5VTEwsCiAgICAgICAgICAgICAgICAgICAgYGN1c3RvbV9mbGFnc2AgdmFyY2hhcigzMikgTk9UIE5VTEwgREVGQVVMVCAnJywKICAgICAgICAgICAgICAgICAgICBgdXNlX3N0YXRpY19iYW50aW1lYCBlbnVtKCd5ZXMnLCdubycpIE5PVCBOVUxMIERFRkFVTFQgJ3llcycsCiAgICAgICAgICAgICAgICAgICAgS0VZIGBhZG1pbl9pZGAgKGBhZG1pbl9pZGApLCBLRVkgYHNlcnZlcl9pZGAgKGBzZXJ2ZXJfaWRgKQogICAgICAgICAgICAgICAgKSBFTkdJTkU9SW5ub0RCIERFRkFVTFQgQ0hBUlNFVD11dGY4bWI0IENPTExBVEU9dXRmOG1iNF91bmljb2RlX2NpJycnKQogICAgICAgICAgICAgICAgY3VyLmV4ZWN1dGUoZicnJ0NSRUFURSBUQUJMRSBJRiBOT1QgRVhJU1RTIGB7YWRtaW5zX3RhYmxlfWAgKAogICAgICAgICAgICAgICAgICAgIGBpZGAgaW50KDEyKSBOT1QgTlVMTCBBVVRPX0lOQ1JFTUVOVCwKICAgICAgICAgICAgICAgICAgICBgdXNlcm5hbWVgIHZhcmNoYXIoMzIpIE5VTEwsCiAgICAgICAgICAgICAgICAgICAgYHBhc3N3b3JkYCB2YXJjaGFyKDUwKSBOVUxMLAogICAgICAgICAgICAgICAgICAgIGBhY2Nlc3NgIHZhcmNoYXIoMzIpIE5VTEwsCiAgICAgICAgICAgICAgICAgICAgYGZsYWdzYCB2YXJjaGFyKDMyKSBOVUxMLAogICAgICAgICAgICAgICAgICAgIGBzdGVhbWlkYCB2YXJjaGFyKDMyKSBOVUxMLAogICAgICAgICAgICAgICAgICAgIGBuaWNrbmFtZWAgdmFyY2hhcigzMikgTlVMTCwKICAgICAgICAgICAgICAgICAgICBgaWNxYCBpbnQoOSkgTlVMTCwKICAgICAgICAgICAgICAgICAgICBgYXNob3dgIGludCgxMSkgTlVMTCwKICAgICAgICAgICAgICAgICAgICBgY3JlYXRlZGAgaW50KDExKSBOVUxMLAogICAgICAgICAgICAgICAgICAgIGBleHBpcmVkYCBpbnQoMTEpIE5VTEwsCiAgICAgICAgICAgICAgICAgICAgYGRheXNgIGludCgxMSkgTlVMTCwKICAgICAgICAgICAgICAgICAgICBQUklNQVJZIEtFWSAoYGlkYCksIEtFWSBgc3RlYW1pZGAgKGBzdGVhbWlkYCkKICAgICAgICAgICAgICAgICkgRU5HSU5FPUlubm9EQiBERUZBVUxUIENIQVJTRVQ9dXRmOG1iNCBDT0xMQVRFPXV0ZjhtYjRfdW5pY29kZV9jaScnJykKICAgICAgICAgICAgICAgIGN1ci5leGVjdXRlKGYnJydDUkVBVEUgVEFCTEUgSUYgTk9UIEVYSVNUUyBge2JhbnNfdGFibGV9YCAoCiAgICAgICAgICAgICAgICAgICAgYGJpZGAgaW50KDExKSBOT1QgTlVMTCBBVVRPX0lOQ1JFTUVOVCwKICAgICAgICAgICAgICAgICAgICBgcGxheWVyX2lwYCB2YXJjaGFyKDMyKSBOVUxMLAogICAgICAgICAgICAgICAgICAgIGBwbGF5ZXJfaWRgIHZhcmNoYXIoMzUpIE5VTEwsCiAgICAgICAgICAgICAgICAgICAgYHBsYXllcl9uaWNrYCB2YXJjaGFyKDEwMCkgTlVMTCBERUZBVUxUICdVbmtub3duJywKICAgICAgICAgICAgICAgICAgICBgYWRtaW5faXBgIHZhcmNoYXIoMzIpIE5VTEwsCiAgICAgICAgICAgICAgICAgICAgYGFkbWluX2lkYCB2YXJjaGFyKDM1KSBOVUxMIERFRkFVTFQgJ1Vua25vd24nLAogICAgICAgICAgICAgICAgICAgIGBhZG1pbl9uaWNrYCB2YXJjaGFyKDEwMCkgTlVMTCBERUZBVUxUICdVbmtub3duJywKICAgICAgICAgICAgICAgICAgICBgYmFuX3R5cGVgIHZhcmNoYXIoMTApIE5VTEwgREVGQVVMVCAnUycsCiAgICAgICAgICAgICAgICAgICAgYGJhbl9yZWFzb25gIHZhcmNoYXIoMTAwKSBOVUxMLAogICAgICAgICAgICAgICAgICAgIGBjc19iYW5fcmVhc29uYCB2YXJjaGFyKDEwMCkgTlVMTCwKICAgICAgICAgICAgICAgICAgICBgYmFuX2NyZWF0ZWRgIGludCgxMSkgTlVMTCwKICAgICAgICAgICAgICAgICAgICBgYmFuX2xlbmd0aGAgaW50KDExKSBOVUxMLAogICAgICAgICAgICAgICAgICAgIGBzZXJ2ZXJfaXBgIHZhcmNoYXIoMzIpIE5VTEwsCiAgICAgICAgICAgICAgICAgICAgYHNlcnZlcl9uYW1lYCB2YXJjaGFyKDEwMCkgTlVMTCBERUZBVUxUICdVbmtub3duJywKICAgICAgICAgICAgICAgICAgICBgYmFuX2tpY2tzYCBpbnQoMTEpIE5PVCBOVUxMIERFRkFVTFQgMCwKICAgICAgICAgICAgICAgICAgICBgZXhwaXJlZGAgaW50KDEpIE5PVCBOVUxMIERFRkFVTFQgMCwKICAgICAgICAgICAgICAgICAgICBgaW1wb3J0ZWRgIGludCgxKSBOT1QgTlVMTCBERUZBVUxUIDAsCiAgICAgICAgICAgICAgICAgICAgUFJJTUFSWSBLRVkgKGBiaWRgKSwgS0VZIGBwbGF5ZXJfaWRgIChgcGxheWVyX2lkYCksIEtFWSBgcGxheWVyX2lwYCAoYHBsYXllcl9pcGApLCBLRVkgYGV4cGlyZWRgIChgZXhwaXJlZGApCiAgICAgICAgICAgICAgICApIEVOR0lORT1Jbm5vREIgREVGQVVMVCBDSEFSU0VUPXV0ZjhtYjQgQ09MTEFURT11dGY4bWI0X3VuaWNvZGVfY2knJycpCiAgICAgICAgICAgICAgICBjdXIuZXhlY3V0ZShmJycnQ1JFQVRFIFRBQkxFIElGIE5PVCBFWElTVFMgYHtsb2dzX3RhYmxlfWAgKAogICAgICAgICAgICAgICAgICAgIGBpZGAgaW50KDExKSBOT1QgTlVMTCBBVVRPX0lOQ1JFTUVOVCwKICAgICAgICAgICAgICAgICAgICBgdGltZXN0YW1wYCBpbnQoMTEpIE5VTEwsCiAgICAgICAgICAgICAgICAgICAgYGlwYCB2YXJjaGFyKDMyKSBOVUxMLAogICAgICAgICAgICAgICAgICAgIGB1c2VybmFtZWAgdmFyY2hhcigzMikgTlVMTCwKICAgICAgICAgICAgICAgICAgICBgYWN0aW9uYCB2YXJjaGFyKDY0KSBOVUxMLAogICAgICAgICAgICAgICAgICAgIGByZW1hcmtzYCB2YXJjaGFyKDI1NikgTlVMTCwKICAgICAgICAgICAgICAgICAgICBQUklNQVJZIEtFWSAoYGlkYCkKICAgICAgICAgICAgICAgICkgRU5HSU5FPUlubm9EQiBERUZBVUxUIENIQVJTRVQ9dXRmOG1iNCBDT0xMQVRFPXV0ZjhtYjRfdW5pY29kZV9jaScnJykKICAgICAgICAgICAgICAgIGN1ci5leGVjdXRlKGYnJydDUkVBVEUgVEFCTEUgSUYgTk9UIEVYSVNUUyBge3NlcnZlcl90YWJsZX1gICgKICAgICAgICAgICAgICAgICAgICBgaWRgIGludCgxMSkgTk9UIE5VTEwgQVVUT19JTkNSRU1FTlQsCiAgICAgICAgICAgICAgICAgICAgYHRpbWVzdGFtcGAgaW50KDExKSBOVUxMLAogICAgICAgICAgICAgICAgICAgIGBob3N0bmFtZWAgdmFyY2hhcigxMDApIE5VTEwgREVGQVVMVCAnVW5rbm93bicsCiAgICAgICAgICAgICAgICAgICAgYGFkZHJlc3NgIHZhcmNoYXIoMTAwKSBOVUxMLAogICAgICAgICAgICAgICAgICAgIGBnYW1ldHlwZWAgdmFyY2hhcigzMikgTlVMTCwKICAgICAgICAgICAgICAgICAgICBgcmNvbmAgdmFyY2hhcigzMikgTlVMTCwKICAgICAgICAgICAgICAgICAgICBgYW14YmFuX3ZlcnNpb25gIHZhcmNoYXIoMzIpIE5VTEwsCiAgICAgICAgICAgICAgICAgICAgYGFteGJhbl9tb3RkYCB2YXJjaGFyKDI1MCkgTlVMTCwKICAgICAgICAgICAgICAgICAgICBgbW90ZF9kZWxheWAgaW50KDEwKSBOVUxMIERFRkFVTFQgMTAsCiAgICAgICAgICAgICAgICAgICAgYGFteGJhbl9tZW51YCBpbnQoMTApIE5PVCBOVUxMIERFRkFVTFQgMSwKICAgICAgICAgICAgICAgICAgICBgcmVhc29uc2AgaW50KDEwKSBOVUxMLAogICAgICAgICAgICAgICAgICAgIGB0aW1lem9uZV9maXh4YCBpbnQoMTEpIE5PVCBOVUxMIERFRkFVTFQgMCwKICAgICAgICAgICAgICAgICAgICBQUklNQVJZIEtFWSAoYGlkYCksIEtFWSBgYWRkcmVzc2AgKGBhZGRyZXNzYCkKICAgICAgICAgICAgICAgICkgRU5HSU5FPUlubm9EQiBERUZBVUxUIENIQVJTRVQ9dXRmOG1iNCBDT0xMQVRFPXV0ZjhtYjRfdW5pY29kZV9jaScnJykKCiAgICAgICAgICAgICAgICBjdXIuZXhlY3V0ZShmJ1NFTEVDVCBgaWRgIEZST00gYHtzZXJ2ZXJfdGFibGV9YCBXSEVSRSBgYWRkcmVzc2A9JXMgT1JERVIgQlkgYGlkYCBMSU1JVCAxJywoYWRkcmVzcywpKQogICAgICAgICAgICAgICAgcm93PWN1ci5mZXRjaG9uZSgpCiAgICAgICAgICAgICAgICBpZiByb3c6CiAgICAgICAgICAgICAgICAgICAgc2VydmVyX2lkPWludChyb3dbJ2lkJ10pCiAgICAgICAgICAgICAgICAgICAgY3VyLmV4ZWN1dGUoZicnJ1VQREFURSBge3NlcnZlcl90YWJsZX1gIFNFVCBgdGltZXN0YW1wYD1VTklYX1RJTUVTVEFNUCgpLGBob3N0bmFtZWA9JXMsCiAgICAgICAgICAgICAgICAgICAgICAgIGBnYW1ldHlwZWA9J2NzdHJpa2UnIFdIRVJFIGBpZGA9JXMnJycsKHNlcnZlcl9uYW1lLHNlcnZlcl9pZCkpCiAgICAgICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgICAgIGN1ci5leGVjdXRlKGYnJydJTlNFUlQgSU5UTyBge3NlcnZlcl90YWJsZX1gIChgdGltZXN0YW1wYCxgaG9zdG5hbWVgLGBhZGRyZXNzYCxgZ2FtZXR5cGVgLGByY29uYCxgYW14YmFuX3ZlcnNpb25gLGBtb3RkX2RlbGF5YCxgYW14YmFuX21lbnVgLGB0aW1lem9uZV9maXh4YCkKICAgICAgICAgICAgICAgICAgICAgICAgVkFMVUVTKFVOSVhfVElNRVNUQU1QKCksJXMsJXMsJ2NzdHJpa2UnLCcnLCdGcmVzaEJhbnMnLDEwLDEsMCknJycsKHNlcnZlcl9uYW1lLGFkZHJlc3MpKQogICAgICAgICAgICAgICAgICAgIHNlcnZlcl9pZD1pbnQoY3VyLmxhc3Ryb3dpZCkKCiAgICAgICAgICAgICAgICBtaWdyYXRlZD0wCiAgICAgICAgICAgICAgICBmb3IgYSBpbiBfdjMyNF91c2Vyc19iYWNrdXAodXNlcnMpOgogICAgICAgICAgICAgICAgICAgIGN1ci5leGVjdXRlKGYnJydTRUxFQ1QgYGlkYCBGUk9NIGB7YWRtaW5zX3RhYmxlfWAgV0hFUkUgKGBzdGVhbWlkYD0lcyBPUiBgdXNlcm5hbWVgPSVzIE9SIGBuaWNrbmFtZWA9JXMpIE9SREVSIEJZIGBpZGAgTElNSVQgMScnJywKICAgICAgICAgICAgICAgICAgICAgICAgKGFbJ2F1dGgnXSxhWydhdXRoJ10sYVsnbmlja25hbWUnXSkpCiAgICAgICAgICAgICAgICAgICAgYXI9Y3VyLmZldGNob25lKCkKICAgICAgICAgICAgICAgICAgICBpZiBhcjoKICAgICAgICAgICAgICAgICAgICAgICAgYWRtaW5faWQ9aW50KGFyWydpZCddKQogICAgICAgICAgICAgICAgICAgIGVsc2U6CiAgICAgICAgICAgICAgICAgICAgICAgIGN1ci5leGVjdXRlKGYnJydJTlNFUlQgSU5UTyBge2FkbWluc190YWJsZX1gIChgdXNlcm5hbWVgLGBwYXNzd29yZGAsYGFjY2Vzc2AsYGZsYWdzYCxgc3RlYW1pZGAsYG5pY2tuYW1lYCxgaWNxYCxgYXNob3dgLGBjcmVhdGVkYCxgZXhwaXJlZGAsYGRheXNgKQogICAgICAgICAgICAgICAgICAgICAgICAgICAgVkFMVUVTKCVzLCVzLCVzLCVzLCVzLCVzLDAsMSxVTklYX1RJTUVTVEFNUCgpLCVzLDApJycnLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgKGFbJ2F1dGgnXSxhWydwYXNzd29yZCddLGFbJ2FjY2VzcyddLGFbJ2ZsYWdzJ10sYVsnYXV0aCddLGFbJ25pY2tuYW1lJ10sYVsnZXhwaXJlZCddKSkKICAgICAgICAgICAgICAgICAgICAgICAgYWRtaW5faWQ9aW50KGN1ci5sYXN0cm93aWQpOyBtaWdyYXRlZCs9MQogICAgICAgICAgICAgICAgICAgIGN1ci5leGVjdXRlKGYnJydTRUxFQ1QgMSBGUk9NIGB7bGlua3NfdGFibGV9YCBXSEVSRSBgYWRtaW5faWRgPSVzIEFORCBgc2VydmVyX2lkYD0lcyBMSU1JVCAxJycnLChhZG1pbl9pZCxzZXJ2ZXJfaWQpKQogICAgICAgICAgICAgICAgICAgIGlmIG5vdCBjdXIuZmV0Y2hvbmUoKToKICAgICAgICAgICAgICAgICAgICAgICAgY3VyLmV4ZWN1dGUoZicnJ0lOU0VSVCBJTlRPIGB7bGlua3NfdGFibGV9YCAoYGFkbWluX2lkYCxgc2VydmVyX2lkYCxgY3VzdG9tX2ZsYWdzYCxgdXNlX3N0YXRpY19iYW50aW1lYCkgVkFMVUVTKCVzLCVzLCcnLCd5ZXMnKScnJywoYWRtaW5faWQsc2VydmVyX2lkKSkKCiAgICAgICAgICAgICAgICAjIFZlcmlmeSB0aGUgZXhhY3QgcXVlcnkgY29udHJhY3QgdXNlZCBieSB0aGlzIGFzc2VtYmx5J3MgQWRtaW4gTG9hZGVyLgogICAgICAgICAgICAgICAgY3VyLmV4ZWN1dGUoZicnJ1NFTEVDVCBhLnN0ZWFtaWQsYS5wYXNzd29yZCxhLm5pY2tuYW1lLGEuYWNjZXNzLGEuZmxhZ3MsYS5leHBpcmVkLGIuY3VzdG9tX2ZsYWdzCiAgICAgICAgICAgICAgICAgICAgRlJPTSBge2FkbWluc190YWJsZX1gIEFTIGEsIGB7bGlua3NfdGFibGV9YCBBUyBiCiAgICAgICAgICAgICAgICAgICAgV0hFUkUgYi5hZG1pbl9pZD1hLmlkIEFORCBiLnNlcnZlcl9pZD0oU0VMRUNUIGlkIEZST00gYHtzZXJ2ZXJfdGFibGV9YCBXSEVSRSBhZGRyZXNzPSVzIE9SREVSIEJZIGlkIExJTUlUIDEpCiAgICAgICAgICAgICAgICAgICAgQU5EIChhLmRheXM9JzAnIE9SIGEuZXhwaXJlZD5VTklYX1RJTUVTVEFNUChOT1coKSkpJycnLChhZGRyZXNzLCkpCiAgICAgICAgICAgICAgICBhZG1pbl9yb3dzPWxlbihjdXIuZmV0Y2hhbGwoKSkKICAgICAgICBmaW5hbGx5OgogICAgICAgICAgICBjb24uY2xvc2UoKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCdMZWdhY3kgRnJlc2hCYW5zL0FkbWluIExvYWRlciBTUUwgYnJpZGdlIGZhaWxlZDogJytzdHIoZXhjKSkKCiAgICAjIFJld2lyZSBib3RoIHN0YW5kYXJkIEFNWFggYW5kIHRoZSBhc3NlbWJseS1zcGVjaWZpYyBGcmVzaEJhbnMgY29uZmlnLgogICAgZm9yIGtleSx2YWx1ZSBpbiBbCiAgICAgICAgKCdmYl9zZXJ2ZXJfaXAnLHB1YmxpY19pcCksKCdmYl9zZXJ2ZXJfcG9ydCcsc3RyKHBvcnQpKSwoJ2ZiX3NlcnZlcl9uYW1lJyxzZXJ2ZXJfbmFtZSksCiAgICAgICAgKCdmYl9zcWxfaG9zdCcsJzEyNy4wLjAuMScpLCgnZmJfc3FsX3VzZXInLGRiX3VzZXIpLCgnZmJfc3FsX3Bhc3MnLGRiX3Bhc3N3b3JkKSwoJ2ZiX3NxbF9kYicsZGJfbmFtZSksCiAgICAgICAgKCdmYl9zcWxfdGFibGUnLGJhbnNfdGFibGUpLCgnZmJfc2VydmVyc190YWJsZScsc2VydmVyX3RhYmxlKSwoJ2ZiX3NxbF9sb2dfdGFibGUnLGxvZ3NfdGFibGUpLCgnZmJfdXNlX3NxbCcsJzEnKSwKICAgICAgICAoJ2FteF9wYXNzd29yZF9maWVsZCcsJ19wdycpLCgnYW14X2FteGFkbWluc190YWJsZScsYWRtaW5zX3RhYmxlKSwoJ2FteF9hZG1pbnNfdGFibGUnLGxpbmtzX3RhYmxlKSwKICAgIF06CiAgICAgICAgX3YzMjRfY2ZnX3NldChmYixrZXksdmFsdWUpCgogICAgbWFya2VyPWNmZ2Rpci8naHlwZXJfbGVnYWN5X3NxbC5jZmcnCiAgICBtYXJrZXIud3JpdGVfdGV4dCgKICAgICAgICAnOyBIWVBFUi1IT1NUIHYzLjI0IGxlZ2FjeSBTUUwgYnJpZGdlXG4nCiAgICAgICAgJzsgRnJlc2hCYW5zL0FkbWluIExvYWRlciBhcmUgY29ubmVjdGVkIHRvIHRoZSBkZWRpY2F0ZWQgU1FMIGRhdGFiYXNlIG9mIHRoaXMgZ2FtZSBzZXJ2ZXIuXG4nCiAgICAgICAgZic7IEhvc3Q6IDEyNy4wLjAuMTozMzA2XG47IERhdGFiYXNlOiB7ZGJfbmFtZX1cbjsgVXNlcjoge2RiX3VzZXJ9XG4nCiAgICAgICAgZic7IFNlcnZlciBrZXk6IHthZGRyZXNzfVxuOyBQcmVmaXg6IHtwcmVmaXh9XG4nLGVuY29kaW5nPSd1dGYtOCcpCgogICAgcmV0dXJuIHsKICAgICAgICAnZGV0ZWN0ZWQnOlRydWUsJ3dpcmVkJzpUcnVlLCdraW5kJzonZnJlc2hiYW5zLWFkbWluLWxvYWRlcicsJ3ByZWZpeCc6cHJlZml4LAogICAgICAgICdzZXJ2ZXJfYWRkcmVzcyc6YWRkcmVzcywnc2VydmVyX3RhYmxlJzpzZXJ2ZXJfdGFibGUsJ2JhbnNfdGFibGUnOmJhbnNfdGFibGUsCiAgICAgICAgJ2xvZ3NfdGFibGUnOmxvZ3NfdGFibGUsJ2FkbWluc190YWJsZSc6YWRtaW5zX3RhYmxlLCdhZG1pbnNfc2VydmVyc190YWJsZSc6bGlua3NfdGFibGUsCiAgICAgICAgJ3RhYmxlcyc6W3NlcnZlcl90YWJsZSxiYW5zX3RhYmxlLGxvZ3NfdGFibGUsYWRtaW5zX3RhYmxlLGxpbmtzX3RhYmxlXSwKICAgICAgICAnbWlncmF0ZWRfYWRtaW5zJzptaWdyYXRlZCwnYWN0aXZlX2FkbWluX3Jvd3MnOmFkbWluX3Jvd3MsCiAgICAgICAgJ2NvbmZpZ19wYXRoJzpzdHIoZmIpLAogICAgfQojIDw8PCBIWVBFUi1IT1NUIHYzLjI0IExFR0FDWSBTUUwgQlJJREdFIDw8PAoiIiIKCgpkZWYgX2ZpbmRfZnVuY3Rpb24odHJlZSxuYW1lKToKICAgIGZvciBuIGluIHRyZWUuYm9keToKICAgICAgICBpZiBpc2luc3RhbmNlKG4sKGFzdC5GdW5jdGlvbkRlZixhc3QuQXN5bmNGdW5jdGlvbkRlZikpIGFuZCBuLm5hbWU9PW5hbWU6CiAgICAgICAgICAgIHJldHVybiBuCiAgICByZXR1cm4gTm9uZQoKCmRlZiBfdGFyZ2V0X25hbWUobik6CiAgICBpZiBpc2luc3RhbmNlKG4sYXN0LkFzc2lnbik6CiAgICAgICAgZm9yIHQgaW4gbi50YXJnZXRzOgogICAgICAgICAgICBpZiBpc2luc3RhbmNlKHQsYXN0Lk5hbWUpOiByZXR1cm4gdC5pZAogICAgcmV0dXJuIE5vbmUKCgpkZWYgX3JlcGxhY2VfZnVuYyhzcmMsbm9kZSxuZXcpOgogICAgbGluZXM9c3JjLnNwbGl0bGluZXMoa2VlcGVuZHM9VHJ1ZSkKICAgIGlmIG5vdCBuZXcuZW5kc3dpdGgoJ1xuJyk6IG5ldys9J1xuJwogICAgbGluZXNbbm9kZS5saW5lbm8tMTpub2RlLmVuZF9saW5lbm9dPVtuZXddCiAgICByZXR1cm4gJycuam9pbihsaW5lcykKCgpkZWYgcGF0Y2hfY3RsKHBhdGg6UGF0aCk6CiAgICBzcmM9cGF0aC5yZWFkX3RleHQoZW5jb2Rpbmc9J3V0Zi04JyxlcnJvcnM9J3N1cnJvZ2F0ZWVzY2FwZScpCiAgICBpZiBDVExfTUFSS0VSIG5vdCBpbiBzcmM6CiAgICAgICAgcG9zPXNyYy5maW5kKCdcbmRlZiBzcWxfcHJvdmlzaW9uKCcpCiAgICAgICAgaWYgcG9zPDA6IHJhaXNlIFJ1bnRpbWVFcnJvcignc3FsX3Byb3Zpc2lvbiBub3QgZm91bmQnKQogICAgICAgIHNyYz1zcmNbOnBvc10rJ1xuJytIRUxQRVIrc3JjW3BvczpdCgogICAgdHJlZT1hc3QucGFyc2Uoc3JjKQogICAgZm49X2ZpbmRfZnVuY3Rpb24odHJlZSwnc3FsX3Byb3Zpc2lvbicpCiAgICBpZiBmbiBpcyBOb25lOiByYWlzZSBSdW50aW1lRXJyb3IoJ3NxbF9wcm92aXNpb24gQVNUIG5vdCBmb3VuZCcpCiAgICBmc3JjPScnLmpvaW4oc3JjLnNwbGl0bGluZXMoa2VlcGVuZHM9VHJ1ZSlbZm4ubGluZW5vLTE6Zm4uZW5kX2xpbmVub10pCgogICAgaWYgJ2xlZ2FjeV9zcWw9X3YzMjRfd2lyZV9sZWdhY3lfc3FsJyBub3QgaW4gZnNyYzoKICAgICAgICBsaW5lcz1mc3JjLnNwbGl0bGluZXMoKQogICAgICAgIGlkeD1Ob25lCiAgICAgICAgZm9yIGksbGluZSBpbiBlbnVtZXJhdGUobGluZXMpOgogICAgICAgICAgICBpZiAnY2ZnX3BhdGhfd3JpdHRlbj1fd3JpdGVfYW14eF9zcWxfY2ZnJyBpbiBsaW5lLnJlcGxhY2UoJyAnLCcnKToKICAgICAgICAgICAgICAgIGlkeD1pKzE7IGJyZWFrCiAgICAgICAgaWYgaWR4IGlzIE5vbmU6CiAgICAgICAgICAgICMgd2hpdGVzcGFjZS1pbnNlbnNpdGl2ZSBmYWxsYmFjawogICAgICAgICAgICBmb3IgaSxsaW5lIGluIGVudW1lcmF0ZShsaW5lcyk6CiAgICAgICAgICAgICAgICBpZiAnX3dyaXRlX2FteHhfc3FsX2NmZyhjLGRiX25hbWUsZGJfdXNlcixwYXNzd29yZCknIGluIGxpbmUucmVwbGFjZSgnICcsJycpOgogICAgICAgICAgICAgICAgICAgIGlkeD1pKzE7IGJyZWFrCiAgICAgICAgaWYgaWR4IGlzIE5vbmU6IHJhaXNlIFJ1bnRpbWVFcnJvcignQU1YWCBzcWwuY2ZnIHdpcmluZyBhc3NpZ25tZW50IG5vdCBmb3VuZCcpCiAgICAgICAgbGluZXMuaW5zZXJ0KGlkeCwiICAgICAgICBsZWdhY3lfc3FsPV92MzI0X3dpcmVfbGVnYWN5X3NxbChjLGRiX25hbWUsZGJfdXNlcixwYXNzd29yZCkiKQogICAgICAgICMgUGVyc2lzdCBhIG5vbi1zZWNyZXQgc3VtbWFyeSBpbiB0aGUgc2VydmVyIHN0YXRlLgogICAgICAgIGxpbmVzLmluc2VydChpZHgrMSwiICAgICAgICBjWydsZWdhY3lfc3FsX2JyaWRnZSddPWxlZ2FjeV9zcWwiKQogICAgICAgIGZzcmM9J1xuJy5qb2luKGxpbmVzKSsnXG4nCgogICAgaWYgIidsZWdhY3lfc3FsJzpsZWdhY3lfc3FsIiBub3QgaW4gZnNyYzoKICAgICAgICBmc3JjPWZzcmMucmVwbGFjZSgiJ3N0YW5kYXJkX2FteHhfc3FsJzpUcnVlLCd0ZWxlbWV0cnknOidwYW5lbC1kYid9IiwKICAgICAgICAgICAgICAgICAgICAgICAgICAiJ3N0YW5kYXJkX2FteHhfc3FsJzpUcnVlLCd0ZWxlbWV0cnknOidwYW5lbC1kYicsJ2xlZ2FjeV9zcWwnOmxlZ2FjeV9zcWx9IikKICAgICAgICBpZiAiJ2xlZ2FjeV9zcWwnOmxlZ2FjeV9zcWwiIG5vdCBpbiBmc3JjOgogICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ3NxbF9wcm92aXNpb24gcmV0dXJuIHBhdGNoIHBvaW50IG5vdCBmb3VuZCcpCgogICAgc3JjPV9yZXBsYWNlX2Z1bmMoc3JjLGZuLGZzcmMpCgogICAgdHJlZT1hc3QucGFyc2Uoc3JjKQogICAgZm49X2ZpbmRfZnVuY3Rpb24odHJlZSwnc3FsX3N0YXR1cycpCiAgICBpZiBmbiBpcyBOb25lOiByYWlzZSBSdW50aW1lRXJyb3IoJ3NxbF9zdGF0dXMgQVNUIG5vdCBmb3VuZCcpCiAgICBmc3JjPScnLmpvaW4oc3JjLnNwbGl0bGluZXMoa2VlcGVuZHM9VHJ1ZSlbZm4ubGluZW5vLTE6Zm4uZW5kX2xpbmVub10pCiAgICBpZiAiJ2xlZ2FjeV9zcWxfYnJpZGdlJzoiIG5vdCBpbiBmc3JjOgogICAgICAgIG9sZD0iJ3Bhc3N3b3JkJzpwdywnY29uZmlnX3BhdGgnOnN0cihjZmcpLCdjb25maWdfZXhpc3RzJzpjZmcuaXNfZmlsZSgpLCd0YWJsZXMnOnRhYmxlc1s6MjUwXSwnZXJyb3InOmVycm9yfSIKICAgICAgICBuZXc9IidwYXNzd29yZCc6cHcsJ2NvbmZpZ19wYXRoJzpzdHIoY2ZnKSwnY29uZmlnX2V4aXN0cyc6Y2ZnLmlzX2ZpbGUoKSwndGFibGVzJzp0YWJsZXNbOjI1MF0sJ2Vycm9yJzplcnJvcixcbiAgICAgICAgICAgICdsZWdhY3lfc3FsX2JyaWRnZSc6Yy5nZXQoJ2xlZ2FjeV9zcWxfYnJpZGdlJykgb3Ige319IgogICAgICAgIGlmIG9sZCBub3QgaW4gZnNyYzogcmFpc2UgUnVudGltZUVycm9yKCdzcWxfc3RhdHVzIHJldHVybiBwYXRjaCBwb2ludCBub3QgZm91bmQnKQogICAgICAgIGZzcmM9ZnNyYy5yZXBsYWNlKG9sZCxuZXcsMSkKICAgIHNyYz1fcmVwbGFjZV9mdW5jKHNyYyxmbixmc3JjKQoKICAgIHRtcD1wYXRoLndpdGhfbmFtZShwYXRoLm5hbWUrJy52MzI0dG1wJykKICAgIHRtcC53cml0ZV90ZXh0KHNyYyxlbmNvZGluZz0ndXRmLTgnLGVycm9ycz0nc3Vycm9nYXRlZXNjYXBlJykKICAgIG9zLmNobW9kKHRtcCxwYXRoLnN0YXQoKS5zdF9tb2RlKQogICAgcHlfY29tcGlsZS5jb21waWxlKHN0cih0bXApLGRvcmFpc2U9VHJ1ZSkKICAgIGZpbmFsPXRtcC5yZWFkX3RleHQoZW5jb2Rpbmc9J3V0Zi04JyxlcnJvcnM9J3N1cnJvZ2F0ZWVzY2FwZScpCiAgICByZXF1aXJlZD1bQ1RMX01BUktFUiwnbGVnYWN5X3NxbD1fdjMyNF93aXJlX2xlZ2FjeV9zcWwnLCdkZWYgX3YzMjRfd2lyZV9sZWdhY3lfc3FsJywiJ2xlZ2FjeV9zcWxfYnJpZGdlJzoiXQogICAgbWlzcz1beCBmb3IgeCBpbiByZXF1aXJlZCBpZiB4IG5vdCBpbiBmaW5hbF0KICAgIGlmIG1pc3M6IHJhaXNlIFJ1bnRpbWVFcnJvcignY29udHJvbGxlciB2ZXJpZmljYXRpb24gZmFpbGVkOiAnK3JlcHIobWlzcykpCiAgICBvcy5yZXBsYWNlKHRtcCxwYXRoKQogICAgcHJpbnQoJ1tQQVRDSEVEXScscGF0aCkKCgpkZWYgcGF0Y2hfaW5kZXgocGF0aDpQYXRoKToKICAgIHNyYz1wYXRoLnJlYWRfdGV4dChlbmNvZGluZz0ndXRmLTgnLGVycm9ycz0nc3Vycm9nYXRlZXNjYXBlJykKICAgICMgU1FMIGFjdGlvbiBmZWVkYmFjazogc2hvdyB3aGVuIGxlZ2FjeSBGcmVzaEJhbnMvQWRtaW4gTG9hZGVyIHdhcyByZXdpcmVkLgogICAgb2xkPSJmbGFzaCgnU1FMINC/0L7QtNC60LvRjtGH0ZHQvS4gQU1YWCBzcWwuY2ZnINC+0LHQvdC+0LLQu9GR0L06ICcuKHN0cmluZykoJHJbJ2RhdGFiYXNlJ10/PycnKS4nIC8gJy4oc3RyaW5nKSgkclsndXNlciddPz8nJykpOyIKICAgIG5ldz0iJGxlZ2FjeT0kclsnbGVnYWN5X3NxbCddPz9bXTskbGVnYWN5TXNnPSghZW1wdHkoJGxlZ2FjeVsnd2lyZWQnXSkpPycgwrcgRnJlc2hCYW5zL0FkbWluIExvYWRlciDQv9C+0LTQutC70Y7Rh9C10L3RiyDQuiDRjdGC0L7QuSDQttC1INCx0LDQt9C1Lic6Jyc7Zmxhc2goJ1NRTCDQv9C+0LTQutC70Y7Rh9GR0L0uIEFNWFggc3FsLmNmZyDQvtCx0L3QvtCy0LvRkdC9OiAnLihzdHJpbmcpKCRyWydkYXRhYmFzZSddPz8nJykuJyAvICcuKHN0cmluZykoJHJbJ3VzZXInXT8/JycpLiRsZWdhY3lNc2cpOyIKICAgIGlmIG9sZCBpbiBzcmMgYW5kICckbGVnYWN5TXNnPScgbm90IGluIHNyYzoKICAgICAgICBzcmM9c3JjLnJlcGxhY2Uob2xkLG5ldywxKQoKICAgIG9sZHA9J9CU0LvRjyBBTVhYLdGB0LHQvtGA0L7QuiDQsNCy0YLQvtC80LDRgtC40YfQtdGB0LrQuCDRgdC+0LfQtNCw0ZHRgtGB0Y8g0L7RgtC00LXQu9GM0L3QsNGPINCx0LDQt9CwINC4INGB0YLQsNC90LTQsNGA0YLQvdGL0LkgPGNvZGU+YWRkb25zL2FteG1vZHgvY29uZmlncy9zcWwuY2ZnPC9jb2RlPi4nCiAgICBuZXdwPSfQlNC70Y8gQU1YWC3RgdCx0L7RgNC+0Log0LDQstGC0L7QvNCw0YLQuNGH0LXRgdC60Lgg0YHQvtC30LTQsNGR0YLRgdGPINC+0YLQtNC10LvRjNC90LDRjyDQsdCw0LfQsCDQuCDRgdGC0LDQvdC00LDRgNGC0L3Ri9C5IDxjb2RlPmFkZG9ucy9hbXhtb2R4L2NvbmZpZ3Mvc3FsLmNmZzwvY29kZT4uIEhZUEVSLUhPU1Qg0YLQsNC60LbQtSDQvtC/0YDQtdC00LXQu9GP0LXRgiBGcmVzaEJhbnMvQWRtaW4gTG9hZGVyINC4INC/0LXRgNC10L/RgNC40LLRj9C30YvQstCw0LXRgiDQuNGFINGB0L7QsdGB0YLQstC10L3QvdGL0LUgU1FMLdC90LDRgdGC0YDQvtC50LrQuCDQuiDRjdGC0L7QuSDQttC1INCx0LDQt9C1LicKICAgIGlmIG9sZHAgaW4gc3JjOgogICAgICAgIHNyYz1zcmMucmVwbGFjZShvbGRwLG5ld3AsMSkKCiAgICAjIFNob3cgbm9uLXNlY3JldCBsZWdhY3kgYnJpZGdlIHN0YXR1cyBpbiB0aGUgU1FMIGNhcmQuCiAgICBhbmNob3I9Ijw/cGhwIGlmKCFlbXB0eSgkc2VsZWN0ZWRTcWxbJ2Vycm9yJ10pKTo/PjxkaXYgY2xhc3M9XCJhbGVydCBhbGVydC13YXJuaW5nIG10LTMgbWItMFwiPjxiPlNRTDo8L2I+IDw/PWUoKHN0cmluZykkc2VsZWN0ZWRTcWxbJ2Vycm9yJ10pPz48L2Rpdj48P3BocCBlbmRpZjs/PiIKICAgIGlmICdMZWdhY3kgU1FMIGJyaWRnZScgbm90IGluIHNyYyBhbmQgYW5jaG9yIGluIHNyYzoKICAgICAgICBibG9jaz0iPD9waHAgJGxlZ2FjeUJyaWRnZT0oYXJyYXkpKCRzZWxlY3RlZFNxbFsnbGVnYWN5X3NxbF9icmlkZ2UnXT8/W10pOyBpZighZW1wdHkoJGxlZ2FjeUJyaWRnZVsnd2lyZWQnXSkpOj8+PGRpdiBjbGFzcz1cImNhbGxvdXQgbXQtMyBtb2Qtb2tcIj48aSBjbGFzcz1cImZhLXNvbGlkIGZhLWxpbmtcIj48L2k+PGRpdj48Yj5MZWdhY3kgU1FMIGJyaWRnZTwvYj48cD5GcmVzaEJhbnMvQWRtaW4gTG9hZGVyINC/0L7QtNC60LvRjtGH0LXQvdGLINC6INGN0YLQvtC5INCx0LDQt9C1LiBTZXJ2ZXIga2V5OiA8Y29kZT48Pz1lKChzdHJpbmcpKCRsZWdhY3lCcmlkZ2VbJ3NlcnZlcl9hZGRyZXNzJ10/PyfigJQnKSk/PjwvY29kZT4gwrcgUHJlZml4OiA8Y29kZT48Pz1lKChzdHJpbmcpKCRsZWdhY3lCcmlkZ2VbJ3ByZWZpeCddPz8n4oCUJykpPz48L2NvZGU+IMK3INCw0LTQvNC40L3QvtCyINCyIFNRTDogPD89KGludCkoJGxlZ2FjeUJyaWRnZVsnYWN0aXZlX2FkbWluX3Jvd3MnXT8/MCk/Pi48L3A+PC9kaXY+PC9kaXY+PD9waHAgZW5kaWY7Pz4iCiAgICAgICAgc3JjPXNyYy5yZXBsYWNlKGFuY2hvcixibG9jaythbmNob3IsMSkKCiAgICB0bXA9cGF0aC53aXRoX25hbWUocGF0aC5uYW1lKycudjMyNHRtcCcpCiAgICB0bXAud3JpdGVfdGV4dChzcmMsZW5jb2Rpbmc9J3V0Zi04JyxlcnJvcnM9J3N1cnJvZ2F0ZWVzY2FwZScpCiAgICBvcy5jaG1vZCh0bXAscGF0aC5zdGF0KCkuc3RfbW9kZSkKICAgIG9zLnJlcGxhY2UodG1wLHBhdGgpCiAgICBwcmludCgnW1BBVENIRURdJyxwYXRoKQoKCmRlZiBtYWluKCk6CiAgICBpZiBsZW4oc3lzLmFyZ3YpIT0zOiByYWlzZSBTeXN0ZW1FeGl0KCd1c2FnZTogcGF0Y2hfdjMyNC5weSBjdGx8aW5kZXggUEFUSCcpCiAgICBpZiBzeXMuYXJndlsxXT09J2N0bCc6IHBhdGNoX2N0bChQYXRoKHN5cy5hcmd2WzJdKSkKICAgIGVsaWYgc3lzLmFyZ3ZbMV09PSdpbmRleCc6IHBhdGNoX2luZGV4KFBhdGgoc3lzLmFyZ3ZbMl0pKQogICAgZWxzZTogcmFpc2UgU3lzdGVtRXhpdCgnYmFkIG1vZGUnKQoKaWYgX19uYW1lX189PSdfX21haW5fXyc6IG1haW4oKQo=' | base64 -d >"$PATCHER"
python3 -m py_compile "$PATCHER" || die "Embedded v3.24 patcher is invalid"

echo "============================================================"
echo " HYPER-HOST CS16 v3.24 — LEGACY SQL BRIDGE"
echo "============================================================"
echo "Server:     $SID"
echo "Live ctl:   $LIVE_CTL"
echo "Repo:       $REPO"
echo "Backup:     $BACKUP"
echo "Log:        $LOG"
echo

[[ "$SID" =~ ^[0-9]+$ ]] || die "Invalid server id: $SID"
[[ -f "$LIVE_CTL" ]] || die "Live controller not found: $LIVE_CTL"
[[ -f "$REPO_CTL" ]] || die "Repository controller not found: $REPO_CTL"
[[ -f "/var/lib/hyper-cs16/servers/$SID.json" ]] || die "Server state not found: $SID"
grep -q "def sql_provision" "$LIVE_CTL" || die "sql_provision not found in live controller"

STATE="/var/lib/hyper-cs16/servers/$SID.json"
SERVER_PATH="$(python3 - "$STATE" <<'PYSTATE'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
print(d.get('path') or f"/srv/hyper-cs16/servers/{int(d.get('id') or 0)}")
PYSTATE
)"
FB_CFG="$SERVER_PATH/cstrike/addons/amxmodx/configs/fb/main.cfg"
SQL_CFG="$SERVER_PATH/cstrike/addons/amxmodx/configs/sql.cfg"
USERS_CFG="$SERVER_PATH/cstrike/addons/amxmodx/configs/users.ini"

echo "[1/9] Backing up controller / panel / SQL configs..."
backup_file "$LIVE_CTL"
backup_file "$REPO_CTL"
backup_file "$STATE"
backup_file "$FB_CFG"
backup_file "$SQL_CFG"
backup_file "$USERS_CFG"

echo
echo "[2/9] Patching LIVE controller..."
python3 "$PATCHER" ctl "$LIVE_CTL" || die "Live controller patch failed"
python3 -m py_compile "$LIVE_CTL" || die "Live controller syntax validation failed"
echo "[OK] controller patched"

echo
echo "[3/9] Synchronizing patched controller to current repo checkout..."
install -m 0755 "$LIVE_CTL" "$REPO_CTL"
python3 -m py_compile "$REPO_CTL" || die "Repository controller validation failed"

echo
echo "[4/9] Patching SQL page in active panel..."
for root in   "/var/www/hyper-host-sites/$DOMAIN/public_html"   "/var/www/$DOMAIN/public_html"   "/var/www/$DOMAIN"
do
  [[ -f "$root/index.php" ]] && echo "$root" >>"$ROOTS"
done
if command -v nginx >/dev/null 2>&1; then
  nginx -T >"$NGTMP" 2>&1 || true
  python3 - "$NGTMP" "$DOMAIN" >>"$ROOTS" <<'PYROOT'
import re,sys
text=open(sys.argv[1],encoding='utf-8',errors='ignore').read(); domain=sys.argv[2]
for block in re.findall(r'server\s*\{.*?\n\}',text,re.S):
    if domain not in block: continue
    for x in re.findall(r'(?m)^\s*root\s+([^;]+);',block):
        x=x.strip()
        if x.startswith('/'): print(x)
PYROOT
fi
while IFS= read -r idx; do
  grep -q "serverTabs" "$idx" 2>/dev/null || continue
  echo "$(dirname "$idx")" >>"$ROOTS"
done < <(find /var/www -xdev -type f -name index.php 2>/dev/null || true)
sort -u "$ROOTS" -o "$ROOTS"
PANEL_COUNT=0; FIRST_ROOT=""
while IFS= read -r DOCROOT; do
  [[ -f "$DOCROOT/index.php" ]] || continue
  grep -q "serverTabs" "$DOCROOT/index.php" || continue
  PANEL_COUNT=$((PANEL_COUNT+1)); [[ -n "$FIRST_ROOT" ]] || FIRST_ROOT="$DOCROOT"
  backup_file "$DOCROOT/index.php"
  python3 "$PATCHER" index "$DOCROOT/index.php" || die "Panel patch failed: $DOCROOT"
  php -l "$DOCROOT/index.php" >/dev/null || die "PHP syntax error: $DOCROOT/index.php"
  echo "[PATCHED PANEL] $DOCROOT"
done <"$ROOTS"
if [[ "$PANEL_COUNT" -gt 0 && -n "$FIRST_ROOT" ]]; then
  install -m 0644 "$FIRST_ROOT/index.php" "$REPO/cs16-panel/public/index.php"
  php -l "$REPO/cs16-panel/public/index.php" >/dev/null || die "Repo panel PHP validation failed"
else
  echo "[WARN] Active panel root not found; backend SQL bridge is still installed."
fi
while IFS= read -r svc; do
  [[ -n "$svc" ]] || continue
  systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
done < <(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '/php.*fpm/ {print $1}')

echo
echo "[5/9] Provisioning dedicated SQL + wiring FreshBans/Admin Loader for server #$SID..."
chmod 600 "$SQL_OUT"
set +e
"$LIVE_CTL" sql-provision "$SID" >"$SQL_OUT" 2>&1
RC=$?
set -e
python3 - "$SQL_OUT" <<'PYSHOW'
import json,sys
from pathlib import Path
raw=Path(sys.argv[1]).read_text(encoding='utf-8',errors='replace').strip()
try:
    obj=json.loads(raw.splitlines()[-1])
except Exception:
    print('[SQL OUTPUT]',raw[-2500:]); raise SystemExit(0)
if not obj.get('ok'):
    print('[SQL ERROR]',obj.get('error') or obj)
else:
    legacy=obj.get('legacy_sql') or {}
    print('[OK] database:',obj.get('database'))
    print('[OK] user:',obj.get('user'))
    print('[OK] host: 127.0.0.1:3306')
    print('[OK] standard sql.cfg:',obj.get('config_path'))
    print('[OK] FreshBans/Admin Loader detected:',bool(legacy.get('detected')))
    print('[OK] legacy bridge wired:',bool(legacy.get('wired')))
    if legacy.get('wired'):
        print('[OK] server key:',legacy.get('server_address'))
        print('[OK] prefix:',legacy.get('prefix'))
        print('[OK] tables:',', '.join(legacy.get('tables') or []))
        print('[OK] migrated admins:',legacy.get('migrated_admins'))
        print('[OK] active admin rows:',legacy.get('active_admin_rows'))
PYSHOW
[[ "$RC" -eq 0 ]] || die "sql-provision failed; see sanitized SQL error above"

echo
echo "[6/9] Showing effective FreshBans config (password redacted)..."
python3 - "$FB_CFG" <<'PYCFG'
import re,sys
from pathlib import Path
p=Path(sys.argv[1])
if not p.is_file():
    print('[INFO] FreshBans config is not present on this server'); raise SystemExit
text=p.read_text(encoding='utf-8',errors='replace')
keys=['fb_server_ip','fb_server_port','fb_server_name','fb_sql_host','fb_sql_user','fb_sql_pass','fb_sql_db','fb_sql_table','fb_servers_table','fb_sql_log_table','fb_use_sql','amx_password_field','amx_amxadmins_table','amx_admins_table']
for k in keys:
    m=re.search(r'(?im)^\s*'+re.escape(k)+r'\s+(?:"([^"]*)"|([^\s;/]+))',text)
    if not m: continue
    v=m.group(1) if m.group(1) is not None else (m.group(2) or '')
    if 'pass' in k.lower(): v='[REDACTED]'
    print(f'{k} = {v}')
PYCFG
if grep -q "212\.20\.41\.198" "$FB_CFG" 2>/dev/null; then
  echo "[WARN] Old SQL host still appears somewhere in fb/main.cfg (possibly in a comment)."
else
  echo "[OK] old external SQL host is gone from fb/main.cfg"
fi

echo
echo "[7/9] Restarting server so FreshBans/Admin Loader reload SQL settings..."
START_EPOCH="$(date +%s)"
systemctl reset-failed "hyper-cs16@$SID.service" 2>/dev/null || true
systemctl restart "hyper-cs16@$SID.service" || die "Server restart failed"
READY=0
for _ in $(seq 1 50); do
  if systemctl is-active --quiet "hyper-cs16@$SID.service"; then
    if "$LIVE_CTL" rcon "$SID" "status" >/dev/null 2>&1; then READY=1; break; fi
  fi
  sleep 1
done
[[ "$READY" -eq 1 ]] || die "Server did not become RCON-ready after SQL bridge"
sleep 5

echo
echo "[8/9] Verifying DB tables and Admin Loader contract..."
"$LIVE_CTL" sql-status "$SID" >"$SQL_STATUS" 2>&1 || true
chmod 600 "$SQL_STATUS"
python3 - "$SQL_STATUS" <<'PYSTATUS'
import json,sys
from pathlib import Path
raw=Path(sys.argv[1]).read_text(encoding='utf-8',errors='replace').strip()
try: d=json.loads(raw.splitlines()[-1])
except Exception:
    print('[WARN] could not parse sql-status:',raw[-1500:]); raise SystemExit
print('[OK]' if d.get('connected') else '[FAIL]','game SQL connected =',bool(d.get('connected')))
print('database =',d.get('database'))
print('user =',d.get('user'))
print('tables =',', '.join(d.get('tables') or []))
b=d.get('legacy_sql_bridge') or {}
if b:
    print('legacy kind =',b.get('kind'))
    print('server key =',b.get('server_address'))
    print('admin rows =',b.get('active_admin_rows'))
PYSTATUS
python3 - "$STATE" <<'PYDB'
import json,sys
from pathlib import Path
s=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
b=s.get('legacy_sql_bridge') or {}
if not b.get('wired'):
    print('[INFO] No legacy FreshBans bridge recorded.'); raise SystemExit
try:
 import pymysql
 con=pymysql.connect(host='127.0.0.1',port=3306,user=s['sql_user'],password=s['sql_password'],database=s['sql_db'],charset='utf8mb4',cursorclass=pymysql.cursors.DictCursor,connect_timeout=5)
 with con.cursor() as cur:
  for key in ('server_table','admins_table','admins_servers_table','bans_table','logs_table'):
   t=b.get(key)
   if not t: continue
   cur.execute('SELECT COUNT(*) AS c FROM `'+t+'`')
   print(f'[DB] {t} = {int(cur.fetchone()["c"])} row(s)')
 con.close()
except Exception as e:
 print('[WARN] DB verification:',e)
PYDB

echo "--- AMXX plugins ---"
"$LIVE_CTL" rcon "$SID" "amxx plugins" 2>&1 | tail -80 || true

echo
echo "[9/9] Fresh SQL log after restart..."
FRESH_LOG="$(journalctl -u "hyper-cs16@$SID.service" --since "@$START_EPOCH" --no-pager -o cat 2>/dev/null || journalctl -u "hyper-cs16@$SID.service" -n 300 --no-pager -o cat 2>/dev/null || true)"
printf '%s
' "$FRESH_LOG" | grep -Ei '\[FB\]|admin_loader|MYSQL ERROR|Проблемы с БД|SQL' | tail -120 || true
if printf '%s
' "$FRESH_LOG" | grep -q "212\.20\.41\.198"; then
  echo "[WARN] Fresh server log still references the old external database host."
else
  echo "[OK] fresh server log does not reference old SQL host 212.20.41.198"
fi
if printf '%s
' "$FRESH_LOG" | grep -Eqi 'MYSQL ERROR|Проблемы с БД|Table .* doesn.t exist|Unknown column'; then
  echo "[WARN] SQL is now local, but a plugin still reported an SQL/schema error above. Send these exact lines if present."
else
  echo "[OK] no FreshBans/Admin Loader SQL/schema error detected in fresh startup log"
fi

echo
echo "============================================================"
echo " v3.24 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo "Current and future builds with configs/fb/main.cfg are now wired to"
echo "the dedicated HYPER-HOST database of that game server."
echo "No existing database/table is dropped. users.ini backup admins are"
echo "seeded into the matching *_amxadmins / *_admins_servers tables."
echo "Backup: $BACKUP"
echo "Log:    $LOG"
echo "============================================================"
