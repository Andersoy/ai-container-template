#!/usr/bin/env bash
# Starts Claude Code inside a container, so a mistaken command cannot reach beyond this project.
#
#   scripts/claude-container.sh            # start Claude, web traffic open
#   scripts/claude-container.sh --strict   # start Claude, only the hosts in init-firewall.sh
#   scripts/claude-container.sh bash       # a shell: in the running container if Claude is up,
#                                          # otherwise in a fresh one
#
# The container lives exactly as long as the program it was started with, and is deleted when that
# ends. Only the project, Claude's memory, its login and the caches carry over; anything installed
# during a session is gone next time, so a tool the project always needs belongs in the Dockerfile.
#
# What the container can reach:
#   - this project, at the same path as on the host, so Claude's memory for it still lines up
#   - the web, or with --strict only the hosts in .devcontainer/init-firewall.sh
# What it cannot:
#   - your cloud logins, tokens, SSH keys, or anything else in your home directory
#   - other projects, or other processes on this machine
#   - pushing — you review and push from the host
#
# Read-only inside, even though the rest of the project is writable: every path the host runs on its
# own. Git runs .git/hooks, and .git/config can point it at other programs; .claude holds hooks
# Claude Code runs; .idea and .vscode hold run configurations. A change there would run on the host
# with all your credentials. The container's own definition is read-only for the same reason: it
# must not be able to loosen itself.
#
# One limit no mount fixes: the project is shared, and building or running it on the host runs its
# code there. Read the diff before you run anything on the host — scripts included.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$(basename "$root")"
name="claude-${project//[^a-zA-Z0-9_.-]/-}"
image="localhost/$name"

firewall_mode=open
if [ "${1:-}" = --strict ]; then firewall_mode=strict; shift; fi

command -v podman >/dev/null || { echo "Podman is not installed. Run: sudo apt install -y podman uidmap passt"; exit 1; }
[ -d "$root/.devcontainer" ] || { echo "No .devcontainer/ next to scripts/ — copy the whole template in."; exit 1; }

# A terminal only when there is one, so the same script also runs from scripts and checks.
tty=(-i); [ -t 0 ] && [ -t 1 ] && tty=(-it)

# Already running: join it as the same unprivileged user rather than starting a second one.
# (`podman container exists` is true for a stopped one too, which would send us into a dead container.)
if [ -n "$(podman ps --filter "name=^${name}$" --format '{{.Names}}')" ]; then
  exec podman exec "${tty[@]}" --user 1000:1000 -w "$root" "$name" "${@:-bash}"
fi

echo "==> Building the image (cached after the first time)"
podman build -q -t "$image" "$root/.devcontainer" >/dev/null

mounts=(-v "$root:$root")
for path in .git/hooks .git/config .claude .idea .vscode .devcontainer scripts/claude-container.sh; do
  if [ -e "$root/$path" ]; then
    mounts+=(-v "$root/$path:$root/$path:ro")
  fi
done

# Claude keeps its memory per project, under a name taken from the working directory. Mounting the
# project at the same path keeps that name, so the memory written on the host is found in here.
project_key="$(echo "$root" | sed 's#[/.]#-#g')"
memory="$HOME/.claude/projects/$project_key/memory"
mkdir -p "$memory"
mounts+=(-v "$memory:/home/ubuntu/.claude/projects/$project_key/memory")

# Commits made inside carry your name. git's own config is read-only in there, so it comes this way.
git_env=()
git_name="$(git -C "$root" config user.name || true)"
git_email="$(git -C "$root" config user.email || true)"
[ -n "$git_name" ] && git_env+=(-e "GIT_AUTHOR_NAME=$git_name" -e "GIT_COMMITTER_NAME=$git_name")
[ -n "$git_email" ] && git_env+=(-e "GIT_AUTHOR_EMAIL=$git_email" -e "GIT_COMMITTER_EMAIL=$git_email")

# --user 0 only for start.sh, which raises the firewall and then drops to your uid for good.
# keep-id maps your uid to the same number inside, so files written here are owned by you.
exec podman run --rm "${tty[@]}" \
  --name "$name" \
  --hostname "$name" \
  --userns=keep-id \
  --user 0:0 \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --security-opt=no-new-privileges \
  --sysctl net.ipv6.conf.all.disable_ipv6=1 \
  --sysctl net.ipv6.conf.default.disable_ipv6=1 \
  -e FIREWALL_MODE="$firewall_mode" \
  "${mounts[@]}" \
  -v "$name-config:/home/ubuntu/.claude" \
  -v "$name-cache:/home/ubuntu/.cache" \
  -e CLAUDE_CONFIG_DIR=/home/ubuntu/.claude \
  "${git_env[@]}" \
  -w "$root" \
  "$image" "$@"
