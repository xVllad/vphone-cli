#!/bin/zsh
# install_apps.sh — Batch install IPA/TIPA files into a running vphone JB VM.
#
# Copies each package to /tmp/ipas/ on the guest via scp, installs via
# trollstorehelper, then removes it. No files left on the device.
#
# Prerequisites:
#   - VM fully booted with JB and TrollStore Lite set up
#   - sshpass installed on host: brew install sshpass
#   - SSH accessible on the guest (localhost port-forwarded)
#
# Usage:
#   zsh scripts/install_apps.sh <apps-folder> [--port <port>] [--pass <password>]
#
# Examples:
#   zsh scripts/install_apps.sh ./apps
#   zsh scripts/install_apps.sh ./apps --port 2222
#   zsh scripts/install_apps.sh ./apps --port 2222 --pass alpine

set -euo pipefail

die()  { echo "[-] $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok()   { echo "[+] $*"; }
warn() { echo "[!] $*"; }

usage() {
  cat <<'EOF'
Usage: install_apps.sh <apps-folder> [options]

  <apps-folder>   Folder containing .ipa and/or .tipa files

Options:
  --port <port>   SSH port (default: 2222)
  --pass <pass>   SSH root password (default: alpine)
  -h, --help      Show this help
EOF
  exit 1
}

# ─── Args ────────────────────────────────────────────────────────────
[[ $# -ge 1 ]] || usage

APPS_DIR="$1"
shift

SSH_PORT="2222"
SSH_PASS="alpine"
SSH_USER="root"
SSH_HOST="127.0.0.1"
REMOTE_TMP="/tmp/ipas"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) SSH_PORT="$2"; shift 2 ;;
    --pass) SSH_PASS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ─── Validate ────────────────────────────────────────────────────────
[[ -d "$APPS_DIR" ]] || die "Folder not found: ${APPS_DIR}"
command -v sshpass >/dev/null 2>&1 || die "sshpass not found — install with: brew install sshpass"

packages=("${APPS_DIR}"/*.ipa(N) "${APPS_DIR}"/*.tipa(N))
(( ${#packages[@]} > 0 )) || die "No .ipa or .tipa files found in: ${APPS_DIR}"

# ─── SSH / SCP helpers ───────────────────────────────────────────────
SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
)

_ssh() {
  sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" "$@"
}

_scp() {
  sshpass -p "$SSH_PASS" scp "${SSH_OPTS[@]}" -P "$SSH_PORT" "$1" "${SSH_USER}@${SSH_HOST}:$2"
}

# ─── Connectivity ────────────────────────────────────────────────────
echo ""
info "SSH ${SSH_USER}@${SSH_HOST} -p ${SSH_PORT}"
_ssh "true" 2>/dev/null || die "Cannot connect. Is the VM booted and SSH running?"
ok "Connected"

# ─── Find trollstorehelper ───────────────────────────────────────────
TSHELPER=""
for candidate in \
  "/private/preboot/4010033559D1DCBF0C83298760F9804922445BA1D9E312A418D7A02230690F3F59FB16BD7B7A0A031B14695FD58492F7/jb-vphone/procursus/Applications/TrollStoreLite.app/trollstorehelper" \
  "/var/jb/usr/bin/trollstorehelper" \
  "/var/jb/Applications/TrollStoreLite.app/trollstorehelper" \
  "/usr/bin/trollstorehelper" \
  "/Applications/TrollStoreLite.app/trollstorehelper"
do
  if _ssh "test -x '${candidate}'" 2>/dev/null; then
    TSHELPER="$candidate"
    break
  fi
done
[[ -n "$TSHELPER" ]] || die "trollstorehelper not found. TrollStore Lite may still be setting up — check: tail -f /var/log/vphone_jb_setup.log"
ok "trollstorehelper: ${TSHELPER}"

# ─── Install ─────────────────────────────────────────────────────────
_ssh "mkdir -p '${REMOTE_TMP}'"

TOTAL=${#packages[@]}
SUCCESS=0
SKIPPED=0
failed_names=()

echo ""
info "${TOTAL} package(s) to install"
echo ""

for pkg in "${packages[@]}"; do
  name="${pkg:t}"
  remote_path="${REMOTE_TMP}/${name}"
  idx=$(( SUCCESS + ${#failed_names[@]} + SKIPPED + 1 ))

  echo "── [${idx}/${TOTAL}] ${name}"

  # Extract bundle ID from IPA on host (IPA is a zip)
  bundle_id=""
  plist_path=$(unzip -Z1 "$pkg" 2>/dev/null | grep -m1 'Payload/[^/]*/Info\.plist$' || true)
  if [[ -n "$plist_path" ]]; then
    bundle_id=$(unzip -p "$pkg" "$plist_path" 2>/dev/null \
      | plutil -extract CFBundleIdentifier raw - 2>/dev/null || true)
  fi

  # Check if already installed on guest
  if [[ -n "$bundle_id" ]]; then
    if _ssh "find /private/var/containers/Bundle/Application -maxdepth 2 -name 'Info.plist' \
        -exec /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' {} \\; 2>/dev/null \
        | grep -qFx '${bundle_id}'" 2>/dev/null; then
      info "  Already installed (${bundle_id}) — skipping"
      (( ++SKIPPED )) || true
      echo ""
      continue
    fi
  fi

  info "  Copying..."
  if ! _scp "$pkg" "$remote_path"; then
    warn "  Upload failed"
    failed_names+=("$name (upload failed)")
    echo ""
    continue
  fi

  info "  Installing..."
  if _ssh "'${TSHELPER}' install '${remote_path}'" 2>&1 | sed 's/^/    /'; then
    ok "  Installed"
    (( ++SUCCESS )) || true
  else
    warn "  Install failed"
    failed_names+=("$name")
  fi

  _ssh "rm -f '${remote_path}'"
  echo ""
done

_ssh "rmdir '${REMOTE_TMP}' 2>/dev/null || true"

# ─── Summary ─────────────────────────────────────────────────────────
FAIL=${#failed_names[@]}
echo "────────────────────────────────────────────"
if (( FAIL == 0 && SKIPPED == 0 )); then
  ok "${SUCCESS}/${TOTAL} installed."
elif (( FAIL == 0 )); then
  ok "${SUCCESS} installed, ${SKIPPED} already present (skipped)."
else
  warn "${SUCCESS} installed, ${SKIPPED} skipped, ${FAIL} failed."
  echo ""
  echo "  Failed:"
  for f in "${failed_names[@]}"; do
    echo "    - ${f}"
  done
fi
echo ""
