#!/bin/bash
# Entry point: raise the firewall as root, then hand over to the ordinary user for good.
#
# setpriv drops to uid 1000 with no capabilities, an empty bounding set and no_new_privs. That last
# one means nothing started afterwards can gain privileges again — not a setuid binary, not anything.
# Whatever Claude runs cannot reach iptables, so the firewall stays as it was raised.
set -euo pipefail

/usr/local/bin/init-firewall.sh

# Podman creates the directories leading to a mount inside a volume, and creates them as root.
# Claude writes its session transcripts there, and Codex its login, so without this every write
# fails with EACCES.
# Only the directories themselves change owner, never their contents.
for dir in /home/ubuntu/.claude /home/ubuntu/.claude/projects /home/ubuntu/.claude/projects/*/ /home/ubuntu/.codex; do
  if [ -d "$dir" ] && [ ! -L "${dir%/}" ]; then chown ubuntu:ubuntu "$dir"; fi
done

exec setpriv --reuid=1000 --regid=1000 --clear-groups \
  --inh-caps=-all --bounding-set=-all --no-new-privs \
  env HOME=/home/ubuntu USER=ubuntu LOGNAME=ubuntu "$@"
