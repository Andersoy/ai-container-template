# The container Claude Code and Codex run in. Nothing from the host comes in except the project directory
# and Claude's memory for it — no cloud logins, no tokens, no SSH keys.
#
# Built and started by scripts/ai-container.sh. It starts small on purpose: what is here is what
# Claude needs to work at all. Everything a particular project needs — a toolchain, a browser, a
# database client — is an optional block further down, commented out with what it costs. Uncomment
# what you need; the image is rebuilt once, on the next start.
#
# For a .NET project, swap the base image for Microsoft's, which carries the SDK and its runtime
# dependencies and sets DOTNET_RUNNING_IN_CONTAINER:
#   FROM mcr.microsoft.com/dotnet/sdk:10.0-noble
FROM ubuntu:24.04

ARG TZ=Europe/Oslo
ENV TZ=$TZ
ENV DEBIAN_FRONTEND=noninteractive

# No sudo on purpose. The firewall is raised by root before Claude starts, and Claude then runs as
# an ordinary user with no way back to root — so it cannot take the firewall down again.
#
# python3 and the network tools are not optional: the firewall script uses dig, iptables and ip, and
# Claude Code's hooks are commonly shell and Python.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git less procps jq zip unzip ripgrep \
      iptables iproute2 dnsutils \
      python3 \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Where every globally installed npm package goes, set before the first one is installed: npm's own
# default for root is elsewhere (/usr/lib/node_modules with this Node), and a package there is
# invisible to `npx`, which resolves through this prefix — so `npx <tool>` would quietly download the
# package again, at whatever version is newest, rather than use the one pinned here.
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global \
    PATH=/usr/local/share/npm-global/bin:$PATH

# ---------------------------------------------------------------------------------------------
# Optional. Uncomment a block to add it; each says what it gives and what it costs. Anything Claude
# installs during a session is gone the next time the container starts, so what the project always
# needs belongs here, where it is in the image and visible in git.
# ---------------------------------------------------------------------------------------------

# A real browser (~400 MB). Claude can open the app, click through it, read the console and take
# screenshots at phone and desktop width — the layout failures a type check cannot see. Chromium
# only, installed as root into shared paths: a browser under /home/ubuntu would live in a volume and
# be gone the next time the image changes. Pin the version, and if the project adds
# @playwright/test, move the two together — a browser build that does not match is refused.
# ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/ms-playwright
# RUN mkdir -p /usr/local/share/npm-global \
#     && npm install -g playwright@1.63.0 \
#     && npx playwright install --with-deps chromium \
#     && chmod -R a+rX /usr/local/share/ms-playwright \
#     && apt-get clean && rm -rf /var/lib/apt/lists/*

# Everything below is apt, so put what you want on one line and leave the rest out:
#   python3-numpy      (~30 MB)  arithmetic over data without writing a compiled program first
#   poppler-utils      (~20 MB)  reading PDFs — pages as images, or plain text
#   sqlite3            (~2 MB)   looking at a SQLite database by hand
#   postgresql-client  (~30 MB)  psql, for a Postgres the project talks to
#   build-essential    (~200 MB) a C toolchain, which some npm and Python packages build against
# RUN apt-get update && apt-get install -y --no-install-recommends \
#       python3-numpy poppler-utils sqlite3 \
#     && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------------------------

# The image's ordinary user is `ubuntu`, uid 1000 — the same number as yours on the host. Podman's
# keep-id mapping relies on that, so files Claude writes in the project are owned by you. This runs
# after the optional blocks, so anything root installed into the shared npm prefix is handed over.
RUN id ubuntu \
    && mkdir -p /usr/local/share/npm-global /home/ubuntu/.claude /home/ubuntu/.codex /home/ubuntu/.cache \
    && chown -R ubuntu:ubuntu /usr/local/share/npm-global /home/ubuntu

USER ubuntu
ENV HOME=/home/ubuntu
RUN npm install -g @anthropic-ai/claude-code
# OpenAI's agent, started with `scripts/ai-container.sh codex`. Pinned: its flags and its login change
# between releases. Its own sandbox works inside this container, so it runs with its defaults and
# asks before stepping outside them.
RUN npm install -g @openai/codex@0.160.0
# A tool the project always needs goes here too, pinned, and as this user. For example:
#   RUN dotnet tool install -g dotnet-ef --version 10.0.11    (then add ~/.dotnet/tools to PATH)

# start.sh raises the firewall, which needs root; it drops to `ubuntu` itself before Claude starts.
# Copied last, so a change to either script rebuilds only this step and not the installs above.
USER root
COPY init-firewall.sh start.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/init-firewall.sh /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
CMD ["claude"]
