# The container Claude Code and Codex run in. Nothing from the host comes in except the project directory
# and Claude's memory for it — no cloud logins, no tokens, no SSH keys.
#
# Built by ai-container for every project, from what the project's .devcontainer/ai-container.conf
# asks for: the base image and extra apt packages. It starts small on purpose: what is here is what
# Claude needs to work at all. Anything more particular — a browser, a pinned tool — goes in the
# project's own .devcontainer/Dockerfile, which builds on this image (see templates/Dockerfile).
#
# base_image is Ubuntu 24.04 by default. A .NET project sets Microsoft's SDK image, which is Ubuntu
# 24.04 underneath, carries the SDK, and sets DOTNET_RUNNING_IN_CONTAINER.
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG TZ=Europe/Oslo
ENV TZ=$TZ
ENV DEBIAN_FRONTEND=noninteractive

# The time of the last --rebuild, from the launcher. A new value makes every step below run again —
# that is how a rebuild fetches the packages anew — and the same value lets later starts reuse them.
ARG REBUILT=0
RUN echo "$REBUILT" > /etc/ai-container-rebuilt

# No sudo on purpose. The firewall is raised by root before Claude starts, and Claude then runs as
# an ordinary user with no way back to root — so it cannot take the firewall down again.
#
# python3 and the network tools are not optional: the firewall script uses dig, iptables and ip, and
# Claude Code's hooks are commonly shell and Python. Nor are bubblewrap and socat: the launcher starts
# Claude with its own sandbox around each command, and on Linux that sandbox is built from these two.
# APT_PACKAGES is the project's apt_packages, which the launcher has checked are package names only.
ARG APT_PACKAGES=""
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git less procps jq zip unzip ripgrep \
      iptables iproute2 dnsutils \
      python3 bubblewrap socat \
      ${APT_PACKAGES} \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# A company network that inspects encrypted traffic re-signs it with its own root certificate, and
# npm, Claude Code and Playwright then fail with "self-signed certificate in certificate chain". The
# certificate belongs to the machine's network, not to a project: put it in
# ~/.config/ai-container/company-root.crt on that machine, and the launcher brings it into the build
# (otherwise an empty file comes in, and nothing changes). Node keeps its own list of authorities, so
# it is pointed at the system store as well, which then holds the certificate.
COPY company-root.crt /usr/local/share/ca-certificates/company-root.crt
RUN if [ -s /usr/local/share/ca-certificates/company-root.crt ]; then update-ca-certificates; \
    else rm /usr/local/share/ca-certificates/company-root.crt; fi
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Where every globally installed npm package goes, set before the first one is installed: npm's own
# default for root is elsewhere (/usr/lib/node_modules with this Node), and a package there is
# invisible to `npx`, which resolves through this prefix — so `npx <tool>` would quietly download the
# package again, at whatever version is newest, rather than use the one pinned here.
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global \
    PATH=/usr/local/share/npm-global/bin:$PATH

# The image's ordinary user is `ubuntu`, uid 1000 — the same number as yours on the host. Podman's
# keep-id mapping relies on that, so files Claude writes in the project are owned by you.
# The folders on the second line are where Claude's own sandbox lets commands write (sandbox_writable
# in the launcher). The sandbox can only open folders that exist — it cannot create one in a home
# directory it keeps read-only — so they are made here, empty, whether or not a project uses them.
RUN id ubuntu \
    && mkdir -p /usr/local/share/npm-global /home/ubuntu/.claude /home/ubuntu/.codex /home/ubuntu/.cache /home/ubuntu/.npm \
       /home/ubuntu/.nuget /home/ubuntu/.dotnet /home/ubuntu/.templateengine /home/ubuntu/.local/share/NuGet \
    && chown -R ubuntu:ubuntu /usr/local/share/npm-global /home/ubuntu

USER ubuntu
# The .NET lines do nothing in an image without .NET.
ENV HOME=/home/ubuntu \
    PATH=/home/ubuntu/.dotnet/tools:$PATH \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1
# The .NET SDK's first-run setup, done here once. Otherwise the first dotnet command in every new
# container does it, takes a mutex under /tmp/.dotnet/shm, which Claude's sandbox keeps read-only, and
# fails with EROFS. The sentinel it leaves in ~/.dotnet is in the image, so later commands skip it.
RUN if command -v dotnet >/dev/null; then dotnet new list >/dev/null; fi
# The two agents, at the newest release when the image is built. The image decides the version: Claude
# is told not to update itself (DISABLE_UPDATES), and the launcher tells Codex not to check. An update
# made inside would live only until the container stops, so two sessions could run different versions.
# --rebuild is how they move on. If a release ever breaks the launcher, pin it here (@x.y.z) until
# the launcher is fixed.
ENV DISABLE_UPDATES=1
RUN npm install -g @anthropic-ai/claude-code
# OpenAI's agent, started with `ai-container codex`. Its own sandbox works inside this container, so it
# runs with its defaults and asks before stepping outside them.
RUN npm install -g @openai/codex

# start.sh raises the firewall, which needs root; it drops to `ubuntu` itself before Claude starts.
# Copied last, so a change to either script rebuilds only this step and not the installs above.
USER root
COPY init-firewall.sh start.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/init-firewall.sh /usr/local/bin/start.sh
ENTRYPOINT ["/usr/local/bin/start.sh"]
CMD ["claude"]
