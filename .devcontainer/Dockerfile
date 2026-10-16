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
# Claude Code's hooks are commonly shell and Python. Nor are bubblewrap and socat: the launcher starts
# Claude with its own sandbox around each command, and on Linux that sandbox is built from these two.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git less procps jq zip unzip ripgrep \
      iptables iproute2 dnsutils \
      python3 bubblewrap socat \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# A company network that inspects encrypted traffic re-signs it with its own root certificate, and
# npm, Claude Code and Playwright then fail with "self-signed certificate in certificate chain". Put
# the certificate in .devcontainer/ and uncomment. Node keeps its own list of authorities, so it needs
# NODE_EXTRA_CA_CERTS as well as the system store. A proxy on a port other than 80 or 443 also needs
# letting through in init-firewall.sh.
# COPY company-root.crt /usr/local/share/ca-certificates/company-root.crt
# RUN update-ca-certificates
# ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/company-root.crt

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
# The folders on the second line are where Claude's own sandbox lets commands write (sandbox_writable
# in the launcher). The sandbox can only open folders that exist — it cannot create one in a home
# directory it keeps read-only — so they are made here, empty, whether or not a project uses them.
RUN id ubuntu \
    && mkdir -p /usr/local/share/npm-global /home/ubuntu/.claude /home/ubuntu/.codex /home/ubuntu/.cache /home/ubuntu/.npm \
       /home/ubuntu/.nuget /home/ubuntu/.dotnet /home/ubuntu/.templateengine /home/ubuntu/.local/share/NuGet \
    && chown -R ubuntu:ubuntu /usr/local/share/npm-global /home/ubuntu

USER ubuntu
ENV HOME=/home/ubuntu
# The two agents, at the newest release when the image is built. The image decides the version: Claude
# is told not to update itself (DISABLE_UPDATES), and the launcher tells Codex not to check. An update
# made inside would live only until the container stops, so two sessions could run different versions.
# --rebuild is how they move on. If a release ever breaks the launcher, pin it here (@x.y.z) until
# the launcher is fixed.
ENV DISABLE_UPDATES=1
RUN npm install -g @anthropic-ai/claude-code
# OpenAI's agent, started with `scripts/ai-container.sh codex`. Its own sandbox works inside this
# container, so it runs with its defaults and asks before stepping outside them.
RUN npm install -g @openai/codex
# A tool the project always needs goes here too, pinned, and as this user. For example:
#   RUN dotnet tool install -g dotnet-ef --version 10.0.11    (then add ~/.dotnet/tools to PATH)

# start.sh raises the firewall, which needs root; it drops to `ubuntu` itself before Claude starts.
# Copied last, so a change to either script rebuilds only this step and not the installs above.
USER root
COPY init-firewall.sh start.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/init-firewall.sh /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
CMD ["claude"]
