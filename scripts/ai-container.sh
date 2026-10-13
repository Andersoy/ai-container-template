#!/usr/bin/env bash
# Starts an AI coding agent inside a container, so a mistaken command cannot reach beyond this project.
#
#   scripts/ai-container.sh claude              # Claude Code
#   scripts/ai-container.sh codex               # OpenAI Codex
#   scripts/ai-container.sh bash                # a shell, to look around
#   scripts/ai-container.sh --strict claude     # any of them, with only the hosts in init-firewall.sh
#
# Anything after the tool goes to it: `scripts/ai-container.sh codex login --device-auth` signs Codex
# in, which is needed once — its ordinary login sends the browser back to an address inside the
# container, which the host cannot reach. If the container is already running, the tool starts in
# that one rather than a second, so Claude and Codex can work side by side.
#
# The container lives exactly as long as the program it was started with, and is deleted when that
# ends. Only the project, Claude's memory, the logins and the caches carry over; anything installed
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
name="ai-${project//[^a-zA-Z0-9_.-]/-}"
image="localhost/$name"
# Named volumes holding the logins, Claude's sessions and the caches. Changing this starts them over.
volumes="$name"

usage() {
  echo "Usage: scripts/ai-container.sh [--strict] [--rebuild] <claude|codex|bash> [arguments for it]"
  echo "First time with Codex: scripts/ai-container.sh codex login --device-auth"
}

# --rebuild builds the image from scratch, fetching the base image and every package anew. Without
# it the build is cached, so Claude Code, Node and the Ubuntu packages stay at whatever versions the
# first build got. Run it now and then, and when a security fix is out.
firewall_mode=open
rebuild=()
while :; do
  case "${1:-}" in
    --strict) firewall_mode=strict; shift ;;
    --rebuild) rebuild=(--no-cache --pull); shift ;;
    *) break ;;
  esac
done

tool="${1:-}"
case "$tool" in
  claude|codex|bash) shift ;;
  ""|-h|--help) usage; exit 1 ;;
  *) echo "Unknown tool: $tool"; usage; exit 1 ;;
esac

command -v podman >/dev/null || { echo "Podman is not installed. Run: sudo apt install -y podman uidmap passt"; exit 1; }
# The image's user is uid 1000 and keep-id maps yours onto it; anything else gives files owned by a
# stranger, so say so instead.
[ "$(id -u)" = 1000 ] || { echo "This setup expects uid 1000; you are $(id -u)."; exit 1; }
[ -d "$root/.devcontainer" ] || { echo "No .devcontainer/ next to scripts/ — copy the whole template in."; exit 1; }

# A terminal only when there is one, so the same script also runs from scripts and checks.
tty=(-i); [ -t 0 ] && [ -t 1 ] && tty=(-it)

# Already running: start the tool in that container, as the same unprivileged user.
# (`podman container exists` is true for a stopped one too, which would send us into a dead container.)
if [ -n "$(podman ps --filter "name=^${name}$" --format '{{.Names}}')" ]; then
  # The firewall, the keys and the image were fixed when it started; nothing here can change them.
  if [ "$firewall_mode" = strict ] || [ ${#rebuild[@]} -gt 0 ]; then
    echo "Already running — --strict and --rebuild only apply when the container starts. Stop it first." >&2
  fi
  exec podman exec "${tty[@]}" --user 1000:1000 -w "$root" "$name" "$tool" "$@"
fi

echo "==> Building the image (cached after the first time)"
podman build -q "${rebuild[@]}" -t "$image" "$root/.devcontainer" >/dev/null

# What the host runs on its own, read-only in here. Created first when missing: a directory that does
# not exist cannot be mounted, and one the agent could create here is one the IDE would later run
# from out there — a run configuration in .idea or .run, a hook, a task in .vscode.
for dir in .claude .idea .vscode .run; do mkdir -p "$root/$dir"; done
protected=(.git/hooks .git/config .claude .idea .vscode .run .npmrc .devcontainer scripts/ai-container.sh)
# A hook directory of the project's own (husky and the like) runs on the host at every commit.
hooks_path="$(git -C "$root" config core.hooksPath || true)"
[ -n "$hooks_path" ] && [ "${hooks_path#/}" = "$hooks_path" ] && protected+=("$hooks_path")
# IDE folders deeper in, where a sub-project was opened on its own. Only the ones that exist; the
# root's are the ones an IDE opens by default.
while IFS= read -r dir; do protected+=("${dir#"$root"/}"); done < <(
  find "$root" -mindepth 2 -maxdepth 4 \( -name node_modules -o -name .git -o -name bin -o -name obj \) -prune \
    -o -type d \( -name .idea -o -name .vscode -o -name .run \) -print)

mounts=(-v "$root:$root")
for path in "${protected[@]}"; do
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

# --memory and --pids-limit cap what a runaway build, test or loop can take from the machine (or from
# WSL, where it would take everything else in WSL down with it). Raise them here if a project needs more.
# --user 0 only for start.sh, which raises the firewall and then drops to your uid for good.
# keep-id maps your uid to the same number inside, so files written here are owned by you.
exec podman run --rm "${tty[@]}" \
  --name "$name" \
  --hostname "$name" \
  --userns=keep-id \
  --user 0:0 \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --security-opt=no-new-privileges \
  --memory 8g --pids-limit 4096 \
  --sysctl net.ipv6.conf.all.disable_ipv6=1 \
  --sysctl net.ipv6.conf.default.disable_ipv6=1 \
  -e FIREWALL_MODE="$firewall_mode" \
  "${mounts[@]}" \
  -v "$volumes-config:/home/ubuntu/.claude" \
  -v "$volumes-codex:/home/ubuntu/.codex" \
  -v "$volumes-cache:/home/ubuntu/.cache" \
  -v "$volumes-npm:/home/ubuntu/.npm" \
  -e CLAUDE_CONFIG_DIR=/home/ubuntu/.claude \
  "${git_env[@]}" \
  -w "$root" \
  "$image" "$tool" "$@"
