# 📦 CodeBox - OpenCode Docker Environment

A bash script that runs OpenCode in a Docker container. It dynamically mounts your current working directory, matches your user permissions, and keeps configuration persistent across sessions.


## Features

- **Run from anywhere** - Launch OpenCode from any project directory with automatic mounting
- **Isolated workspace** - Only your current directory and OpenCode data directories are mounted into the container
- **Easy updates** - Update to the latest OpenCode version with `--update`
- **Persistent data and state** - Auth tokens, history, and session data persist across container restarts
- **Dynamic UID/GID matching** - Automatic detection ensures seamless file permissions without manual configuration
- **Multi-architecture support** - Works on ARM64 (Apple Silicon, ARM servers) and x86_64
- **Non-root container security** - Runs as non-root user with dropped capabilities and privilege restrictions
- **OAuth authentication support** - Built-in port forwarding for OpenAI and GitHub Copilot sign-in
- **Customizable config directory** - Mount your own OpenCode config for dotfiles integration
- **Bash debug mode** - Open an interactive shell for troubleshooting with `--bash`
- **Optional cache pruning** - Run `--prune` (or enable `AUTO_PRUNE`) to control Docker disk growth
- **OpenCode v1 or v2 (beta)** - Select the stable or beta release channel with `OPENCODE_CHANNEL` in `.env`
- **Optional Claude Code CLI** - Install Anthropic's Claude Code CLI and launch it with `--claude` (see [Claude Code CLI](#claude-code-cli))
- **Configurable launcher** - Choose whether `codebox` starts OpenCode, agy, or Claude by default via `DEFAULT_LAUNCHER`


## Prerequisites

- Docker installed
- Permission to build Docker images

If you run into permission errors, see the [Troubleshooting](#troubleshooting) section.


## Quick Setup

### 1. Clone the Repository

```bash
# HTTPS
git clone https://github.com/sciguy/codebox.git ~/codebox
cd ~/codebox

# SSH
git clone git@github.com:sciguy/codebox.git ~/codebox
cd ~/codebox
```

### 2. Create Environment File

The `.env` file must be located in the `codebox` repository directory. You can copy it manually, or it will be automatically created from `.env.example` on first launch:

```bash
cp .env.example .env
```

### 3. Configure API Keys (Optional)

If you have API keys for providers like Anthropic or OpenAI, you can add them to the `.env` file:

```bash
vim .env  # Add your API keys
```

Alternatively, you can use OAuth authentication for supported providers (see [OAuth & Provider Authentication](#oauth--provider-authentication) section).


### 4. Start Using OpenCode

Navigate to any project directory and run:

```bash
path/to/codebox.sh              # Start OpenCode in current directory
path/to/codebox.sh --version    # Check OpenCode version
path/to/codebox.sh --help       # Show OpenCode help
```

For easier access from anywhere, see the **Shell Integration** section below.

## Shell Integration

Add the following function to your `.bashrc` or `.zshrc` to run CodeBox from any directory:

```bash
# CodeBox - OpenCode Docker Environment
# Update CODEBOX_PATH to match where you cloned the repository
CODEBOX_PATH="$HOME/codebox"
if [ -f "$CODEBOX_PATH/codebox.sh" ]; then
  codebox() {
    "$CODEBOX_PATH/codebox.sh" "$@"
  }
fi
```

After adding this and reloading your shell (`source ~/.bashrc`), you can use `codebox` from anywhere.

Alternative setup with a symlink from your user bin directory:

```bash
mkdir -p "$HOME/bin"
ln -s "$HOME/codebox/codebox.sh" "$HOME/bin/codebox"
chmod +x "$HOME/codebox/codebox.sh"
```

Make sure `$HOME/bin` is in your `PATH` (for example, add `export PATH="$HOME/bin:$PATH"` to your shell config).


## Usage

The following examples assume you have set up the shell integration function. If not, replace `codebox` with `path/to/codebox.sh`.

### Basic Commands

```bash
# Navigate to any project
cd ~/my-project

# Run OpenCode
codebox

# Run with OpenCode arguments
codebox --version
codebox --continue
```

### Advanced Options

```bash
# Update the Docker image to latest OpenCode version
codebox --upgrade

# Launch Antigravity CLI (agy) instead of OpenCode
codebox --agy

# Launch Claude Code CLI instead of OpenCode
codebox --claude

# Force OpenCode (overrides DEFAULT_LAUNCHER)
codebox --opencode

# OpenCode v2 only: start with or without --standalone (overrides OPENCODE_V2_STANDALONE)
codebox --standalone
codebox --no-standalone

# Show help
codebox -h

# Combined options
codebox --upgrade --version
```

### Complete Options Reference

```
---------------------------------------------------------------
📦 codebox - OpenCode Docker Launcher
---------------------------------------------------------------
Usage: codebox [options] [tool-arguments]

Options:
  -n, --name NAME    Use NAME as the container root directory (temporary override)
  -u, --update       Rebuild docker and update OpenCode before starting container
  -b, --bash         Open an interactive bash session instead of running a tool
  -o, --oauth        Enable OAuth callback port (127.0.0.1:1455) for OpenAI sign-in
  -p, --prune        Prune unused Docker build cache and dangling images before start
  -a, --agy          Launch Antigravity CLI (agy) instead of OpenCode
  -c, --claude       Launch Claude Code CLI instead of OpenCode
      --claude-config DIR  Use DIR as the host Claude config dir (overrides HOST_CLAUDE_CONFIG_DIR)
      --opencode     Launch OpenCode (overrides DEFAULT_LAUNCHER)
      --standalone   Start OpenCode v2 with --standalone (overrides OPENCODE_V2_STANDALONE)
      --no-standalone  Start OpenCode v2 without --standalone (overrides OPENCODE_V2_STANDALONE)
  -f, --force        Continue even in protected directories
  -h, --help         Show this help and tool help
---------------------------------------------------------------
Launcher (set DEFAULT_LAUNCHER in .env): opencode (default), agy, claude
Channel  (set OPENCODE_CHANNEL in .env): v1 = stable (default), v2 = beta
v2 start (set OPENCODE_V2_STANDALONE in .env): false (default) or true
---------------------------------------------------------------
```

Any additional arguments not recognized by codebox are passed directly to the launched tool. For example:

```bash
codebox --version            # Passed to OpenCode
codebox --continue           # Passed to OpenCode
codebox --upgrade --version  # --upgrade for codebox, --version for OpenCode
```

### Container Path Structure

When you run `codebox` from any directory, the container creates a path structure:

```
/${CODEBOX_NAME}/hostname/directory-name
```

For example (with default `CODEBOX_NAME=BOX`):

| Host directory | Hostname | Container path |
| --- | --- | --- |
| `~/my-project` | `helix` | `/BOX/helix/my-project` |
| `~/workspace/app` | `helix` | `/BOX/helix/app` |

This makes it clear you're in a containerized environment and shows which machine and project you're working on.

You can temporarily override the container root for a single session with `--name`:

```bash
codebox --name WORKSPACE
```

To make it persistent, set `CODEBOX_NAME` in your `.env` file:

```bash
CODEBOX_NAME=WORKSPACE
```

## How It Works

The `codebox` function:
- Runs from **any directory** (mounts current directory dynamically)
- Auto-detects your **UID/GID** for correct file permissions
- Auto-rebuilds when UID/GID or CODEBOX_NAME changes
- Mounts your OpenCode config, auth, and history
- Checks for `.env` file and guides you if missing

## OpenCode Directories

OpenCode uses several directories for different purposes:

| Directory | Purpose | CodeBox location |
|-----------|---------|-----------------|
| `~/.config/opencode` | **Config**: Settings, agents, etc | Optional host mount |
| `~/.local/share/opencode` | **Data**: Auth tokens, logs, session data | Mounted from host |
| `~/.local/state/opencode` | **State**: History, UI state, Favorites | Mounted from host |
| `~/.cache/opencode` | **Cache**: Temporary files, downloads | Container only |
| `/usr/local/bin/opencode` | **Binary**: OpenCode executable | Container only |

When `OPENCODE_CHANNEL=v2`, the data, state, and cache directories use an `opencode2` suffix on the host
(`~/.local/share/opencode2`, `~/.local/state/opencode2`, `~/.cache/opencode2`) and are mounted to the same
container paths, so the v1 session database is never mutated.

Directories mounted on the host will be automatically created if needed on first run of codebox.

```bash
# To get a list of directories used by OpenCode
codebox uninstall --dry-run
# 'uninstall --dry-run' is passed through to opencode
```

### Volume Mounts

When you run `codebox`, these directories are mounted into the container:

| Host | Container | Purpose |
|------|-----------|---------|
| Current directory | `/${CODEBOX_NAME}/hostname/dirname` | Your project files (dynamic) |
| [`HOST_OPENCODE_CONFIG_DIR`](#opencode-config-directory) | `/home/dev/.config/opencode` | Settings, preferences |
| `~/.local/share/opencode` | `/home/dev/.local/share/opencode` | Auth tokens, logs |
| `~/.local/state/opencode` | `/home/dev/.local/state/opencode` | History, state |
| `~/.claude` | `/home/dev/.claude` | Claude Code config, credentials, sessions (only when `ENABLE_CLAUDE_CLI=true`) |
| `~/.claude.json` | `/home/dev/.claude.json` | Claude Code app state/onboarding (only when `ENABLE_CLAUDE_CLI=true`) |

## Configuration

### API Keys

Edit `.env` (or wherever you cloned the repository) and add API keys for your chosen provider(s):

```bash
ANTHROPIC_API_KEY=your_key
OPENAI_API_KEY=your_key
```


### OAuth & Provider Authentication

Some providers require OAuth authentication instead of API keys:

**OpenAI OAuth:**
1. Start codebox with the `--oauth` flag to enable the OAuth callback server:
   ```bash
   codebox --oauth
   ```
2. Inside OpenCode, run the `/connect` command
3. OpenCode will provide an OpenAI authentication URL
4. Copy this URL and open it in your host machine's web browser
5. Complete the authentication in your browser
6. Return to OpenCode - the connection will be established

If you are connecting from a remote server, set up SSH port forwarding so the OAuth callback can reach your local browser:
```bash
ssh -L 1455:localhost:1455 SERVER
```

**GitHub Copilot:**
- Use the `/connect` command within OpenCode to link your GitHub account
- Follow the on-screen authentication prompts

Once connected, authentication tokens are stored in `~/.local/share/opencode` and persist across container sessions.

### OpenCode Config Directory

The `config.opencode.example/` directory provides a ready-made OpenCode configuration you can copy into your own config directory. This is useful if you want a version-controlled setup with `opencode.json`, `AGENTS.md`, and optional subdirectories like `agents/`, `commands/`, or `themes/`.

To use it with CodeBox, copy the folder to a location you control and set `HOST_OPENCODE_CONFIG_DIR` in `.env` to that absolute path. When set, CodeBox mounts it to `~/.config/opencode` inside the container, so your OpenCode configuration persists across sessions and acts as the global config layer.

Example using the default OpenCode config path:

```bash
cp -R config.opencode.example ~/.config/opencode
```

```bash
# Must be an absolute path
HOST_OPENCODE_CONFIG_DIR=/home/your-username/.config/opencode
```

For details on supported files, directory structure, and precedence, see `config.opencode.example/README.md` and the `OpenCode Config Directory` section in `.env.example`.

### Antigravity CLI (agy)

CodeBox can launch [Google's Antigravity CLI](https://antigravity.google) (`agy`) instead of OpenCode.

**Enable agy in the image** (opt-in build arg, requires a rebuild):

```bash
# .env
ENABLE_AGY=true
```

The first run of `codebox` will detect the change and rebuild the image with `agy` installed to `/usr/local/bin`. Self-updates are disabled (`AGY_CLI_DISABLE_AUTO_UPDATE=true`), so the version is pinned at build time — rebuild with `codebox --upgrade` to update it.

**Launch agy** — either pass the flag per invocation:

```bash
codebox --agy
```

or make it the default launcher in `.env`:

```bash
# .env
DEFAULT_LAUNCHER=agy
```

Arguments not recognized by codebox are forwarded to `agy` (e.g. `codebox --agy "explain this repo"`).

**Data & configuration:** agy stores settings, history, and auth tokens in `~/.gemini/antigravity-cli/`. When launching in agy mode, CodeBox mounts your host `~/.gemini` directory into the container (created automatically if missing) so this data persists across sessions.

**Authentication:** the container has no OS keyring or browser, so two flows are supported:

- **Gemini API key (recommended for reliability):** set `"modelProvider": "gemini"` in `~/.gemini/antigravity-cli/settings.json` and add `GEMINI_API_KEY` to `.env`. This skips the sign-in screen entirely. Get a key at [Google AI Studio](https://aistudio.google.com/app/api-keys).
- **Remote SSH OAuth flow (Google account):** set `AGY_REMOTE_AUTH=true` in `.env`. CodeBox fabricates SSH environment variables so `agy` uses its browser-based remote sign-in: it prints a secure authorization URL → open it in your local browser → sign in → paste the returned code back into the terminal. The token is stored in the mounted `~/.gemini` directory and persists across sessions. If your host session is already over SSH, the real `SSH_*` variables are passed through automatically.

### Claude Code CLI

CodeBox can optionally install [Anthropic's Claude Code CLI](https://code.claude.com/docs) inside the container using the official native installer. This is opt-in at build time.

1. Enable it in `.env`:
   ```bash
   ENABLE_CLAUDE_CLI=true
   # Optionally pin a channel/version: latest | stable | X.Y.Z
   CLAUDE_CODE_VERSION=latest
   ```
2. Rebuild the image:
   ```bash
   codebox --update
   ```
3. Launch it:
   ```bash
   codebox --claude        # Launch Claude Code
   codebox --opencode      # Launch OpenCode (override)
   codebox                 # Launch the default launcher (see below)
   ```

**Choosing the default launcher:** set `DEFAULT_LAUNCHER` in `.env` to `opencode` (default), `agy`, or `claude`. Per-session flags (`--opencode` / `--agy` / `--claude`) take precedence, and `--bash` always opens a shell.

```bash
DEFAULT_LAUNCHER=claude
```

**Authentication:** Claude Code uses either `ANTHROPIC_API_KEY` or a `CLAUDE_CODE_OAUTH_TOKEN`. Add one to `.env`. Credentials are stored in `~/.claude/.credentials.json`.

**Persistence:** the host `~/.claude` directory and `~/.claude.json` file are mounted into the container, so global configuration and session history persist across runs. These are the same locations a host Claude Code install uses, so state is shared between host and container. CodeBox creates them if missing.

**Custom config directory:** if you use `CLAUDE_CONFIG_DIR` on the host (for example, separate work and personal profiles), CodeBox can mount that directory instead. It is mounted at `~/.claude` in the container with `CLAUDE_CONFIG_DIR` pointing to it, so Claude reads `.claude.json` from inside the directory, as it does on the host. The directory must already exist. The first match wins:

1. `--claude-config DIR` (per session)
2. `HOST_CLAUDE_CONFIG_DIR` in `.env`
3. `CLAUDE_CONFIG_DIR` in the host environment
4. Default: `~/.claude` + `~/.claude.json`

```bash
codebox --claude --claude-config ~/.claude-work
```

### Timezone

If session timestamps appear in UTC, set your local timezone in `.env` so the container formats times correctly:

```bash
TZ=America/Edmonton
```

### Clipboard

Pasting images into OpenCode or Claude Code needs access to the host display. `codebox` forwards the display session selected by `DISPLAY_FORWARDING` in `.env`:

- `auto` (default): Wayland if the `$WAYLAND_DISPLAY` socket exists, otherwise X11 if `DISPLAY` is set
- `wayland`: mounts the Wayland socket from `$XDG_RUNTIME_DIR`
- `x11`: mounts `/tmp/.X11-unix` and a copy of the X11 cookie with a wildcard host name, written to `$XDG_RUNTIME_DIR/codebox.Xauthority` (requires `xauth` on the host)
- `none`: no display forwarding

Add the matching clipboard tool to `DOCKER_PACKAGES` and rebuild with `codebox -u`: `xclip` for X11, `wl-clipboard` for Wayland.

### Git Configuration

Add to `.env` for proper commit attribution:

```bash
GIT_AUTHOR_NAME="Your Name"
GIT_AUTHOR_EMAIL="your.email@example.com"
GIT_COMMITTER_NAME="Your Name"
GIT_COMMITTER_EMAIL="your.email@example.com"
```

## OpenCode v2 (beta)

CodeBox can install either the stable **v1** channel or the **v2** beta channel. Both use the same `opencode`
command, so this is a **build-time toggle** configured in `.env` (not a runtime flag), which keeps the image
deterministic for scripts and integrations:

```bash
# .env
OPENCODE_CHANNEL=v2
```

The channel is baked into the image. Switching it is detected on the next run and rewrites the image
automatically (or force it with `codebox --upgrade`).

**Data isolation:** v2 writes to `~/.local/share/opencode2`, `~/.local/state/opencode2`, and
`~/.cache/opencode2` on the host, mounted to the standard container paths. This prevents v2 from mutating the
v1 session database. Config locations (`~/.config/opencode/opencode.json(c)`) are shared; v2 reads existing v1
configuration and normalizes it in memory without rewriting the source file.

**What to expect in v2:** the main breaking changes are the plugin API, the server API/clients, and the terminal
client config (layered `tui.json(c)` files become a single global `~/.config/opencode/cli.json`). Existing
agents, commands, skills, and server config are intended to keep working. See the
[OpenCode v2 migration guide](https://opencode.ai/v2/docs/migrate-v1/) for details.

**Version pinning** works per channel via `OPENCODE_VERSION`:

```bash
# .env
OPENCODE_CHANNEL=v2
OPENCODE_VERSION=2.0.16   # omit or set "latest" to track the newest v2 release
```

To revert to stable, set `OPENCODE_CHANNEL=v1` (or remove the line) and rerun codebox.

**Standalone mode:** set `OPENCODE_V2_STANDALONE=true` in `.env` to start v2 as `opencode --standalone`
(default: `false`). Override it per session with `codebox --standalone` or `codebox --no-standalone`. The
setting takes effect at launch (no rebuild) and is ignored for v1, `--agy`, `--claude`, and `--bash`; passing
either flag in those cases prints a warning. Because codebox consumes `--standalone`, it is not forwarded to
OpenCode as a regular argument.

## Updating OpenCode

To update to the latest version of the currently selected channel:

```bash
codebox --upgrade
```

`--upgrade` rebuilds with `--pull --no-cache`, so it also picks up a new `latest` release for whichever channel
`OPENCODE_CHANNEL` is set to.

## Troubleshooting

### Permission denied while building

If you see an error like this when CodeBox tries to build the image, your user likely does not have permission to access the Docker daemon:

```
ERROR: permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get "http://%2Fvar%2Frun%2Fdocker.sock/_ping": dial unix /var/run/docker.sock: connect: permission denied
```

On most Linux systems, the typical fix is to add your user to the `docker` group, then log out and back in:

```bash
sudo usermod -aG docker $USER
```

After re-login, re-run `codebox` and the build should proceed.


### Check Version

```bash
codebox --version
```

### Debug Container

Run with shell access for debugging:

```bash
codebox --bash
```

### Docker Storage Management

If you run CodeBox frequently, Docker build cache and dangling image layers can accumulate over time.

- Run manual cleanup before a session:

```bash
codebox --prune
```

- Enable automatic cleanup in `.env` after image rebuilds/updates:

```bash
AUTO_PRUNE=true
PRUNE_MAX_AGE=168h
```

`PRUNE_MAX_AGE` controls which build cache entries are removed by `docker builder prune`.

## Cross-Platform Support

The setup automatically adapts to each system's UID/GID:
- Auto-detects UID/GID on every run
- Works on Mac (ARM64), Linux servers, and WSL
- No manual configuration needed

## Files

- `Dockerfile` - Container definition with multi-arch support
- `codebox.sh` - Main script for building and running the container
- `.env.example` - Environment template
- `.env` - Your config (git-ignored, create from .env.example)
- `README.md` - This file


## Security

- Runs as non-root user (UID/GID matches your host user)
- `.env` file excluded from git
- No sensitive data in container

## Resources

- [OpenCode Documentation](https://opencode.ai/docs)
- [OpenCode GitHub](https://github.com/anomalyco/opencode)
- [OpenCode Releases](https://github.com/anomalyco/opencode/releases)

## License

CodeBox and OpenCode are licensed under MIT
