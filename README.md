# AI agents in a container — template

Drop-in setup for running Claude Code or OpenAI Codex inside a rootless Podman container, so a
mistaken command cannot reach beyond one project. Copy it into any project and start.

## Use it

```
sudo apt install -y podman uidmap passt      # once per machine

cp -r ~/programming/ai-container-template/.devcontainer /path/to/project/
mkdir -p /path/to/project/scripts
cp ~/programming/ai-container-template/scripts/ai-container.sh /path/to/project/scripts/

cd /path/to/project
scripts/ai-container.sh claude
```

The first start builds the image (a few minutes, ~1 GB downloaded); later starts take seconds.
Choosing the tool is required — there is no default:

```
scripts/ai-container.sh claude             # Claude Code, web traffic open
scripts/ai-container.sh codex              # OpenAI Codex
scripts/ai-container.sh bash               # a shell
scripts/ai-container.sh --strict claude    # any of them, with only the hosts in init-firewall.sh
scripts/ai-container.sh --rebuild claude   # rebuild the image from scratch first
```

**Rebuild now and then.** The image is cached, so Claude Code, Node and the Ubuntu packages stay at
the versions the first build got until the Dockerfile changes. `--rebuild` fetches the base image and
every package anew; run it every month or so, and when a security fix is out.

`--strict` and `--rebuild` only apply when the container starts. If it is already running, the tool
joins it as it is, and the launcher says so — stop it first.

**Signing in.** Claude asks the first time, and the login is remembered. Codex needs one step of its
own, once: `scripts/ai-container.sh codex login --device-auth`. Its ordinary login sends the browser
back to an address inside the container, which the host cannot reach; the device login gives you a
code to enter on the web instead.

If the container is already running, the tool starts inside that one, so Claude and Codex can work
in the same project side by side. The container is named after the project directory, and each
project keeps its own image, logins and caches, so several projects can each have one.

**Codex keeps its own sandbox too.** It works inside this container — writes outside the project
and network access are refused until Codex asks — so it runs with its defaults, and you get both
layers. On an Ubuntu host it would not: its sandbox needs unprivileged user namespaces, which
Ubuntu's AppArmor restricts, and its read-only mode blocks writing but not reading the rest of the
machine.

## What it protects, and what it does not

**It protects:** everything outside the project directory. No cloud logins, tokens, SSH keys or
other projects are mounted in; there is no `sudo`, no capabilities and `no_new_privs`; and the paths
the *host* runs code from are read-only inside:

| Path | Why the host runs it |
| --- | --- |
| `.git/hooks`, `.git/config`, and `core.hooksPath` if the project sets one (`.husky`) | git runs hooks at every commit, and the config can point it at other programs |
| `.claude` | Claude Code runs its hooks on the host too |
| `.idea`, `.run`, `.vscode` — at the root, and any found deeper in | the IDE's run configurations and tasks |
| `.npmrc` | can make every `npm` command load a script first |
| `.devcontainer`, the launcher | so the container cannot loosen itself |

The four directories are created when missing, before the container starts. A directory that does
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
instructions to send the project somewhere. The mode is chosen on the host; the launcher and
firewall are read-only inside, so the agent cannot change either.

## Fit it to the project

- **Tools:** the image starts at what the agents need to work at all — git, Node, Python, Claude
  Code, Codex, and what the firewall uses — about 1 GB. Everything else is an optional block in
  `.devcontainer/Dockerfile`, commented out with what it gives and what it costs: a browser
  (Playwright with Chromium, ~400 MB), numpy, PDF reading, SQLite, a Postgres client, a C toolchain.
  Uncomment what the project needs; the image rebuilds once, on the next start. Anything Claude
  installs during a session is gone next time, so what the project always needs belongs here.
- **A .NET project:** swap the base image for `mcr.microsoft.com/dotnet/sdk:10.0-noble`, which
  carries the SDK and sets `DOTNET_RUNNING_IN_CONTAINER`. Add `dotnet-ef` as its own pinned line,
  and a volume for `~/.nuget` in the launcher.
- **Pin what you add**, and keep a pinned tool in step with the project's own version of it — a
  Playwright browser build that does not match the library is refused, and so is a mismatched
  `dotnet-ef`.
- **Strict hosts:** add package registries and documentation sites to `ALLOWED_HOSTS` in
  `.devcontainer/init-firewall.sh`. The Anthropic and OpenAI hosts the two agents need are there
  already.
- **Caches:** the container keeps `~/.cache` in a volume. For a toolchain that caches elsewhere
  (`~/.nuget`, `~/.m2`, `~/.cargo`), add a volume for it in the launcher, or every start downloads
  the dependencies again.
- **Build output:** if the host and the container both build the project, they may write different
  absolute paths into the build folder and undo each other's work. Point the container's output
  somewhere of its own (in .NET, a `Directory.Build.props` keyed on `DOTNET_RUNNING_IN_CONTAINER`).
- **A company network** that inspects encrypted traffic needs its root certificate in the image; the
  Dockerfile has a commented block for it. A proxy on a port other than 80 or 443 must be let through
  in `init-firewall.sh`.
- **WSL2** is untested. Podman, the firewall and AppArmor behave differently there; on a first start,
  run the same checks as on Ubuntu (firewall up, files owned by you, protected paths read-only).
- **API keys** for the project's own calls: pass them in with `-e NAME` from a file outside the
  project, and use keys with a low spend limit — with the web open, a key inside the container is a
  key that can leave. Never `ANTHROPIC_API_KEY`, which Claude Code would take for its own
  conversation and bill to it.

## Sessions and settings are separate

Logins and settings live in volumes of their own — one for Claude, one for Codex — and never in
your home directory. For Claude, `/resume` inside lists only sessions held inside, and the other way
round. Host transcripts are
deliberately not mounted in: a transcript the container could write is one a host session might
later resume, with every credential on the machine. What carries over is Claude's memory for the
project. Settings are separate too, so choose the model with `/model` inside.

Permission mode is a good one to set per side: lock the host down to manual in
`~/.claude/settings.json` (`permissions.disableBypassPermissionsMode` and `disableAutoMode`, both
`"disable"`), and inside the container run in auto mode, or skip permissions entirely when the
session is watched and the firewall strict.
