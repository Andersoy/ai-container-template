# Optional: what this project needs beyond ai-container.conf. Copy to .devcontainer/Dockerfile and keep
# the blocks you want. ai-container builds the template's image first, from the base image and apt
# packages in ai-container.conf, and then this file on top of it — so everything the agents need is
# already there, and a template update reaches this project without touching this file.
#
# Anything Claude installs during a session is gone the next time the container starts, so what the
# project always needs belongs here, where it is in the image and visible in git. Pin what you add,
# and keep a pinned tool in step with the project's own version of it.
#
# Change only what a step adds itself, never files that come from the template's image. Each RUN is
# a layer of its own, and a file it changes — its permissions included — is stored in it once more,
# in full: a chmod over /usr/local/share/npm-global copies Claude Code and Codex (~1.1 GB) into the
# layer. `podman history <image>` shows what each layer weighs.
ARG BASE
FROM ${BASE}

# A real browser (~400 MB). Claude can open the app, click through it, read the console and take
# screenshots at phone and desktop width — the layout failures a type check cannot see. Chromium
# only, installed as root into shared paths: a browser under /home/ubuntu would live in a volume and
# be gone the next time the image changes. If the project adds @playwright/test, move the two
# together — a browser build that does not match is refused.
# ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/ms-playwright
# RUN npm install -g playwright@1.63.0 \
#     && npx playwright install --with-deps chromium \
#     && chmod -R a+rX /usr/local/share/ms-playwright /usr/local/share/npm-global/lib/node_modules/playwright \
#     && apt-get clean && rm -rf /var/lib/apt/lists/*

# A tool installed as the ordinary user, such as EF Core's command line for migrations. ~/.dotnet/tools
# is on PATH already. Keep the version in step with the EF Core packages, or it refuses to run.
# USER ubuntu
# RUN dotnet tool install -g dotnet-ef --version 10.0.13
# USER root

# The template's image ends as root, with start.sh as its entry point, and so must this one: start.sh
# raises the firewall as root and only then drops to the ordinary user.
