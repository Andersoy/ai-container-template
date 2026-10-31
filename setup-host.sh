#!/usr/bin/env bash
# Prepares a machine (Ubuntu, or Ubuntu under WSL2) for the AI container and for Claude Code's
# sandbox on the host. Run it once per machine; it checks each step first and only does what is
# missing, so running it again is safe.
#
#   ./setup-host.sh           # do what is missing, asking before each change
#   ./setup-host.sh --check   # only report what is in place and what is not
#
# It asks for your password through sudo for packages and AppArmor, and never handles a key or token.
set -euo pipefail

check_only=false
case "${1:-}" in
  --check) check_only=true ;;
  "") ;;
  *) echo "Usage: ./setup-host.sh [--check]"; exit 1 ;;
esac

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
todo() { printf '  \033[33mmissing\033[0m %s\n' "$*"; missing=$((missing + 1)); }
note() { printf '  \033[36mnote\033[0m  %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
explain() { sed 's/^/  /' <<< "$1"; }
confirm() {
  local answer
  read -r -p "  $1 [y/N] " answer
  [[ "$answer" =~ ^[YyJj] ]]
}
missing=0

wsl=false
grep -qi microsoft /proc/version 2>/dev/null && wsl=true

# --- 1. Packages ------------------------------------------------------------------------------
step "1. Packages"
explain "podman, uidmap and passt run the containers without root. bubblewrap and socat are what
Claude Code's sandbox is built from, on the host and inside the containers. whiptail draws the
launcher's menus. All come from Ubuntu's own archive."
packages=(podman uidmap passt bubblewrap socat whiptail)
absent=()
for pkg in "${packages[@]}"; do
  if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
    ok "$pkg"
  else
    todo "$pkg"; absent+=("$pkg")
  fi
done
if [ ${#absent[@]} -gt 0 ] && ! $check_only; then
  echo "  This downloads ${absent[*]} and what they need (some tens of MB)."
  if confirm "Install with sudo apt install?"; then
    sudo apt-get update
    sudo apt-get install -y "${absent[@]}"
  fi
fi

# --- 2. AppArmor ------------------------------------------------------------------------------
step "2. AppArmor profile for bubblewrap"
explain "Ubuntu 24.04 and later stop ordinary programs from creating user namespaces — the trick
bubblewrap uses to build its sandbox — unless an AppArmor profile allows that program. This adds
the profile from the Claude Code documentation, the same form Ubuntu ships for Podman."
restrict_file=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
profile=/etc/apparmor.d/bwrap
if [ ! -r "$restrict_file" ] || [ "$(cat "$restrict_file")" != 1 ]; then
  ok "user namespaces are not restricted here$($wsl && echo ' (WSL2)') — no profile needed"
elif [ -f "$profile" ]; then
  ok "$profile is in place"
else
  todo "$profile"
  if ! $check_only && confirm "Add the profile and load it (sudo)?"; then
    sudo tee "$profile" >/dev/null <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
EOF
    sudo apparmor_parser -r "$profile"
    ok "profile loaded"
  fi
fi

# --- 3. Claude Code settings on the host ------------------------------------------------------
step "3. Claude Code settings on the host (~/.claude/settings.json)"
explain "Sessions on the host ask before every command (bypass and auto mode are switched off), and
run commands inside the sandbox: writes only to the project, and the folders with credentials
unreadable. Your other settings are kept; the file is backed up before it changes."
settings="$HOME/.claude/settings.json"
merge_settings() {  # $1 = check | write; prints what differs, exits 1 if anything does
  python3 -I - "$settings" "$1" <<'PY'
import json, os, shutil, sys, time
path, mode = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as e:
    sys.exit(f"  {path} is not valid JSON ({e}); fix it by hand first")

want = {
    ("permissions", "defaultMode"): "default",
    ("permissions", "disableBypassPermissionsMode"): "disable",
    ("permissions", "disableAutoMode"): "disable",
    ("sandbox", "enabled"): True,
    ("sandbox", "autoAllowBashIfSandboxed"): False,
    ("sandbox", "failIfUnavailable"): True,
}
denied = ["~/.ssh", "~/.azure", "~/.git-credentials", "~/.microsoft/usersecrets"]

changes = []
for (section, key), value in want.items():
    block = data.setdefault(section, {})
    if block.get(key) != value:
        changes.append(f"{section}.{key} = {json.dumps(value)}")
        block[key] = value
files = data["sandbox"].setdefault("credentials", {}).setdefault("files", [])
for p in denied:
    if not any(e.get("path") == p and e.get("mode") == "deny" for e in files):
        changes.append(f"sandbox.credentials.files: deny {p}")
        files.append({"path": p, "mode": "deny"})

for c in changes:
    print(f"  {'missing' if mode == 'check' else 'set'}  {c}")
if changes and mode == "write":
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        backup = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(path, backup)
        print(f"  backup: {backup}")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    json.load(open(tmp))  # what we wrote must read back
    os.replace(tmp, path)
sys.exit(1 if changes and mode == "check" else 0)
PY
}
if merge_settings check; then
  ok "lock and sandbox are set"
else
  missing=$((missing + 1))
  if ! $check_only && confirm "Write these into $settings?"; then
    merge_settings write
    ok "settings written"
  fi
fi
note "Project secrets in ~/.config/<project> are added to sandbox.credentials.files by hand."

# --- 4. ai-container on PATH ------------------------------------------------------------------
step "4. The ai-container command"
explain "A link in ~/.local/bin to the launcher in this folder, so \`ai-container\` works in every
project. Projects hold only their settings; a \`git pull\` here updates the launcher for all of them."
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
link="$HOME/.local/bin/ai-container"
if [ "$(readlink -f "$link" 2>/dev/null)" = "$here/bin/ai-container" ]; then
  ok "$link -> $here/bin/ai-container"
elif [ -e "$link" ] || [ -L "$link" ]; then
  todo "$link exists but points elsewhere; move it aside, then run this again"
else
  todo "$link"
  if ! $check_only && confirm "Create the link?"; then
    mkdir -p "$HOME/.local/bin"
    ln -s "$here/bin/ai-container" "$link"
    ok "link created"
  fi
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ok "~/.local/bin is on PATH" ;;
  *) note "~/.local/bin is not on PATH yet. Ubuntu's ~/.profile adds it at login once the folder exists: log out and in, or open a new login shell." ;;
esac

# --- 5. Checks that only report ---------------------------------------------------------------
step "5. The rest of the machine (reported, not changed)"

if [ "$(id -u)" = 1000 ]; then
  ok "your user id is 1000, as the image's user is"
else
  note "your user id is $(id -u), not 1000: files the container writes may show up with another owner"
fi

if grep -q "^$(id -un):" /etc/subuid 2>/dev/null && grep -q "^$(id -un):" /etc/subgid 2>/dev/null; then
  ok "subordinate user ids in /etc/subuid and /etc/subgid (rootless Podman needs them)"
else
  todo "no line for $(id -un) in /etc/subuid or /etc/subgid — see the rootless section of Podman's docs"
fi

if command -v podman >/dev/null; then
  runtime="$(podman info --format '{{.Host.OCIRuntime.Name}} {{.Host.OCIRuntime.Path}}' 2>/dev/null || true)"
  rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
  [ "$rootless" = true ] && ok "Podman runs rootless" || todo "Podman does not answer as rootless (podman info)"
  if [ -n "$runtime" ]; then
    owner="$(dpkg -S "$(readlink -f "${runtime#* }")" 2>/dev/null | cut -d: -f1 || true)"
    if [ "$owner" = containerd.io ]; then
      ok "runtime: $runtime, from containerd.io (keep that package installed)"
    else
      note "runtime: $runtime, from ${owner:-an unknown package}. Ubuntu's runc/crun in universe go unpatched without Ubuntu Pro; Docker's containerd.io carries a maintained runc."
    fi
  fi
fi

for unit in docker.service docker.socket podman.socket; do
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    note "$unit is running system-wide; the containers do not need it (sudo systemctl disable --now $unit)"
  fi
done

if command -v bwrap >/dev/null; then
  if bwrap --ro-bind / / --dev /dev --proc /proc --unshare-all true 2>/dev/null; then
    ok "bubblewrap can build a sandbox, network included"
  else
    todo "bubblewrap fails to build a sandbox — see step 2"
  fi
fi

command -v claude >/dev/null && ok "Claude Code: $(claude --version 2>/dev/null | head -1)" \
  || note "Claude Code is not installed: https://code.claude.com/docs"

echo
if [ "$missing" -eq 0 ]; then
  echo "All in place."
elif $check_only; then
  echo "$missing item(s) missing. Run ./setup-host.sh without --check to set them up."
else
  echo "$missing item(s) were missing; run ./setup-host.sh --check to see what is left."
fi
