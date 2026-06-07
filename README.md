# fedora-thinkpad-remap-keys-to-be-like-mac

macOS-style key remapping for a ThinkPad running Fedora (GNOME on Wayland),
powered by [keyd](https://github.com/rvaiya/keyd).

The key directly left of the spacebar (physical **Alt** on a ThinkPad — the
spot where macOS Cmd sits) becomes a **Cmd** layer, and the **Win** key takes
over as Alt so nothing is lost.

## What you get

| Chord (Cmd = key next to space) | Action |
|---|---|
| Cmd+C / Cmd+V / Cmd+X | copy / paste / cut |
| Cmd+Z | undo |
| Cmd+W | close tab (sends Ctrl+W) |
| Cmd+Tab | app switcher |
| Cmd tap | GNOME overview (still sends Super) |
| Win key | acts as Alt (Alt+F4-style accelerators, menus) |

Commented-out extras (Cmd+Q, Cmd+Space, line/word jumps) live at the bottom of
the generated config — uncomment to taste.

### The Ctrl guarantee

**Physical Ctrl is never remapped.** Plain Ctrl+C keeps sending SIGINT in
every terminal (real, VS Code integrated, web terminals). The scripts contain
a grep guard that aborts if a generated config would ever bind
`control`/`leftcontrol`/`rightcontrol` as a mapping source, and the install
verification re-checks the installed file.

### Terminal caveat

Without keyd's GNOME Shell extension there is no per-application scoping, so
the cmd-layer chords are global: in a terminal, Cmd+C sends Ctrl+C (SIGINT) —
use the terminal's native Ctrl+Shift+C / Ctrl+Shift+V to copy/paste there.

## Install

```bash
./install-mac-keys.sh            # add --dry-run to preview
```

- Installs keyd from the [`alternateved/keyd` COPR](https://copr.fedorainfracloud.org/coprs/alternateved/keyd/)
  (falls back to building from source if COPR fails); requires keyd >= 2.2.
- Confirms the real config path via `man keyd` (`.conf` vs `.cfg` differs
  across keyd versions) and writes a sentinel-marked config, backing up any
  pre-existing one.
- Enables/starts the `keyd` service and adds you to the `keyd` group
  (re-login needed for `keyd monitor`; the mappings themselves work
  immediately).
- Records everything it changed in `/var/lib/mac-keys-script/state`.
- Idempotent — safe to re-run; re-runs converge with no duplication.

## Uninstall

```bash
./uninstall-mac-keys.sh          # revert mappings only; keyd stays installed
./uninstall-mac-keys.sh --purge  # full teardown: remove keyd + COPR repo too
```

The default run restores your previous config (if one was backed up), reloads
keyd, and removes only what the installer added — it only ever deletes a
config carrying the script's sentinel marker. Running it when nothing is
installed exits 0 cleanly. Both scripts support `--dry-run`.

## Tested on

Fedora 44, GNOME on Wayland, ThinkPad X1 Carbon, keyd 2.6.0.
