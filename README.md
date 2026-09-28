# Claude Code in a container — template

Drop-in setup for running Claude Code inside a rootless Podman container, so a mistaken command
cannot reach beyond one project. Copy it into any project and start.

## Use it

```
sudo apt install -y podman uidmap passt      # once per machine

cp -r ~/programming/claude-container-template/.devcontainer /path/to/project/
mkdir -p /path/to/project/scripts
cp ~/programming/claude-container-template/scripts/claude-container.sh /path/to/project/scripts/

cd /path/to/project
scripts/claude-container.sh
```

The first start builds the image (a few minutes, ~500 MB downloaded); later starts take seconds.
Sign in to Claude the first time; it is remembered afterwards.

```
scripts/claude-container.sh            # Claude, web traffic open
scripts/claude-container.sh --strict   # Claude, only the hosts in init-firewall.sh
scripts/claude-container.sh bash       # a shell, in the running container if Claude is up
```

The container is named after the project directory, and each project keeps its own image, login and
caches, so several projects can each have one without colliding.

## What it protects, and what it does not

**It protects:** everything outside the project directory. No cloud logins, tokens, SSH keys or
other projects are mounted in; there is no `sudo`, no capabilities and `no_new_privs`; and the paths
the *host* runs code from are read-only inside — `.git/hooks`, `.git/config`, `.claude`, `.idea`,
`.vscode`, `.devcontainer` and the launcher itself.

**It does not protect:** the project itself. Claude can change or delete anything in it, so commit
often. Nor does it protect against code you then run on the host — read the diff first.

**Network.** Open by default: HTTP and HTTPS to the internet, every other port refused, and the home
network (private addresses) refused too, so the router and printers stay out of reach. IPv6 is off
in both modes, so it cannot route round the rules, and DNS goes only to the container's own
resolvers. `--strict` allows a listed handful of hosts instead — an allowlist worth having when a
session should run unwatched, since with the web open a page Claude reads could carry instructions
to send the project somewhere. The mode is chosen on the host; the launcher and firewall are
read-only inside, so Claude cannot change either.

## Fit it to the project

- **Tools:** the image starts at what Claude needs to work at all — git, Node, Python, Claude Code,
  and what the firewall uses — about 830 MB. Everything else is an optional block in
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
  `.devcontainer/init-firewall.sh`.
- **Caches:** the container keeps `~/.cache` in a volume. For a toolchain that caches elsewhere
  (`~/.nuget`, `~/.m2`, `~/.cargo`), add a volume for it in the launcher, or every start downloads
  the dependencies again.
- **Build output:** if the host and the container both build the project, they may write different
  absolute paths into the build folder and undo each other's work. Point the container's output
  somewhere of its own (in .NET, a `Directory.Build.props` keyed on `DOTNET_RUNNING_IN_CONTAINER`).
- **API keys** for the project's own calls: pass them in with `-e NAME` from a file outside the
  project, and use keys with a low spend limit — with the web open, a key inside the container is a
  key that can leave. Never `ANTHROPIC_API_KEY`, which Claude Code would take for its own
  conversation and bill to it.

## Sessions and settings are separate

`/resume` inside lists only sessions held inside, and the other way round. Host transcripts are
deliberately not mounted in: a transcript the container could write is one a host session might
later resume, with every credential on the machine. What carries over is Claude's memory for the
project. Settings are separate too, so choose the model with `/model` inside.

Permission mode is a good one to set per side: lock the host down to manual in
`~/.claude/settings.json` (`permissions.disableBypassPermissionsMode` and `disableAutoMode`, both
`"disable"`), and inside the container run in auto mode, or skip permissions entirely when the
session is watched and the firewall strict.
