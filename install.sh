#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  do-export installer
#  Usage: curl -fsSL https://your-host/install.sh | bash
# ─────────────────────────────────────────────

VERSION="1.0.0"
INSTALL_BIN="/usr/local/bin/do-export"
SERVICE_FILE="/etc/systemd/system/do-export-safe.service"
SCRIPT_URL="https://your-host/do-export.sh"   # ← point this at do-export.sh, NOT install.sh

# ── Colors ────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

# ── Helpers ───────────────────────────────────
header()  { echo -e "\n${BOLD}$1${RESET}"; }
info()    { echo -e "  ${DIM}→${RESET} $1"; }
success() { echo -e "  ${GREEN}✓${RESET} $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
fail()    { echo -e "\n  ${RED}✗ $1${RESET}\n" >&2; exit 1; }

ask() {
  # ask "Question" default_value
  # Prints prompt to /dev/tty and reads from /dev/tty so it works with curl|bash
  local prompt="$1"
  local default="${2:-}"
  local answer
  if [[ -n "$default" ]]; then
    echo -en "  ${BOLD}${prompt}${RESET} ${DIM}[${default}]${RESET}: " >/dev/tty
  else
    echo -en "  ${BOLD}${prompt}${RESET}: " >/dev/tty
  fi
  read -r answer </dev/tty
  # Echo the result to stdout so $() capture works correctly
  echo "${answer:-$default}"
}

ask_yn() {
  # ask_yn "Question" y|n  → returns 0 (yes) or 1 (no)
  local prompt="$1"
  local default="${2:-y}"
  local hint
  [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
  echo -en "  ${BOLD}${prompt}${RESET} ${DIM}[${hint}]${RESET}: " >/dev/tty
  local answer
  read -r answer </dev/tty
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

divider() { echo -e "${DIM}────────────────────────────────────────${RESET}"; }

# ── Preflight ─────────────────────────────────
preflight() {
  [[ "$EUID" -eq 0 ]] || fail "Please run as root (try: sudo bash)"
  command -v systemctl >/dev/null 2>&1 || fail "systemd is required"
  command -v curl      >/dev/null 2>&1 || \
  command -v wget      >/dev/null 2>&1 || fail "curl or wget is required"
}

# ── Welcome ───────────────────────────────────
welcome() {
  echo
  echo -e "${BOLD}  do-export${RESET} ${DIM}v${VERSION}${RESET}"
  echo -e "  ${DIM}Disk imaging & export tool — installer${RESET}"
  echo
  divider
  echo -e "  This will:"
  echo -e "  ${DIM}1.${RESET} Install do-export to ${BOLD}${INSTALL_BIN}${RESET}"
  echo -e "  ${DIM}2.${RESET} Ask a few questions to configure it"
  echo -e "  ${DIM}3.${RESET} Set up a systemd service that images your disk safely"
  divider
  echo
  ask_yn "Continue?" y || { echo; exit 0; }
}

# ── Config questions ──────────────────────────
collect_config() {
  header "Configuration"
  echo

  # Output directory
  OUTPUT_DIR=$(ask "Where should images be saved?" "/tmp/do-export")

  # Remote transfer
  echo
  if ask_yn "Transfer image to a remote server?" n; then
    REMOTE_TARGET=$(ask "Remote SSH target (user@host)")
    REMOTE_PATH=$(ask "Remote destination path" "~")
  else
    REMOTE_TARGET=""
    REMOTE_PATH="~"
  fi

  # Format
  echo >/dev/tty
  echo -e "  ${BOLD}Output format${RESET}"          >/dev/tty
  echo -e "  ${DIM}1)${RESET} raw   — universal, largest"              >/dev/tty
  echo -e "  ${DIM}2)${RESET} qcow2 — QEMU/KVM, supports compression"  >/dev/tty
  echo -e "  ${DIM}3)${RESET} vmdk  — VMware compatible"               >/dev/tty
  echo -e "  ${DIM}4)${RESET} vhd   — Hyper-V / Azure compatible"      >/dev/tty
  local fmt_choice
  fmt_choice=$(ask "Choose format" "1")
  case "$fmt_choice" in
    2) FORMAT="qcow2" ;;
    3) FORMAT="vmdk"  ;;
    4) FORMAT="vhd"   ;;
    *) FORMAT="raw"   ;;
  esac

  # Compression
  echo
  if ask_yn "Compress the image?" y; then
    COMPRESS="yes"
  else
    COMPRESS="no"
  fi

  # Verify
  echo
  if ask_yn "Verify with SHA-256 checksum?" y; then
    VERIFY="yes"
  else
    VERIFY="no"
  fi
}

# ── Summary ───────────────────────────────────
confirm_config() {
  echo
  divider
  header "Review your settings"
  echo
  info "Output directory : ${BOLD}${OUTPUT_DIR}${RESET}"
  info "Format           : ${BOLD}${FORMAT}${RESET}"
  info "Compression      : ${BOLD}${COMPRESS}${RESET}"
  info "Checksum         : ${BOLD}${VERIFY}${RESET}"
  if [[ -n "$REMOTE_TARGET" ]]; then
    info "Remote target    : ${BOLD}${REMOTE_TARGET}:${REMOTE_PATH}${RESET}"
  else
    info "Remote transfer  : ${BOLD}disabled${RESET}"
  fi
  echo
  divider
  echo
  ask_yn "Looks good — install?" y || { echo -e "\n  Aborted.\n"; exit 0; }
}

# ── Install binary ────────────────────────────
install_binary() {
  header "Installing"
  echo

  info "Downloading do-export..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$SCRIPT_URL" -o "$INSTALL_BIN"
  else
    wget -qO "$INSTALL_BIN" "$SCRIPT_URL"
  fi
  chmod +x "$INSTALL_BIN"
  success "Installed to ${INSTALL_BIN}"
}

# ── Write service ─────────────────────────────
install_service() {
  info "Writing systemd service..."

  # Build environment block dynamically
  local env_block="Environment=OUTPUT_DIR=${OUTPUT_DIR}
Environment=FORMAT=${FORMAT}
Environment=COMPRESS=${COMPRESS}
Environment=VERIFY=${VERIFY}"

  if [[ -n "$REMOTE_TARGET" ]]; then
    env_block+="
Environment=REMOTE_TARGET=${REMOTE_TARGET}
Environment=REMOTE_PATH=${REMOTE_PATH}"
  fi

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=do-export — safe disk imaging
DefaultDependencies=no
After=local-fs.target network.target
RequiresMountsFor=/tmp

[Service]
Type=oneshot
${env_block}
ExecStart=${INSTALL_BIN}
ExecStartPost=/bin/sh -c 'test -f /tmp/export-ok && systemctl set-default multi-user.target || systemctl emergency'
ExecStartPost=/bin/sh -c 'test -f /tmp/export-ok && reboot'
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable do-export-safe.service 2>/dev/null
  success "Service installed and enabled"
}

# ── Done ──────────────────────────────────────
finish() {
  echo
  divider
  echo
  echo -e "  ${GREEN}${BOLD}All done!${RESET}"
  echo
  echo -e "  To run the export:"
  echo -e "  ${BOLD}  systemctl set-default multi-user.target && reboot${RESET}"
  echo
  echo -e "  To check results after the machine comes back:"
  echo -e "  ${BOLD}  journalctl -u do-export-safe.service${RESET}"
  echo
  echo -e "  To uninstall:"
  echo -e "  ${BOLD}  systemctl disable do-export-safe.service && rm ${INSTALL_BIN} ${SERVICE_FILE}${RESET}"
  echo
  divider
  echo
}

# ── Main ──────────────────────────────────────
main() {
  preflight
  welcome
  collect_config
  confirm_config
  install_binary
  install_service
  finish
}

main "$@"
