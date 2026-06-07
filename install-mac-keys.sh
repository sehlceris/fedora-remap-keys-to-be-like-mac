#!/usr/bin/env bash
#
# install-mac-keys.sh — macOS-style key remapping for Fedora/GNOME via keyd
#
# What this does:
#   * Installs keyd from the alternateved/keyd COPR repository (keyd is not
#     in Fedora's official repos); falls back to building from
#     https://github.com/rvaiya/keyd source only if COPR fails.
#     Requires keyd >= 2.2.
#   * Confirms the config path/extension the installed keyd actually reads
#     (via `man keyd` — default.conf vs default.cfg differs across versions),
#     then installs the mac-keys.conf template that sits next to this script
#     (backing up any pre-existing user config). Edit mac-keys.conf to
#     add/remove key combinations, then re-run this script. The template
#     implements:
#       - Physical swap: leftmeta (Win) <-> leftalt, so a Cmd-position
#         thumb key sits next to the spacebar.
#       - Cmd+C/V/X -> copy/paste/cut, Cmd+Tab -> app switch.
#   * Enables and starts the keyd systemd service.
#   * Records everything it changed in /var/lib/mac-keys-script/state so
#     uninstall-mac-keys.sh can reverse exactly what was done.
#
# Ctrl-preservation guarantee:
#   This script NEVER remaps the physical Ctrl keys and never emits a
#   config in which `control`/`leftcontrol`/`rightcontrol`/`ctrl` appears
#   as a mapping *source*. Plain Ctrl+C continues to send SIGINT in every
#   terminal. A grep guard aborts the script if the generated config would
#   ever violate this.
#
# Flags:
#   --dry-run   Print every action without performing any of them.
#
# Idempotent: safe to run repeatedly; re-runs converge to the same state.
#
set -euo pipefail

SCRIPT_VERSION=1
SENTINEL='# MANAGED-BY: mac-keys-script v1 — do not edit by hand'
SENTINEL_GREP='MANAGED-BY: mac-keys-script'
# CFG is NOT hardcoded — it is detected from `man keyd` after keyd is
# installed (the extension changed across keyd versions: .cfg vs .conf).
CFG=""
STATE_DIR=/var/lib/mac-keys-script
STATE_FILE=$STATE_DIR/state
KEYD_REPO=https://github.com/rvaiya/keyd
KEYD_COPR=alternateved/keyd
MIN_KEYD_VERSION=2.2

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $arg (supported: --dry-run)" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- helpers
if [[ $EUID -eq 0 ]]; then SUDO=(); else SUDO=(sudo); fi
TARGET_USER=${SUDO_USER:-$(id -un)}

log()  { echo "==> $*"; }
note() { echo "    $*"; }

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "    [dry-run] $*"
    else
        "$@"
    fi
}

ver_ge() { # ver_ge A B  -> true if A >= B
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

keyd_version() {
    command -v keyd >/dev/null 2>&1 || return 1
    keyd --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1
}

# State handling: load any existing state so re-runs preserve the original
# record of what we changed (e.g. don't lose the backup path on run #2).
ST_INSTALL_METHOD=""
ST_BACKUP_CONFIG=""
ST_ADDED_GROUP=no
ST_ENABLED_SERVICE=no
ST_MANAGED_APP_CONF=""
ST_APP_CONF_BACKUP=""
ST_CFG_PATH=""
if [[ -f $STATE_FILE ]]; then
    # shellcheck disable=SC1090
    while IFS='=' read -r k v; do
        case "$k" in
            INSTALL_METHOD)  ST_INSTALL_METHOD=$v ;;
            BACKUP_CONFIG)   ST_BACKUP_CONFIG=$v ;;
            ADDED_GROUP)     ST_ADDED_GROUP=$v ;;
            ENABLED_SERVICE) ST_ENABLED_SERVICE=$v ;;
            MANAGED_APP_CONF) ST_MANAGED_APP_CONF=$v ;;
            APP_CONF_BACKUP) ST_APP_CONF_BACKUP=$v ;;
            CFG_PATH)        ST_CFG_PATH=$v ;;
        esac
    done < "$STATE_FILE"
    log "Existing state file found ($STATE_FILE) — re-run will converge, not duplicate."
fi

save_state() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
VERSION=$SCRIPT_VERSION
INSTALL_METHOD=$ST_INSTALL_METHOD
BACKUP_CONFIG=$ST_BACKUP_CONFIG
ADDED_GROUP=$ST_ADDED_GROUP
ENABLED_SERVICE=$ST_ENABLED_SERVICE
MANAGED_APP_CONF=$ST_MANAGED_APP_CONF
APP_CONF_BACKUP=$ST_APP_CONF_BACKUP
CFG_PATH=$CFG
EOF
    run "${SUDO[@]}" mkdir -p "$STATE_DIR"
    run "${SUDO[@]}" install -m 644 "$tmp" "$STATE_FILE"
    rm -f "$tmp"
}

# Hard guard: the generated config must never remap Ctrl as a source key.
ctrl_guard() {
    local file=$1
    if grep -qiE '^[[:space:]]*(left|right)?(control|ctrl)[[:space:]]*=' "$file"; then
        echo "FATAL: generated config '$file' remaps a Ctrl key as a source. Aborting." >&2
        echo "Offending line(s):" >&2
        grep -niE '^[[:space:]]*(left|right)?(control|ctrl)[[:space:]]*=' "$file" >&2
        exit 1
    fi
}

# Determine the config path the *installed* keyd actually reads. The
# extension changed across keyd versions (.cfg in 1.x, .conf in 2.x), so
# we confirm via the installed man page rather than assuming.
detect_cfg_path() {
    local manpage path
    manpage=$(man keyd 2>/dev/null) || return 1
    path=$(grep -oE '/etc/keyd/default\.(conf|cfg)' <<<"$manpage" | head -n1 || true)
    if [[ -z $path ]]; then
        # Man page may only mention the directory + extension, not the
        # literal default file name.
        if grep -q '/etc/keyd' <<<"$manpage" && grep -qE '\.conf\b' <<<"$manpage"; then
            path=/etc/keyd/default.conf
        elif grep -q '/etc/keyd' <<<"$manpage" && grep -qE '\.cfg\b' <<<"$manpage"; then
            path=/etc/keyd/default.cfg
        fi
    fi
    [[ -n $path ]] || return 1
    echo "$path"
}

# ----------------------------------------------------------- 1. get keyd
log "Step 1: ensure keyd >= $MIN_KEYD_VERSION is installed"
CUR_VER=$(keyd_version || true)
if [[ -n $CUR_VER ]] && ver_ge "$CUR_VER" "$MIN_KEYD_VERSION"; then
    note "keyd $CUR_VER already installed — skipping installation."
    [[ -z $ST_INSTALL_METHOD ]] && ST_INSTALL_METHOD=preexisting
else
    if [[ -n $CUR_VER ]]; then
        note "keyd $CUR_VER found but < $MIN_KEYD_VERSION; will install a newer one."
    fi
    # keyd is not in Fedora's official repos — the supported path is the
    # alternateved/keyd COPR. Source build is a fallback only.
    COPR_OK=0
    note "Installing keyd from COPR ($KEYD_COPR)."
    if run "${SUDO[@]}" dnf install -y dnf-plugins-core \
       && run "${SUDO[@]}" dnf copr enable -y "$KEYD_COPR" \
       && run "${SUDO[@]}" dnf install -y keyd; then
        COPR_OK=1
        ST_INSTALL_METHOD=copr
    else
        note "COPR install failed — falling back to building from source ($KEYD_REPO)."
        # Don't leave a half-enabled COPR repo behind on the fallback path.
        run "${SUDO[@]}" dnf -y copr remove "$KEYD_COPR" 2>/dev/null || true
    fi
    if [[ $COPR_OK -eq 0 ]]; then
        # build deps
        missing=()
        for tool in git make gcc; do
            command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
        done
        if [[ ${#missing[@]} -gt 0 ]]; then
            note "Installing build dependencies: ${missing[*]}"
            run "${SUDO[@]}" dnf install -y "${missing[@]}"
        fi
        BUILD_DIR=$(mktemp -d /tmp/keyd-build.XXXXXX)
        if [[ $DRY_RUN -eq 1 ]]; then
            note "[dry-run] git clone $KEYD_REPO && make && sudo make install (in $BUILD_DIR)"
            rmdir "$BUILD_DIR"
        else
            git clone --depth 1 "$KEYD_REPO" "$BUILD_DIR/keyd"
            make -C "$BUILD_DIR/keyd"
            "${SUDO[@]}" make -C "$BUILD_DIR/keyd" install
            "${SUDO[@]}" systemctl daemon-reload
            rm -rf "$BUILD_DIR"
        fi
        ST_INSTALL_METHOD=source
    fi
    if [[ $DRY_RUN -eq 0 ]]; then
        hash -r
        CUR_VER=$(keyd_version || true)
        if [[ -z $CUR_VER ]] || ! ver_ge "$CUR_VER" "$MIN_KEYD_VERSION"; then
            echo "FATAL: keyd ${CUR_VER:-<not found>} after install; need >= $MIN_KEYD_VERSION." >&2
            echo "Application-aware support requires keyd 2.x. Aborting without writing config." >&2
            exit 1
        fi
        note "keyd $CUR_VER installed (method: $ST_INSTALL_METHOD)."
    fi
fi

# ----------------------------------- 1b. confirm the config path keyd reads
log "Step 1b: confirm config path from the installed keyd's man page"
if CFG=$(detect_cfg_path); then
    note "Installed keyd reads: $CFG"
elif [[ $DRY_RUN -eq 1 ]] && ! command -v keyd >/dev/null 2>&1; then
    CFG='/etc/keyd/default.conf'
    note "[dry-run] keyd not installed yet — config path would be confirmed"
    note "[dry-run] from 'man keyd' after install; assuming $CFG for display."
else
    echo "FATAL: could not confirm keyd's config path from 'man keyd'." >&2
    echo "Refusing to guess between default.conf and default.cfg — a wrong" >&2
    echo "extension is silently ignored by keyd. Aborting before any write." >&2
    exit 1
fi
if [[ -n $ST_CFG_PATH && $ST_CFG_PATH != "$CFG" ]]; then
    note "WARNING: state file recorded $ST_CFG_PATH previously; keyd now reads $CFG."
fi

# ------------------------------------------------- 2. load config template
# The key mappings live in mac-keys.conf next to this script — edit that
# file to add/remove combinations, then re-run this installer.
log "Step 2: load keyd config template"
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TEMPLATE="$SCRIPT_DIR/mac-keys.conf"
if [[ ! -f $TEMPLATE ]]; then
    echo "FATAL: config template not found: $TEMPLATE" >&2
    exit 1
fi
if ! head -n1 "$TEMPLATE" | grep -qF "$SENTINEL_GREP"; then
    echo "FATAL: $TEMPLATE is missing the '$SENTINEL_GREP' sentinel on line 1." >&2
    echo "The sentinel is how (un)install distinguishes our managed config" >&2
    echo "from a user-edited one — restore that first line." >&2
    exit 1
fi
note "Using template: $TEMPLATE"
TMP_CFG=$(mktemp)
trap 'rm -f "$TMP_CFG"' EXIT
cp "$TEMPLATE" "$TMP_CFG"

ctrl_guard "$TMP_CFG"
note "Ctrl-guard passed: config contains no remap of any Ctrl key."

# -------------------------------------- 3. detect per-application support
# keyd's per-app overrides live in keyd-application-mapper + app.conf, and
# on GNOME Wayland additionally require the keyd GNOME Shell extension to
# expose the focused window. We *detect*, never assume.
log "Step 3: detect keyd per-application support on this machine"
APP_AWARE=0
SESSION_TYPE=${XDG_SESSION_TYPE:-unknown}
if command -v keyd-application-mapper >/dev/null 2>&1; then
    if [[ $SESSION_TYPE == wayland ]]; then
        if command -v gnome-extensions >/dev/null 2>&1 \
           && gnome-extensions list 2>/dev/null | grep -qi keyd; then
            APP_AWARE=1
        else
            note "keyd-application-mapper present, but the keyd GNOME Shell"
            note "extension is NOT installed — per-app overrides cannot see"
            note "focused windows on GNOME Wayland. Using universal config."
        fi
    else
        APP_AWARE=1   # X11: mapper can read window class directly
    fi
else
    note "keyd-application-mapper not found — no per-app override support."
fi

USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
APP_CONF="$USER_HOME/.config/keyd/app.conf"
if [[ $APP_AWARE -eq 1 ]]; then
    note "Per-app support detected — writing terminal-scoped overrides to $APP_CONF"
    TMP_APP=$(mktemp)
    {
        echo "$SENTINEL"
        echo "# Terminals get the shift-chord so Cmd+C copies instead of sending SIGINT."
        for class in gnome-terminal-server org.gnome.Console kgx konsole code kitty alacritty foot wezterm xterm; do
            cat <<EOA
[$class]
cmd.c = C-S-c
cmd.v = C-S-v
cmd.x = C-S-x
EOA
        done
    } > "$TMP_APP"
    ctrl_guard "$TMP_APP"
    if [[ -f $APP_CONF ]] && ! grep -qF "$SENTINEL_GREP" "$APP_CONF" && [[ -z $ST_APP_CONF_BACKUP ]]; then
        ST_APP_CONF_BACKUP="$APP_CONF.bak.$(date +%Y%m%d%H%M%S)"
        note "Backing up existing user app.conf to $ST_APP_CONF_BACKUP"
        run cp -a "$APP_CONF" "$ST_APP_CONF_BACKUP"
    fi
    run install -D -m 644 -o "$TARGET_USER" "$TMP_APP" "$APP_CONF"
    rm -f "$TMP_APP"
    ST_MANAGED_APP_CONF=$APP_CONF
    note "NOTE: keyd-application-mapper must be running in your session"
    note "      (e.g. 'keyd-application-mapper -d') for these to take effect."
else
    note "Per-app overrides NOT available in this setup."
    note ">>> Copy/paste stays mapped to the universal Ctrl+C / Ctrl+V chord."
    note ">>> In terminals, Cmd+C will send Ctrl+C (SIGINT) — use the terminal's"
    note ">>> native Ctrl+Shift+C / Ctrl+Shift+V to copy/paste there, or ask for"
    note ">>> the xremap + GNOME-extension fallback if you want true per-app"
    note ">>> behaviour. Plain Ctrl is untouched either way."
fi

# -------------------------------------------------- 4. install the config
log "Step 4: install $CFG"
run "${SUDO[@]}" mkdir -p /etc/keyd
if [[ -f $CFG ]]; then
    if grep -qF "$SENTINEL_GREP" "$CFG"; then
        if cmp -s "$TMP_CFG" "$CFG"; then
            note "Existing managed config is identical — nothing to write."
            CFG_CHANGED=0
        else
            note "Updating our managed config (no backup needed — it is ours)."
            run "${SUDO[@]}" install -m 644 "$TMP_CFG" "$CFG"
            CFG_CHANGED=1
        fi
    else
        BK="$CFG.bak.$(date +%Y%m%d%H%M%S)"
        note "Pre-existing user config found — backing up to $BK"
        run "${SUDO[@]}" cp -a "$CFG" "$BK"
        [[ -z $ST_BACKUP_CONFIG ]] && ST_BACKUP_CONFIG=$BK
        run "${SUDO[@]}" install -m 644 "$TMP_CFG" "$CFG"
        CFG_CHANGED=1
    fi
else
    note "Writing new config."
    run "${SUDO[@]}" install -m 644 "$TMP_CFG" "$CFG"
    CFG_CHANGED=1
fi

# ------------------------------------------------------- 5. keyd group
log "Step 5: keyd group membership (needed for 'keyd monitor' etc.)"
if ! getent group keyd >/dev/null; then
    note "Creating 'keyd' group."
    run "${SUDO[@]}" groupadd keyd
fi
if [[ $TARGET_USER != root ]]; then
    if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx keyd; then
        note "User '$TARGET_USER' already in keyd group."
    else
        note "Adding '$TARGET_USER' to keyd group (takes effect after re-login)."
        run "${SUDO[@]}" usermod -aG keyd "$TARGET_USER"
        ST_ADDED_GROUP=yes
    fi
else
    note "Running as root with no invoking user — skipping group membership."
fi

# --------------------------------------------------------- 6. service
log "Step 6: keyd systemd service"
WAS_ENABLED=$(systemctl is-enabled keyd 2>/dev/null || true)
WAS_ACTIVE=$(systemctl is-active keyd 2>/dev/null || true)
if [[ $WAS_ENABLED != enabled ]]; then
    note "Enabling keyd service."
    run "${SUDO[@]}" systemctl enable keyd
    ST_ENABLED_SERVICE=yes
else
    note "Service already enabled."
fi
if [[ $WAS_ACTIVE != active ]]; then
    note "Starting keyd service."
    run "${SUDO[@]}" systemctl start keyd
elif [[ ${CFG_CHANGED:-0} -eq 1 ]]; then
    note "Service already running and config changed — reloading."
    run "${SUDO[@]}" keyd reload
else
    note "Service already running, config unchanged — nothing to do."
fi

# --------------------------------------------------------- 7. state file
log "Step 7: record state in $STATE_FILE"
save_state

# -------------------------------------------------------- 8. verification
log "Step 8: verification"
FAIL=0
if [[ $DRY_RUN -eq 1 ]]; then
    note "[dry-run] verification skipped (nothing was changed)."
else
    V=$(keyd_version || true)
    if [[ -n $V ]] && ver_ge "$V" "$MIN_KEYD_VERSION"; then
        note "[ok] keyd version $V >= $MIN_KEYD_VERSION"
    else
        note "[FAIL] keyd version '$V' < $MIN_KEYD_VERSION"; FAIL=1
    fi
    if [[ $(systemctl is-active keyd 2>/dev/null) == active ]]; then
        note "[ok] keyd service is active"
    else
        note "[FAIL] keyd service is not active"; FAIL=1
    fi
    if grep -qiE '^[[:space:]]*(left|right)?(control|ctrl)[[:space:]]*=' "$CFG"; then
        note "[FAIL] installed config remaps Ctrl — THIS SHOULD NEVER HAPPEN"; FAIL=1
    else
        note "[ok] installed config contains no Ctrl remap (SIGINT preserved)"
    fi
fi
note "Display server: $SESSION_TYPE"
if [[ $SESSION_TYPE == x11 ]]; then
    note "    You are on X11, not Wayland — keyd's app-detection path differs"
    note "    (window class read directly, no GNOME extension needed); per-app"
    note "    behaviour may vary from this script's Wayland assumptions."
fi

cat <<'EOF'

──────────────────────────── MANUAL TESTS ────────────────────────────
1. SIGINT intact (the hard requirement):
     open a terminal, run:  sleep 60
     press plain Ctrl+C  →  it must interrupt immediately.
2. Copy/paste, GUI: in a text editor / browser, select text and press
     Cmd-position+C then Cmd-position+V  →  copy & paste.
3. Copy/paste, terminal: select text, Cmd-position+C / +V. If per-app
     overrides were not available (see Step 3 output above), use the
     terminal's native Ctrl+Shift+C / Ctrl+Shift+V instead.
4. App switching: hold Cmd-position key and press Tab  →  GNOME app
     switcher should appear.
NOTE: if you were just added to the keyd group, log out and back in
      before using 'keyd monitor'.
───────────────────────────────────────────────────────────────────────
EOF

if [[ $FAIL -eq 1 ]]; then
    echo "Verification FAILED — see [FAIL] lines above." >&2
    exit 1
fi
log "Done. To undo everything: ./uninstall-mac-keys.sh"
