#!/usr/bin/env bash
set -Eeuo pipefail

PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-}"

if [[ -t 1 ]]; then
  RESET='\033[0m'; CYAN='\033[1;96m'; GREEN='\033[1;92m'; YELLOW='\033[1;93m'; RED='\033[1;91m'; BOLD='\033[1m'
else
  RESET=''; CYAN=''; GREEN=''; YELLOW=''; RED=''; BOLD=''
fi

log() { printf '%b[%bHYPER-HOST%b]%b %s\n' "$BOLD" "$CYAN" "$RESET" "$RESET" "$*"; }
ok() { printf '%b[%bHYPER-HOST%b]%b %b%s%b\n' "$BOLD" "$CYAN" "$RESET" "$RESET" "$GREEN" "$*" "$RESET"; }
fail() { printf '%b[%bHYPER-HOST ERROR%b]%b %b%s%b\n' "$BOLD" "$RED" "$RESET" "$RESET" "$RED" "$*" "$RESET" >&2; exit 1; }

find_target() {
  local candidate
  if [[ -n "$TARGET_DIR" ]]; then
    printf '%s' "$TARGET_DIR"
    return
  fi
  if [[ -f "$PWD/install.sh" && -d "$PWD/src" ]]; then
    printf '%s' "$PWD"
    return
  fi
  for candidate in /root/hyper-hosting-panel /root/hyper-hosting-panel-main /opt/hyper-hosting-panel; do
    if [[ -f "$candidate/install.sh" && -d "$candidate/src" ]]; then
      printf '%s' "$candidate"
      return
    fi
  done
}

TARGET_DIR="$(find_target)"
[[ -n "$TARGET_DIR" ]] || fail "Не найден каталог репозитория. Запусти: sudo ./apply-v91-installer-menu-branding.sh /путь/к/hyper-hosting-panel"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
[[ -f "$TARGET_DIR/install.sh" && -d "$TARGET_DIR/src" ]] || fail "${TARGET_DIR} не похож на репозиторий HYPER-HOST."

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$TARGET_DIR/.hyper-host-v91-backup-$STAMP"
mkdir -p "$BACKUP_DIR"
for file in install.sh setup.sh README.md QUICK_START_RU.md; do
  [[ -e "$TARGET_DIR/$file" ]] && cp -a "$TARGET_DIR/$file" "$BACKUP_DIR/"
done

log "Устанавливаю фирменное меню HYPER-HOST v91 в ${TARGET_DIR}..."
install -m 0755 "$PATCH_DIR/files/install.sh" "$TARGET_DIR/install.sh"
install -m 0755 "$PATCH_DIR/files/setup.sh" "$TARGET_DIR/setup.sh"
install -m 0644 "$PATCH_DIR/files/README.md" "$TARGET_DIR/README.md"
install -m 0644 "$PATCH_DIR/files/QUICK_START_RU.md" "$TARGET_DIR/QUICK_START_RU.md"
install -m 0644 "$PATCH_DIR/PATCH-v91.md" "$TARGET_DIR/PATCH-v91.md"

bash -n "$TARGET_DIR/install.sh"
bash -n "$TARGET_DIR/setup.sh"

if [[ ${EUID} -eq 0 ]]; then
  install -m 0755 "$TARGET_DIR/setup.sh" /usr/local/sbin/hyper-host-installer
  ln -sf /usr/local/sbin/hyper-host-installer /usr/local/bin/hyper-host-installer 2>/dev/null || true
fi

ok "Патч v91 установлен. Резервная копия: ${BACKUP_DIR}"
printf '\nЗапусти новое меню:\n\n'
printf '  cd %q\n' "$TARGET_DIR"
printf '  sudo bash setup.sh\n\n'
printf 'После полной установки меню доступно командой:\n\n'
printf '  sudo hyper-host-installer\n\n'
printf 'GitHub: https://github.com/memes4u1337/hyper-hosting-panel\n'
printf 'Разработчик: memes4u1337\n'
