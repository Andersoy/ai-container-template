#!/usr/bin/env bash
# Starts an AI coding agent inside a container, so a mistaken command cannot reach beyond this project.
#
#   scripts/ai-container.sh                     # menus: tool, network, ports, rebuild
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
#   - pushing, as long as no login is in here: no SSH key or git credential is mounted, so the
#     agents can commit but not push, and you review and push from the host. Claude's own sandbox
#     also lets its commands reach only sandbox_domains, which leaves out GitHub. Neither is a wall
#     against a token pasted into the session.
#
# Read-only inside, even though the rest of the project is writable: every path the host runs on its
# own. Git runs .git/hooks, and .git/config can point it at other programs; .claude holds hooks
# Claude Code runs; .idea and .vscode hold run configurations; .mcp.json and .codex name programs a
# Claude or Codex session on the host would start. A change there would run on the host
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
# This project's dev-server ports. They are published to this machine only (127.0.0.1), so a dev
# server started in here can be opened in the browser out there, while the packages it runs stay in
# here. The menu offers them ticked; --port adds others.
ports=()
# Hosts Claude's own sandbox lets its shell commands reach — npm, dotnet restore, curl. Its own web
# tools (search, fetch) are outside the sandbox and reach what the container's firewall allows. The
# list starts empty, and a host not on it is refused without asking, so add here what the project needs.
# Add the APIs the project itself calls when it is run in here (api.anthropic.com, api.telegram.org, ...).
sandbox_domains=(registry.npmjs.org api.nuget.org
  # NuGet checks that a package's signing certificate has not been revoked; unreachable, it skips
  # the check without saying so.
  crl3.digicert.com crl4.digicert.com ocsp.digicert.com)
# Where those commands may write besides the project: the package caches. They live only in this
# container's volumes, not on the host.
# They must also exist in the image (the mkdir in .devcontainer/Dockerfile): the sandbox can only open
# folders that are there. Keep the two lists in step.
sandbox_writable=("~/.npm" "~/.nuget" "~/.local/share/NuGet" "~/.dotnet" "~/.templateengine" "~/.cache")

usage() {
  echo "Usage: scripts/ai-container.sh                       (menus)"
  echo "       scripts/ai-container.sh [--strict] [--rebuild] [--port N]... <claude|codex|bash> [arguments for it]"
  echo "First time with Codex: scripts/ai-container.sh codex login --device-auth"
}

# --rebuild builds the image from scratch, fetching the base image and every package anew. Without
# it the build is cached, so Claude Code, Node and the Ubuntu packages stay at whatever versions the
# first build got. Run it now and then, and when a security fix is out.
firewall_mode=open
rebuild=()
published=()
port_flag=false
# Menus when started with nothing after it, in a terminal, and whiptail is there (it is on Ubuntu).
interactive=false
if [ $# -eq 0 ] && [ -t 0 ] && [ -t 1 ] && command -v whiptail >/dev/null; then interactive=true; fi
$interactive || published=("${ports[@]}")
while :; do
  case "${1:-}" in
    --strict) firewall_mode=strict; shift ;;
    --rebuild) rebuild=(--no-cache --pull); shift ;;
    --port)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "--port needs a port number"; usage; exit 1; }
      published+=("$2"); port_flag=true; shift 2 ;;
    *) break ;;
  esac
done

tool=""
if ! $interactive; then
  tool="${1:-}"
  case "$tool" in
    claude|codex|bash) shift ;;
    ""|-h|--help) usage; exit 1 ;;
    *) echo "Unknown tool: $tool"; usage; exit 1 ;;
  esac
fi

command -v podman >/dev/null || { echo "Podman is not installed. Run: sudo apt install -y podman uidmap passt"; exit 1; }
# The image's user is uid 1000 and keep-id maps yours onto it; anything else gives files owned by a
# stranger, so say so instead.
[ "$(id -u)" = 1000 ] || { echo "This setup expects uid 1000; you are $(id -u)."; exit 1; }

# A project with no .gitignore is offered the standard one, once. "No" is remembered outside the
# project, so the question does not come back; Esc just skips it this time.
gitignore_declined="${XDG_CACHE_HOME:-$HOME/.cache}/ai-container/gitignore-declined-$(printf '%s' "$root" | sha1sum | cut -c1-12)"
if [ ! -e "$root/.gitignore" ] && [ -f "$root/.devcontainer/project.gitignore" ] && [ ! -e "$gitignore_declined" ]; then
  if [ -t 0 ] && [ -t 1 ] && command -v whiptail >/dev/null; then
    answer=0
    whiptail --title "AI container — $project" --yesno "This project has no .gitignore.\n\nAdd the standard one? It keeps IDE settings, personal Claude settings, notes/, node_modules/, build output and local env files out of git. You can edit it afterwards.\n\nNo is remembered for this project." 15 74 || answer=$?
    case $answer in
      0) cp "$root/.devcontainer/project.gitignore" "$root/.gitignore"; echo "==> Added .gitignore" ;;
      1) mkdir -p "$(dirname "$gitignore_declined")"; : > "$gitignore_declined" ;;
    esac
  else
    echo "Note: this project has no .gitignore; a standard one is in .devcontainer/project.gitignore" >&2
  fi
fi
[ -d "$root/.devcontainer" ] || { echo "No .devcontainer/ next to scripts/ — copy the whole template in."; exit 1; }

# A terminal only when there is one, so the same script also runs from scripts and checks.
tty=(-i); [ -t 0 ] && [ -t 1 ] && tty=(-it)

# Already running: start the tool in that container, as the same unprivileged user.
# (`podman container exists` is true for a stopped one too, which would send us into a dead container.)
running=false
[ -n "$(podman ps --filter "name=^${name}$" --format '{{.Names}}')" ] && running=true

if $interactive; then
  title="AI container — $project"
  ask() { whiptail --title "$title" "$@" 3>&1 1>&2 2>&3; }
  if $running; then
    note="The container is already running. Network, ports and image were fixed when it started; to change them, stop it first."
  else
    note="Choose the tool to start."
  fi
  tool="$(ask --menu "$note" 14 74 3 \
    claude "Claude Code" codex "OpenAI Codex" bash "A shell")" || { echo "Cancelled."; exit 0; }
  if ! $running; then
    firewall_mode="$(ask --default-item open --menu "Network" 13 74 2 \
      open   "Web open; home network, other ports and IPv6 shut" \
      strict "Only the hosts in .devcontainer/init-firewall.sh")" || { echo "Cancelled."; exit 0; }
    if [ ${#ports[@]} -gt 0 ]; then
      items=(); for port in "${ports[@]}"; do items+=("$port" "localhost:$port" ON); done
      choice="$(ask --separate-output --checklist \
        "Ports to open to this machine, for dev servers (space toggles)" 15 74 6 "${items[@]}")" \
        || { echo "Cancelled."; exit 0; }
      while IFS= read -r port; do [ -n "$port" ] && published+=("$port"); done <<< "$choice"
    fi
    extra="$(ask --inputbox "Other ports to open, separated by spaces (leave empty for none)" 9 74 "")" \
      || { echo "Cancelled."; exit 0; }
    for port in $extra; do
      [[ "$port" =~ ^[0-9]+$ ]] || { echo "Not a port number: $port"; exit 1; }
      published+=("$port")
    done
    if ask --defaultno --yesno "Rebuild the image from scratch?\n\nFetches the base image and every package anew — worth doing monthly and after a security fix. Takes a few minutes." 12 74; then
      rebuild=(--no-cache --pull)
    fi
  fi
fi

# Claude Code's own sandbox, around each command it runs, inside this container's walls. In here it
# has to use the container's /proc (enableWeakerNestedSandbox), which lets a sandboxed command see the
# container's other processes; the container is the boundary that matters. Given on the command line
# from this read-only script, so it can be neither weakened from inside nor leak into host sessions,
# as a setting in .claude/ would. failIfUnavailable: no sandbox, no start, rather than none in silence.
tool_cmd=("$tool")
# Codex: no update check at start. The image decides its version (see the Dockerfile).
[ "$tool" = codex ] && tool_cmd=(codex -c check_for_update_on_startup=false)
if [ "$tool" = claude ]; then
  domains="$(printf '"%s",' "${sandbox_domains[@]}")"
  writable="$(printf '"%s",' "${sandbox_writable[@]}")"
  tool_cmd=(claude --settings "{\"sandbox\":{\"enabled\":true,\"enableWeakerNestedSandbox\":true,\"failIfUnavailable\":true,\"network\":{\"allowedDomains\":[${domains%,}]},\"filesystem\":{\"allowWrite\":[${writable%,}]}}}")
fi

if $running; then
  # The firewall, the ports, the keys and the image were fixed when it started; nothing here changes
  # them. Asked for and not possible is a stop, not a warning: --strict above all, since carrying on
  # would give open network to someone who asked for it shut.
  if [ "$firewall_mode" = strict ] || [ ${#rebuild[@]} -gt 0 ] || $port_flag; then
    echo "Already running — --strict, --rebuild and --port only apply when the container starts. Stop it first." >&2
    exit 1
  fi
  exec podman exec "${tty[@]}" --user 1000:1000 -w "$root" "$name" "${tool_cmd[@]}" "$@"
fi

echo "==> Building the image (cached after the first time)"
podman build -q "${rebuild[@]}" -t "$image" "$root/.devcontainer" >/dev/null

# What the host runs on its own, read-only in here. Created first when missing: a directory that does
# not exist cannot be mounted, and one the agent could create here is one the IDE would later run
# from out there — a run configuration in .idea or .run, a hook, a task in .vscode.
# .mcp.json is a file and is protected only when it exists; a new one made in here still needs your
# approval in a host session before Claude starts what it names.
for dir in .claude .codex .idea .vscode .run; do mkdir -p "$root/$dir"; done
protected=(.git/hooks .git/config .claude .codex .mcp.json .idea .vscode .run .npmrc .devcontainer scripts/ai-container.sh)
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

# Keys for the agents' own test runs, so they can run the project against real APIs from in here.
# Off until needed: uncomment the block, and put one NAME=value per line in ~/.config/<project>/agent.env
# (chmod 600, outside the repository). Use keys of their own, never production's — test accounts, and
# API keys in a workspace or project with a small spend limit — since with the web open a key in here
# is a key that could leave.
#
# Only the names listed are passed on, whatever else the file holds. Never ANTHROPIC_API_KEY or
# OPENAI_API_KEY: Claude Code and Codex would take those for their own conversations and bill them.
# They go in by name (-e NAME), so the values never appear on a command line.
agent_env=()
# agent_env_file="$HOME/.config/$project/agent.env"
# if [ -f "$agent_env_file" ]; then
#   if [ -n "$(find "$agent_env_file" -perm /077)" ]; then
#     echo "Refusing $agent_env_file: others can read it. Run: chmod 600 $agent_env_file"; exit 1
#   fi
#   for key in Anthropic__ApiKey; do        # the names the project's code reads
#     value="$(sed -n "s/^$key=//p" "$agent_env_file" | tail -n 1)"
#     if [ -n "$value" ]; then
#       export "$key=$value"
#       agent_env+=(-e "$key")
#     fi
#   done
#   unset value
# fi

# Published to 127.0.0.1 only: this machine's browser reaches them, nothing else on the network does.
publish=()
for port in "${published[@]}"; do publish+=(-p "127.0.0.1:$port:$port"); done
if [ ${#published[@]} -gt 0 ]; then echo "==> Ports open to this machine: ${published[*]}"; fi

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
  -e PUBLISHED_PORTS="${published[*]}" \
  "${publish[@]}" \
  "${mounts[@]}" \
  -v "$volumes-config:/home/ubuntu/.claude" \
  -v "$volumes-codex:/home/ubuntu/.codex" \
  -v "$volumes-cache:/home/ubuntu/.cache" \
  -v "$volumes-npm:/home/ubuntu/.npm" \
  -v "$volumes-nuget:/home/ubuntu/.nuget" \
  -e CLAUDE_CONFIG_DIR=/home/ubuntu/.claude \
  "${git_env[@]}" \
  "${agent_env[@]}" \
  -w "$root" \
  "$image" "${tool_cmd[@]}" "$@"
