#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_VERSION="1.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="/etc/hyper-host/hyper-host.conf"
PROJECT_DIR="$SCRIPT_DIR"

# Когда меню запущено командой /usr/local/sbin/hyper-host-installer,
# берём путь к GitHub-копии проекта из конфигурации установленной панели.
if [[ ! -f "$PROJECT_DIR/install.sh" && -f "$CONF_FILE" ]]; then
  CONFIG_PROJECT_DIR="$(bash -c 'source "$1" 2>/dev/null || true; printf "%s" "${PROJECT_SOURCE_DIR:-}"' _ "$CONF_FILE" 2>/dev/null || true)"
  if [[ -n "$CONFIG_PROJECT_DIR" && -f "$CONFIG_PROJECT_DIR/install.sh" ]]; then
    PROJECT_DIR="$CONFIG_PROJECT_DIR"
  fi
fi
if [[ ! -f "$PROJECT_DIR/install.sh" ]]; then
  for candidate in /root/hyper-hosting-panel /root/hyper-hosting-panel-main /opt/hyper-hosting-panel; do
    if [[ -f "$candidate/install.sh" ]]; then
      PROJECT_DIR="$candidate"
      break
    fi
  done
fi
INSTALL_SCRIPT="${PROJECT_DIR}/install.sh"

AUTHOR="memes4u1337"
PROJECT_SITE="https://hyper-host.pw"
PANEL_SITE="https://panel.hyper-host.pw"
REPOSITORY="https://github.com/memes4u1337/hyper-hosting-panel"
AUTHOR_URL="https://github.com/memes4u1337"

if [[ -t 1 ]]; then
  RESET='\033[0m'
  BOLD='\033[1m'
  DIM='\033[2m'
  CYAN='\033[1;96m'
  BLUE='\033[1;94m'
  GREEN='\033[1;92m'
  YELLOW='\033[1;93m'
  RED='\033[1;91m'
  WHITE='\033[1;97m'
else
  RESET=''
  BOLD=''
  DIM=''
  CYAN=''
  BLUE=''
  GREEN=''
  YELLOW=''
  RED=''
  WHITE=''
fi

brand() { printf '%bHYPER-HOST%b' "$CYAN" "$RESET"; }
line() { printf '%b%s%b\n' "$BLUE" '======================================================================' "$RESET"; }
info() { printf '%b[%bHYPER-HOST%b]%b %s\n' "$BOLD" "$CYAN" "$RESET" "$RESET" "$*"; }
ok() { printf '%b[%bHYPER-HOST%b]%b %b%s%b\n' "$BOLD" "$CYAN" "$RESET" "$RESET" "$GREEN" "$*" "$RESET"; }
warn() { printf '%b[%bHYPER-HOST%b]%b %b%s%b\n' "$BOLD" "$CYAN" "$RESET" "$RESET" "$YELLOW" "$*" "$RESET"; }
error() { printf '%b[%bHYPER-HOST%b]%b %b%s%b\n' "$BOLD" "$CYAN" "$RESET" "$RESET" "$RED" "$*" "$RESET" >&2; }

pause_menu() {
  [[ -t 0 ]] || return 0
  printf '\n%bНажми Enter, чтобы вернуться в меню...%b' "$DIM" "$RESET"
  read -r _ || true
}

clear_screen() {
  [[ -t 1 ]] && clear || true
}

show_banner() {
  clear_screen
  printf '%b' "$CYAN"
  cat <<'BANNER'
██╗  ██╗██╗   ██╗██████╗ ███████╗██████╗       ██╗  ██╗ ██████╗ ███████╗████████╗
██║  ██║╚██╗ ██╔╝██╔══██╗██╔════╝██╔══██╗      ██║  ██║██╔═══██╗██╔════╝╚══██╔══╝
███████║ ╚████╔╝ ██████╔╝█████╗  ██████╔╝█████╗███████║██║   ██║███████╗   ██║
██╔══██║  ╚██╔╝  ██╔═══╝ ██╔══╝  ██╔══██╗╚════╝██╔══██║██║   ██║╚════██║   ██║
██║  ██║   ██║   ██║     ███████╗██║  ██║      ██║  ██║╚██████╔╝███████║   ██║
╚═╝  ╚═╝   ╚═╝   ╚═╝     ╚══════╝╚═╝  ╚═╝      ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
BANNER
  printf '%b' "$RESET"
  line
  printf '  %bУстановщик и центр управления | v%s%b\n' "$WHITE" "$INSTALLER_VERSION" "$RESET"
  printf '  Разработчик: %b%s%b | GitHub: %s\n' "$BOLD" "$AUTHOR" "$RESET" "$AUTHOR_URL"
  line
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    error "Запусти установщик через sudo: sudo bash setup.sh"
    exit 1
  fi
}

load_config() {
  PANEL_DOMAIN=""
  SERVER_IP=""
  PUBLIC_IP=""
  ADMIN_USER="admin"
  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE" || true
  fi
  if [[ -z "${SERVER_IP:-}" ]]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  SERVER_IP="${SERVER_IP:-127.0.0.1}"
}

show_project_info() {
  load_config
  show_banner
  printf '%bО проекте%b\n\n' "$WHITE" "$RESET"
  printf '  Название:        %bHYPER-HOST%b\n' "$CYAN" "$RESET"
  printf '  Разработчик:     %s\n' "$AUTHOR"
  printf '  Версия меню:     v%s\n' "$INSTALLER_VERSION"
  printf '  Сайт проекта:    %s\n' "$PROJECT_SITE"
  printf '  Панель:          %s\n' "$PANEL_SITE"
  printf '  Репозиторий:     %s\n' "$REPOSITORY"
  printf '  Профиль автора:  %s\n' "$AUTHOR_URL"
  printf '\n%bСервер%b\n\n' "$WHITE" "$RESET"
  printf '  Локальный IP:    %s\n' "$SERVER_IP"
  printf '  Публичный IP:    %s\n' "${PUBLIC_IP:-не настроен}"
  printf '  Домен панели:    %s\n' "${PANEL_DOMAIN:-не настроен}"
  printf '  Конфигурация:    %s\n' "$CONF_FILE"
  printf '  CLI:             sudo hyper help\n'
  line
}

run_install() {
  show_banner
  [[ -f "$INSTALL_SCRIPT" ]] || { error "Не найден ${INSTALL_SCRIPT}"; return 1; }
  chmod +x "$INSTALL_SCRIPT"
  printf '%b[%bHYPER-HOST%b]%b Запускаю установку или обновление %bHYPER-HOST%b...\n' "$BOLD" "$CYAN" "$RESET" "$RESET" "$CYAN" "$RESET"
  printf '\n'
  bash "$INSTALL_SCRIPT"
  printf '\n'
  printf '%b[%bHYPER-HOST%b]%b %bУстановка %bHYPER-HOST%b %bзавершена.%b\n' "$BOLD" "$CYAN" "$RESET" "$RESET" "$GREEN" "$CYAN" "$RESET" "$GREEN" "$RESET"
  printf '  Меню управления: %bsudo hyper-host-installer%b\n' "$WHITE" "$RESET"
  printf '  Репозиторий:     %s\n' "$REPOSITORY"
  line
}

run_repair() {
  show_banner
  if ! command -v hyper >/dev/null 2>&1; then
    error "Команда hyper ещё не установлена. Сначала установи панель."
    return 1
  fi
  printf '%b[%bHYPER-HOST%b]%b Запускаю ремонт %bHYPER-HOST%b...\n' "$BOLD" "$CYAN" "$RESET" "$RESET" "$CYAN" "$RESET"
  hyper repair
  nginx -t
  systemctl reload nginx
  ok "Ремонт завершён, конфигурация Nginx корректна."
}

run_nginx_check() {
  show_banner
  info "Проверяю Nginx..."
  nginx -t
  systemctl is-active nginx --quiet && ok "Nginx запущен." || warn "Nginx сейчас не активен."
}

run_ssl_menu() {
  show_banner
  if ! command -v hyper >/dev/null 2>&1; then
    error "Команда hyper ещё не установлена."
    return 1
  fi
  local domain email
  printf '%bДомен для SSL:%b ' "$WHITE" "$RESET"
  read -r domain
  [[ -n "$domain" ]] || { error "Домен не указан."; return 1; }
  printf "%bEmail для Let's Encrypt:%b " "$WHITE" "$RESET"
  read -r email
  [[ -n "$email" ]] || { error "Email не указан."; return 1; }
  info "Исправляю ACME и выпускаю SSL для ${domain}..."
  hyper ssl fix "$domain"
  hyper ssl issue "$domain" "$email"
  hyper ssl check "$domain"
  ok "SSL-операция для ${domain} завершена."
}

run_ftp_repair() {
  show_banner
  if ! command -v hyper >/dev/null 2>&1; then
    error "Команда hyper ещё не установлена."
    return 1
  fi
  info "Восстанавливаю ProFTPD, FTP/FTPS, passive-порты и FTP-аккаунты..."
  hyper ftp fix
  hyper ftp doctor || true
  ok "FTP/FTPS восстановлен."
}

show_menu() {
  while true; do
    show_banner
    load_config
    printf '  %b1%b  Установить или обновить %bHYPER-HOST%b\n' "$GREEN" "$RESET" "$CYAN" "$RESET"
    printf '  %b2%b  Выполнить ремонт панели и Nginx\n' "$GREEN" "$RESET"
    printf '  %b3%b  Проверить конфигурацию Nginx\n' "$GREEN" "$RESET"
    printf '  %b4%b  Исправить ACME и выпустить SSL\n' "$GREEN" "$RESET"
    printf '  %b5%b  Восстановить FTP/FTPS\n' "$GREEN" "$RESET"
    printf '  %b6%b  Показать информацию и ссылки\n' "$GREEN" "$RESET"
    printf '  %b0%b  Выход\n' "$RED" "$RESET"
    if [[ -f "$CONF_FILE" ]]; then
      printf '\n  Статус: %bHYPER-HOST%b установлен | IP: %s\n' "$CYAN" "$RESET" "$SERVER_IP"
    else
      printf '\n  Статус: не установлен | IP: %s\n' "$SERVER_IP"
    fi
    printf '\n%bВыбери действие:%b ' "$WHITE" "$RESET"
    read -r choice || exit 0
    case "$choice" in
      1) run_install; pause_menu ;;
      2) run_repair || true; pause_menu ;;
      3) run_nginx_check || true; pause_menu ;;
      4) run_ssl_menu || true; pause_menu ;;
      5) run_ftp_repair || true; pause_menu ;;
      6) show_project_info; pause_menu ;;
      0) show_banner; ok "Работа установщика завершена."; exit 0 ;;
      *) warn "Неизвестный пункт: ${choice}"; sleep 1 ;;
    esac
  done
}

require_root
case "${1:-}" in
  --install|install) run_install ;;
  --repair|repair) run_repair ;;
  --nginx-check|nginx-check) run_nginx_check ;;
  --ftp-repair|ftp-repair) run_ftp_repair ;;
  --info|info) show_project_info ;;
  --help|-h|help)
    show_banner
    printf '%s\n' 'Использование:'
    printf '%s\n' '  sudo bash setup.sh               открыть интерактивное меню'
    printf '  sudo bash setup.sh --install     установить или обновить %bHYPER-HOST%b\n' "$CYAN" "$RESET"
    printf '%s\n' '  sudo bash setup.sh --repair      выполнить ремонт'
    printf '%s\n' '  sudo bash setup.sh --nginx-check проверить Nginx'
    printf '%s\n' '  sudo bash setup.sh --ftp-repair восстановить FTP/FTPS'
    printf '%s\n' '  sudo bash setup.sh --info        показать информацию и ссылки'
    ;;
  "") show_menu ;;
  *) error "Неизвестный аргумент: $1"; exit 2 ;;
esac
