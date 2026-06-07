#!/usr/bin/env bash
#
# uninstall-mac-keys.sh — revert the key mappings install-mac-keys.sh applied
#
# Default behaviour (no flags): undo ONLY the configuration —
#   * Restores the backed-up keyd config if the state file recorded one
#     (returning keyd to whatever config existed before we ran); otherwise
#     removes only our managed config, identified by our sentinel marker.
#     A config file lacking the sentinel is NEVER deleted.
#     The config path is the one the installer recorded (it confirmed the
#     real path via `man keyd` — .conf vs .cfg differs across versions),
#     never a hardcoded guess.
#   * Runs `keyd reload` so the revert takes effect immediately.
#   * Removes the user from the keyd group only if WE added them.
#   * LEAVES the keyd package installed, the COPR repo enabled, and the
#     service enabled/running. Updates the state file to record that the
#     mappings are reverted but keyd remains (so a later --purge still
#     knows what to tear down).
#
# --purge: full teardown in addition to the above —
#   * Stops/disables the keyd service only if our state shows WE enabled it.
#   * COPR install method: `dnf remove -y keyd` then
#     `dnf copr remove alternateved/keyd` (safe when already disabled).
#   * Source method (fallback installs): `make uninstall`.
#   * Pre-existing keyd is never touched.
#   * Removes the state file last.
#
# Ctrl-preservation guarantee: this script only removes/restores files;
# it never writes any key mapping, so it cannot remap Ctrl.
#
# Flags:
#   --dry-run   Print every action without performing any of them.
#   --purge     Also remove keyd itself (see above). The only path that
#               removes the package.
#
# Idempotent: running when nothing is installed exits 0 with a message;
# re-running after a revert is a clean no-op.
#
set -euo pipefail

SENTINEL_GREP='MANAGED-BY: mac-keys-script'
# CFG is resolved below from the state file (preferred) or `man keyd` —
# never hardcoded, since the extension (.conf/.cfg) varies by keyd version.
CFG=""
STATE_DIR=/var/lib/mac-keys-script
STATE_FILE=$STATE_DIR/state
KEYD_REPO=https://github.com/rvaiya/keyd
KEYD_COPR=alternateved/keyd

DRY_RUN=0
PURGE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --purge)   PURGE=1 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $arg (supported: --dry-run --purge)" >&2; exit 2 ;;
    esac
done

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

# ------------------------------------------------------------ read state
ST_VERSION=1
ST_INSTALL_METHOD=""
ST_BACKUP_CONFIG=""
ST_ADDED_GROUP=no
ST_ENABLED_SERVICE=no
ST_MANAGED_APP_CONF=""
ST_APP_CONF_BACKUP=""
ST_CFG_PATH=""
ST_REVERTED=no
HAVE_STATE=0
if [[ -f $STATE_FILE ]]; then
    HAVE_STATE=1
    while IFS='=' read -r k v; do
        case "$k" in
            VERSION)          ST_VERSION=$v ;;
            INSTALL_METHOD)   ST_INSTALL_METHOD=$v ;;
            BACKUP_CONFIG)    ST_BACKUP_CONFIG=$v ;;
            ADDED_GROUP)      ST_ADDED_GROUP=$v ;;
            ENABLED_SERVICE)  ST_ENABLED_SERVICE=$v ;;
            MANAGED_APP_CONF) ST_MANAGED_APP_CONF=$v ;;
            APP_CONF_BACKUP)  ST_APP_CONF_BACKUP=$v ;;
            CFG_PATH)         ST_CFG_PATH=$v ;;
            REVERTED)         ST_REVERTED=$v ;;
        esac
    done < "$STATE_FILE"
fi

save_state() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
VERSION=$ST_VERSION
INSTALL_METHOD=$ST_INSTALL_METHOD
BACKUP_CONFIG=$ST_BACKUP_CONFIG
ADDED_GROUP=$ST_ADDED_GROUP
ENABLED_SERVICE=$ST_ENABLED_SERVICE
MANAGED_APP_CONF=$ST_MANAGED_APP_CONF
APP_CONF_BACKUP=$ST_APP_CONF_BACKUP
CFG_PATH=$ST_CFG_PATH
REVERTED=$ST_REVERTED
EOF
    run "${SUDO[@]}" install -m 644 "$tmp" "$STATE_FILE"
    rm -f "$tmp"
}

# -------------------------------------------- resolve the real config path
# Preferred: the path the installer recorded (it confirmed it via man keyd).
# Fallback 1: ask the installed keyd's man page.
# Fallback 2: scan both known spellings for a file carrying our sentinel.
detect_cfg_path() {
    local manpage path
    manpage=$(man keyd 2>/dev/null) || return 1
    path=$(grep -oE '/etc/keyd/default\.(conf|cfg)' <<<"$manpage" | head -n1 || true)
    if [[ -z $path ]]; then
        if grep -q '/etc/keyd' <<<"$manpage" && grep -qE '\.conf\b' <<<"$manpage"; then
            path=/etc/keyd/default.conf
        elif grep -q '/etc/keyd' <<<"$manpage" && grep -qE '\.cfg\b' <<<"$manpage"; then
            path=/etc/keyd/default.cfg
        fi
    fi
    [[ -n $path ]] || return 1
    echo "$path"
}

if [[ -n $ST_CFG_PATH ]]; then
    CFG=$ST_CFG_PATH
else
    CFG=$(detect_cfg_path) || true
    if [[ -z $CFG ]]; then
        for cand in /etc/keyd/default.conf /etc/keyd/default.cfg; do
            if [[ -f $cand ]] && grep -qF "$SENTINEL_GREP" "$cand"; then
                CFG=$cand
                break
            fi
        done
    fi
fi

if [[ $HAVE_STATE -eq 0 ]]; then
    if [[ -z $CFG ]] || [[ ! -f $CFG ]] || ! grep -qF "$SENTINEL_GREP" "$CFG"; then
        log "Nothing installed by mac-keys-script (no state file, no managed config). Nothing to do."
        exit 0
    fi
    note "No state file, but $CFG carries our sentinel — proceeding best-effort."
fi

# ----------------------------------------------------- 1. revert config
log "Step 1: revert keyd config (${CFG:-path unknown})"
CONFIG_TOUCHED=0
if [[ -z $CFG ]]; then
    note "WARNING: could not determine the keyd config path (no CFG_PATH in"
    note "state, no man page, no sentinel file found) — skipping config step."
elif [[ -n $ST_BACKUP_CONFIG && -f $ST_BACKUP_CONFIG ]]; then
    note "Restoring pre-existing config from $ST_BACKUP_CONFIG"
    run "${SUDO[@]}" cp -a "$ST_BACKUP_CONFIG" "$CFG"
    run "${SUDO[@]}" rm -f "$ST_BACKUP_CONFIG"
    [[ $DRY_RUN -eq 1 ]] || ST_BACKUP_CONFIG=""
    CONFIG_TOUCHED=1
elif [[ -f $CFG ]]; then
    if grep -qF "$SENTINEL_GREP" "$CFG"; then
        note "Removing our managed config."
        run "${SUDO[@]}" rm -f "$CFG"
        CONFIG_TOUCHED=1
    else
        note "WARNING: $CFG exists but lacks our sentinel (user-edited?) — leaving it alone."
    fi
else
    note "No config present — already reverted."
fi

# Per-user app.conf, if the installer wrote one
if [[ -n $ST_MANAGED_APP_CONF && -f $ST_MANAGED_APP_CONF ]]; then
    if grep -qF "$SENTINEL_GREP" "$ST_MANAGED_APP_CONF"; then
        note "Removing our managed app.conf ($ST_MANAGED_APP_CONF)."
        run rm -f "$ST_MANAGED_APP_CONF"
        if [[ -n $ST_APP_CONF_BACKUP && -f $ST_APP_CONF_BACKUP ]]; then
            note "Restoring user app.conf from $ST_APP_CONF_BACKUP"
            run cp -a "$ST_APP_CONF_BACKUP" "$ST_MANAGED_APP_CONF"
            run rm -f "$ST_APP_CONF_BACKUP"
        fi
        CONFIG_TOUCHED=1
    else
        note "WARNING: $ST_MANAGED_APP_CONF lacks our sentinel — leaving it alone."
    fi
    if [[ $DRY_RUN -eq 0 ]]; then
        ST_MANAGED_APP_CONF=""
        ST_APP_CONF_BACKUP=""
    fi
fi

# Apply the revert immediately (skip if purging — the service is going away)
if [[ $PURGE -eq 0 ]]; then
    if [[ $(systemctl is-active keyd 2>/dev/null) == active ]] && command -v keyd >/dev/null 2>&1; then
        if [[ $CONFIG_TOUCHED -eq 1 ]]; then
            note "Reloading keyd so the revert takes effect immediately."
            run "${SUDO[@]}" keyd reload
        else
            note "Config unchanged — no reload needed."
        fi
    fi
fi

# ------------------------------------------------------------ 2. group
log "Step 2: keyd group membership"
if [[ $ST_ADDED_GROUP == yes ]]; then
    if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx keyd; then
        note "Removing '$TARGET_USER' from keyd group (we added them; re-login to apply)."
        run "${SUDO[@]}" gpasswd -d "$TARGET_USER" keyd
    else
        note "User '$TARGET_USER' no longer in keyd group."
    fi
    [[ $DRY_RUN -eq 1 ]] || ST_ADDED_GROUP=no
else
    note "We did not add the user to the keyd group — leaving membership as-is."
fi

# ------------------------------------------------- 3. package & service
if [[ $PURGE -eq 1 ]]; then
    log "Step 3 (--purge): keyd service"
    if [[ $ST_ENABLED_SERVICE == yes ]]; then
        if [[ $(systemctl is-active keyd 2>/dev/null) == active ]]; then
            note "Stopping keyd (we started it)."
            run "${SUDO[@]}" systemctl stop keyd
        fi
        if [[ $(systemctl is-enabled keyd 2>/dev/null) == enabled ]]; then
            note "Disabling keyd (we enabled it)."
            run "${SUDO[@]}" systemctl disable keyd
        fi
    else
        note "We did not enable the service — leaving it as-is."
    fi

    log "Step 4 (--purge): remove keyd"
    case "$ST_INSTALL_METHOD" in
        copr)
            note "Removing COPR-installed keyd package."
            run "${SUDO[@]}" dnf remove -y keyd
            note "Removing COPR repo $KEYD_COPR (safe if already disabled)."
            if ! run "${SUDO[@]}" dnf -y copr remove "$KEYD_COPR"; then
                note "COPR repo was already removed/disabled — nothing to do."
            fi
            ;;
        source)
            note "Removing source-installed keyd via 'make uninstall'."
            if [[ $DRY_RUN -eq 1 ]]; then
                note "[dry-run] git clone $KEYD_REPO && sudo make uninstall"
            else
                BUILD_DIR=$(mktemp -d /tmp/keyd-uninstall.XXXXXX)
                git clone --depth 1 "$KEYD_REPO" "$BUILD_DIR/keyd"
                "${SUDO[@]}" make -C "$BUILD_DIR/keyd" uninstall
                "${SUDO[@]}" systemctl daemon-reload
                rm -rf "$BUILD_DIR"
            fi
            ;;
        preexisting)
            note "keyd was already on this system before our installer ran — not touching it."
            ;;
        *)
            note "Install method unknown (no state?) — leaving the keyd program alone."
            ;;
    esac
else
    log "Step 3: keyd package & service left intact"
    note "keyd stays installed, the COPR repo stays enabled, and the service"
    note "stays enabled/running — only our mappings were reverted."
    note "Run './uninstall-mac-keys.sh --purge' for full teardown."
fi

# --------------------------------------------------------- 4. state file
log "Step $([[ $PURGE -eq 1 ]] && echo 5 || echo 4): state file"
if [[ $HAVE_STATE -eq 1 ]]; then
    if [[ $PURGE -eq 1 ]]; then
        note "Removing state file."
        run "${SUDO[@]}" rm -f "$STATE_FILE"
        run "${SUDO[@]}" rmdir --ignore-fail-on-non-empty "$STATE_DIR"
    else
        note "Updating state: mappings reverted, keyd remains (enables later --purge)."
        ST_REVERTED=yes
        save_state
    fi
else
    note "No state file to manage."
fi

log "Uninstall complete."
exit 0
