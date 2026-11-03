# AI agents in a container

Run Claude Code or OpenAI Codex inside a rootless Podman container, so a mistaken command cannot reach
beyond one project. Installed once per machine; each project keeps only a short settings file.

## A new machine

```
git clone https://github.com/Andersoy/ai-container-template ~/programming/ai-container-template
~/programming/ai-container-template/setup-host.sh --check   # what is in place, what is not
~/programming/ai-container-template/setup-host.sh           # do what is missing, asking first
```

`setup-host.sh` checks every step first and only does what is missing, so it is safe to run again:

1. **Packages:** `podman uidmap passt catatonit` for the containers, `bubblewrap socat` for Claude's
   sandbox on the host, `whiptail` for the menus.
2. **AppArmor:** on Ubuntu 24.04 and later, the profile that lets `bwrap` create user namespaces —
   Anthropic's own, from the Claude Code docs, the same form Ubuntu ships for Podman. Skipped where
   the restriction is off (often under WSL2).
3. **Claude settings on the host** (`~/.claude/settings.json`, backed up first): manual permission
   mode with bypass and auto disabled, and the sandbox on — still asking before each command,
   refusing to start without it, and with credential folders unreadable to commands.
4. **The `ai-container` command:** a link in `~/.local/bin` to `bin/ai-container` here. A terminal
   opened before `~/.local/bin` existed does not have it on PATH: `source ~/.profile` there.
5. **Checks it only reports on:** uid 1000, rootless Podman, where `runc` comes from (keep
   `containerd.io` installed: Ubuntu does not patch Podman's or crun's in `universe` without Ubuntu
   Pro), and services you may not want running (the Docker daemon, the system-wide Podman socket).

It asks for your password through `sudo` for the first two steps, and never handles a key or token.

**A company network** that inspects encrypted traffic re-signs it with its own root certificate, and
npm and Claude Code then fail with "self-signed certificate in certificate chain". That belongs to
the machine, not to a project: put the certificate (PEM) in `~/.config/ai-container/company-root.crt`,
and every image built on that machine trusts it. A proxy on a port other than 80 or 443 must also be
let through in `image/init-firewall.sh`.

## Use it

In a project that is already set up (it has `.devcontainer/ai-container.conf`), from any folder in it:

```
ai-container                    # menus: tool, network, ports, rebuild
ai-container claude             # Claude Code, web traffic open
ai-container codex              # OpenAI Codex
ai-container bash               # a shell
ai-container --strict claude    # any of them, with only the allowed hosts reachable
ai-container --rebuild claude   # rebuild the image from scratch first
ai-container --port 3000 claude # open a port for a dev server (repeatable)
ai-container --rebuild          # the flags work with the menus too
```

The first start builds the image (a few minutes, ~1 GB downloaded); later starts take seconds. If the
container is already running, the tool starts inside that one, so Claude and Codex can work in the
same project side by side; `--strict`, `--rebuild` and `--port` then stop with a message rather than
join it without what you asked for. The container is named after the project folder, and each
project keeps its own image, logins and caches.

The container lasts as long as the session that started it. When that one ends — `/exit`, or its
terminal closed — the container stops, and every session joined to it since (a shell, a dev server,
the other agent) ends with it. Joining says how long the container has been running, so a session
left open in a forgotten window is noticed. `podman kill ai-<folder>` stops one from the host.

**A new project:** in its root folder, `ai-container init` (or `ai-container init --dotnet`). It writes
`.devcontainer/ai-container.conf`, with a comment on every line, and a standard `.gitignore` if the
project has none. Commit both. A clone of the project on another machine then needs only this
template installed there.

**Signing in.** Claude asks the first time, and the login is remembered. Codex needs one step of its
own, once: `ai-container codex login --device-auth`. Its ordinary login sends the browser back to an
address inside the container, which the host cannot reach; the device login gives you a code to enter
on the web instead.

**Run dev servers in here, not on the host.** `npm install` and `npm run dev` execute the code in
every package; inside the container that code meets the container's walls, on the host it runs with
your rights. List the project's ports in `ports` (they come ticked in the menu), or give `--port`.
They are published to `127.0.0.1` only — your browser reaches them, nothing else on the network does.
The dev server must listen on all addresses in the container: Next.js does by default; Vite and
Sanity Studio need `--host`. Two containers running at once cannot both have the same port. Start
servers from a shell (`ai-container bash`), not through Claude: Claude's sandbox gives each command a
network of its own, so a server it starts cannot be reached from your browser, nor from Claude's next
command — a server and the check against it (Playwright, curl) go in one command.

## Updates

**The template:** a fix here reaches every project on the machine at its next start. Since this runs
on the host with your rights, look at what is coming before you take it:

```
cd ~/programming/ai-container-template
git fetch && git log -p HEAD..origin/main   # read it
git pull
./setup-host.sh --check                     # anything the update needs on this machine
```

The next start in each project rebuilds what the change touched. An update may also need something
new on the machine itself, such as a package; `--check` says so, and `./setup-host.sh` then sets up
only that.

**The image:** cached, so Claude Code, Node and the Ubuntu packages stay at the versions the last
rebuild got. `--rebuild` fetches the base image and every package anew; run it every couple of weeks,
and when a security fix is out. The launcher keeps count: it records each `--rebuild` in
`~/.cache/ai-container/`, and once the last one is 14 days old (`rebuild_after_days` in the launcher)
it says so at start — a note on the command line, and Yes already chosen in the menu's rebuild
question. It only warns, never stops. A Dockerfile change does not reset the count, since it rebuilds
only the steps below the change and leaves the base and its packages as they were. A project's very
first build fetches everything anew, and counts as one.

**Versions.** Claude Code and Codex are installed at their newest release when the image is built,
and kept there: Claude is told not to update itself and Codex not to check. An update made inside
would last only until the container stops. `--rebuild` is how they move on.

## The project's settings

`.devcontainer/ai-container.conf`, made by `ai-container init`:

| Setting | What it does |
| --- | --- |
| `format` | `1`. Lets a later template say plainly that a project needs updating. |
| `base_image` | `ubuntu:24.04`, or a toolchain image such as `mcr.microsoft.com/dotnet/sdk:10.0-noble` |
| `apt_packages` | Ubuntu packages on top of what the agents need: `sqlite3`, `poppler-utils` (PDFs), `postgresql-client`, `build-essential`… |
| `ports` | Dev-server ports, ticked in the menu |
| `sandbox_domains` | Hosts Claude's sandbox lets commands reach, on top of npm, NuGet and their certificate checks — the APIs the project calls when it runs in here |
| `strict_hosts` | Hosts `--strict` lets through, on top of the agents' own, npm and NuGet |
| `agent_keys` | Names passed in from `~/.config/<project folder>/agent.env`, for test runs against real APIs |

The launcher reads the file as data, never runs it, and checks each value — a port must be a number,
a host a host name, a package a package name. Anything else stops it, naming the line. Two more
settings exist for projects set up before this file did: `volumes` keeps their old volume name, and
with it their logins; `agent_env_file` keeps a key file at another path under `~/.config`.

**More than settings can say** — a browser, a pinned tool — goes in `.devcontainer/Dockerfile`, which
builds on the template's image. `templates/Dockerfile` is a starting point, with a browser (Playwright
with Chromium, ~400 MB) and a pinned `dotnet-ef` ready to uncomment. Pin what you add, and keep a
pinned tool in step with the project's own version of it — a Playwright browser build that does not
match the library is refused, and so is a mismatched `dotnet-ef`.

**API keys** for the project's own calls: one `NAME=value` per line in
`~/.config/<project folder>/agent.env`, `chmod 600`, and the names in `agent_keys`. Only those names are
passed on, by name, so the values never appear on a command line. Use keys with a low spend limit —
with the web open, a key inside the container is a key that can leave. Never `ANTHROPIC_API_KEY` or
`OPENAI_API_KEY`, which Claude Code and Codex would take for their own conversations and bill to them;
the launcher refuses both.

**A .NET project:** `ai-container init --dotnet`. Then:
- Tell Claude, in the project's CLAUDE.md, to build and test with `-m:1` (`dotnet build -m:1`):
  MSBuild's worker processes talk over sockets Claude's sandbox refuses, and the build then fails with
  `Build FAILED` and `0 Error(s)` — a known limit of the sandbox (anthropics/claude-code#39257, closed
  without a fix). One process needs no sockets. A shell from `ai-container bash` is not affected.
- If the host and the container both build the project, they write different absolute paths into
  `obj/` and undo each other's work. Point the container's output somewhere of its own: a
  `Directory.Build.props` keyed on `DOTNET_RUNNING_IN_CONTAINER`, which the .NET image sets.
- Run an API with `--urls http://0.0.0.0:<port>` to reach it from the host: `launchSettings.json`
  binds to localhost.

**WSL2** is untested. Podman, the firewall and AppArmor behave differently there; on a first start,
run the same checks as on Ubuntu (firewall up, files owned by you, protected paths read-only).

## What it protects, and what it does not

**It protects:** everything outside the project directory. No cloud logins, tokens, SSH keys, other
projects or this template are mounted in; there is no `sudo`, no capabilities and `no_new_privs`; and
the paths the *host* runs code from are read-only inside:

| Path | Why |
| --- | --- |
| `.git/hooks`, `.git/config`, and `core.hooksPath` if the project sets one (`.husky`) | git runs hooks at every commit, and the config can point it at other programs |
| `.claude` | Claude Code runs its hooks on the host too |
| `.mcp.json`, `.codex` | name programs a Claude or Codex session on the host would start. `.mcp.json` only when it exists; a new one still needs your approval on the host |
| `.idea`, `.run`, `.vscode` — at the root, and any found deeper in | the IDE's run configurations and tasks |
| `.npmrc` | can make every `npm` command load a script first |
| `.devcontainer` | the project's settings and Dockerfile, so the container cannot loosen itself |

The five directories are created when missing, before the container starts. A directory that does
not exist cannot be mounted, and one the agent could create in a fresh clone is one Rider would
later run from on the host.

The container is capped at 8 GB of memory and 4,096 processes, so a runaway build or loop cannot take
the machine — or, under WSL, everything else in WSL — down with it. The setup expects your uid to be
1000, as the image's user is; the launcher stops with a plain message if it is not.

**It does not protect:** the project itself. The agent can change or delete anything in it, so
commit often. Nor does it protect against code you then run on the host — `package.json` scripts,
build files, anything `npm run dev` or a build will execute — so read the diff first.

**Network.** Open by default: HTTP and HTTPS to the internet, every other port refused, and the home
network (private addresses) refused too, so the router and printers stay out of reach. IPv6 is off
in both modes, so it cannot route round the rules, and DNS goes only to the container's own
resolvers. `--strict` allows a listed handful of hosts instead — an allowlist worth having when a
session should run unwatched, since with the web open a page the agent reads could carry
instructions to send the project somewhere. It is a list of addresses, looked up once at start:
another site sharing an address with a listed host is reachable too.

**Claude and Codex each keep a sandbox of their own inside the container**, around every command they
run — a second wall inside the first. Codex brings its own and runs with its defaults. Claude's is
switched on by the launcher, on the command line so it can be neither loosened from inside nor leak
into host sessions (`/sandbox` inside therefore reports it as overridden). Its commands may write
only to the project, a temp folder and the package caches, and reach only `sandbox_domains`; a host
not on it is refused without asking. Claude's own web search and fetch are not shell commands and are
not affected. In a container the sandbox needs `enableWeakerNestedSandbox`, which lets a sandboxed
command see the container's other processes; the container is the boundary that matters. The
sandbox also leaves empty, read-only placeholders for `.bashrc`, `.gitconfig`, `.mcp.json` and a few
more in the project root, so nothing it runs can plant them; the standard `.gitignore` ignores them.

**Pushing.** No SSH key or git credential is mounted, so the agents can commit but not push. That is
the absence of a login, not a block on GitHub: a token pasted into the session would work. Claude's
own sandbox adds a wall for its commands, since GitHub is not in `sandbox_domains`. The network mode
is chosen on the host, and the settings are read-only inside, so the agent cannot change either.

## Sessions and settings are separate

Logins and settings live in volumes of their own — one for Claude, one for Codex — and never in
your home directory. For Claude, `/resume` inside lists only sessions held inside, and the other way
round. Host transcripts are deliberately not mounted in: a transcript the container could write is
one a host session might later resume, with every credential on the machine. What carries over is
Claude's memory for the project. Settings are separate too, so choose the model with `/model` inside.

Permission mode is a good one to set per side: lock the host down to manual in
`~/.claude/settings.json` (`setup-host.sh` does this), and inside the container run in auto mode, or
skip permissions entirely when the session is watched and the firewall strict.

## Moving a project from its own copy

Projects set up before the template was installed carry `scripts/ai-container.sh` and
`.devcontainer/{Dockerfile,init-firewall.sh,start.sh}`. To move one: run `ai-container init` (or
`--dotnet`) in its root — it leaves the old files alone — and fill the new file from the old launcher (`ports`, `sandbox_domains` beyond the defaults, the key names) and the old firewall
(`ALLOWED_HOSTS` beyond the defaults → `strict_hosts`). Set `volumes` to the old launcher's `volumes`
value if it is not `ai-<folder>`, or the logins start over. Whatever the old Dockerfile adds beyond the
template's goes in `base_image` and `apt_packages`, or a new `.devcontainer/Dockerfile` from
`templates/Dockerfile`. Then delete the old files, and point README and CLAUDE.md at `ai-container`.
