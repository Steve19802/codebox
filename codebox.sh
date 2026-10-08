#!/usr/bin/env bash
set -Eeuo pipefail

# Always surface a useful error message on unexpected failures
trap 'exit_error "🛑 Error: unexpected failure at line $LINENO while running: $BASH_COMMAND"' ERR

# Helper function to print error and exit
exit_error() {
    local message="$1"
    echo "--------------------------------------------------------------------------------" >&2
    echo "$message" >&2
    echo "--------------------------------------------------------------------------------" >&2
    exit 1
}

# Docker cleanup helper to control storage growth
run_docker_prune() {
    local prune_max_age="$1"

    echo "---------------------------------------------------------------"
    echo "🧹 Pruning unused Docker cache and dangling images..."
    echo "   Cache max age: ${prune_max_age}"
    echo "---------------------------------------------------------------"

    if ! docker image prune -f --filter "dangling=true" >/dev/null; then
        echo "⚠️  Warning: docker image prune failed; continuing"
    fi

    if ! docker builder prune -f --filter "until=${prune_max_age}" >/dev/null; then
        echo "⚠️  Warning: docker builder prune failed; continuing"
    fi

    echo "✅ Docker prune complete"
    echo ""
}

# Read a key from .env (returns empty if missing)
read_env_value() {
    local key="$1"
    local env_file="$OPENCODE_DOCKER_DIR/.env"
    if [ -f "$env_file" ]; then
        grep -m1 "^${key}=" "$env_file" 2>/dev/null | cut -d= -f2 || true
    fi
}

# Fill the caller's DISPLAY_ARGS array with docker run arguments that forward
# the host display session (used for clipboard access inside the container).
# Mode: auto (default) | wayland | x11 | both | none
# auto forwards every available session: clients such as OpenTUI need X11 as a
# fallback on compositors without a data-control protocol (e.g. GNOME/Mutter).
build_display_args() {
    local mode="${1:-auto}"
    local wayland_display="${WAYLAND_DISPLAY:-}"
    local x_display="${DISPLAY:-}"
    local runtime_dir="${XDG_RUNTIME_DIR:-}"
    DISPLAY_ARGS=()

    case "$mode" in
        auto)
            if [ -n "$wayland_display" ] && [ -n "$runtime_dir" ] && [ -S "$runtime_dir/$wayland_display" ]; then
                _add_wayland_display_args
            fi
            if [ -n "$x_display" ]; then
                _add_x11_display_args
            fi
            ;;
        wayland) _add_wayland_display_args ;;
        x11) _add_x11_display_args ;;
        both)
            _add_wayland_display_args
            _add_x11_display_args
            ;;
        none) ;;
        *)
            echo "⚠️  Warning: unknown DISPLAY_FORWARDING value '$mode' (expected auto, wayland, x11, both, none); skipping"
            ;;
    esac
}

# Helpers read wayland_display, x_display and runtime_dir from build_display_args' locals
# (bash dynamic scoping) and append to DISPLAY_ARGS.
_add_wayland_display_args() {
    if [ -z "$wayland_display" ] || [ -z "$runtime_dir" ]; then
        echo "⚠️  Warning: Wayland forwarding requested but WAYLAND_DISPLAY or XDG_RUNTIME_DIR is unset; skipping"
        return 0
    fi
    DISPLAY_ARGS+=(
        -e WAYLAND_DISPLAY="$wayland_display"
        -e XDG_RUNTIME_DIR="/tmp"
        -v "$runtime_dir/$wayland_display:/tmp/$wayland_display"
    )
}

# Remove per-launch cookie files that no existing container (running or stopped) mounts.
_cleanup_codebox_xauth() {
    local xauth_dir="$1" file
    local mounted
    mounted=$(docker ps -aq 2>/dev/null \
        | xargs -r docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null)
    for file in "$xauth_dir"/Xauthority.*; do
        [ -e "$file" ] || continue
        grep -qxF "$file" <<< "$mounted" || rm -f "$file"
    done
}

_add_x11_display_args() {
    if [ -z "$x_display" ]; then
        echo "⚠️  Warning: X11 forwarding requested but DISPLAY is unset; skipping"
        return 0
    fi
    DISPLAY_ARGS+=(
        -e DISPLAY="$x_display"
        -v /tmp/.X11-unix:/tmp/.X11-unix:ro
    )
    # The host Xauthority entries are bound to the host name, which differs
    # inside the container. Write a copy of the cookie for this display with
    # the address family set to "wildcard" (ffff) so it matches any host.
    # Each launch gets its own file: a shared file would be rewritten under
    # containers that already bind-mount it, breaking their X11 auth.
    local host_xauth="${XAUTHORITY:-$HOME/.Xauthority}"
    local container_xauth="/tmp/.codebox.Xauthority"
    if command -v xauth >/dev/null 2>&1 && [ -f "$host_xauth" ]; then
        local xauth_dir="${runtime_dir:-$HOME/.cache}/codebox-xauth"
        mkdir -p "$xauth_dir" && chmod 700 "$xauth_dir"
        _cleanup_codebox_xauth "$xauth_dir"
        local codebox_xauth
        codebox_xauth=$(mktemp "$xauth_dir/Xauthority.XXXXXX")
        if XAUTHORITY="$host_xauth" xauth nlist "$x_display" 2>/dev/null \
                | sed -e 's/^..../ffff/' \
                | xauth -f "$codebox_xauth" nmerge - 2>/dev/null \
                && [ -s "$codebox_xauth" ]; then
            DISPLAY_ARGS+=(
                -e XAUTHORITY="$container_xauth"
                -v "$codebox_xauth:$container_xauth:ro"
            )
        else
            rm -f "$codebox_xauth"
            echo "⚠️  Warning: could not extract an X11 cookie for $x_display; clipboard access may fail"
        fi
    elif [ -f "$host_xauth" ]; then
        echo "⚠️  Warning: xauth not found on host; mounting $host_xauth as-is (may not match container host name)"
        DISPLAY_ARGS+=(
            -e XAUTHORITY="$container_xauth"
            -v "$host_xauth:$container_xauth:ro"
        )
    fi
}

# OpenCode Docker script - run from any directory
# Usage: codebox [options] [tool-arguments]
# Options:
#   -n, --name NAME    Use NAME as the container root directory (temporary override)
#   -u, --update       Rebuild docker and update OpenCode before starting container
#   -b, --bash         Open an interactive bash session instead of running a tool
#   -o, --oauth        Enable OAuth callback port (127.0.0.1:1455) for OpenAI sign-in
#   -p, --prune        Prune unused Docker build cache and dangling images before start
#   -a, --agy          Launch Antigravity CLI (agy) instead of OpenCode
#   -c, --claude       Launch Claude Code CLI instead of OpenCode
#       --claude-config DIR  Use DIR as the host Claude config dir (overrides HOST_CLAUDE_CONFIG_DIR)
#       --opencode     Launch OpenCode (overrides DEFAULT_LAUNCHER)
#       --standalone   Start OpenCode v2 with --standalone (overrides OPENCODE_V2_STANDALONE)
#       --no-standalone  Start OpenCode v2 without --standalone (overrides OPENCODE_V2_STANDALONE)
#   -f, --force        Continue even in protected directories
#   -h, --help         Show this help and tool help
#
# Launcher selection (DEFAULT_LAUNCHER in .env, default: opencode):
#   opencode | agy | claude. Per-session flags take precedence.
#
# Channel selection (OPENCODE_CHANNEL in .env, default: v1):
#   v1 = stable OpenCode; v2 = beta OpenCode. Switching channels rewrites the
#   image (build-time toggle), so it is configured in .env rather than a flag.
#   With v2, OPENCODE_V2_STANDALONE=true (default: false) starts OpenCode with
#   --standalone; override per session with --standalone / --no-standalone.
main() {
    # Parse command line arguments first
    local CLI_CODEBOX_NAME=""
    local OPENCODE_ARGS=()
    local UPDATE_REQUESTED=false
    local HELP_REQUESTED=false
    local BASH_MODE=false
    local FORCE_MODE=false
    local OAUTH_ENABLED=false
    local PRUNE_REQUESTED=false
    local AGY_MODE=false
    local CLAUDE_MODE=false
    local CLI_CLAUDE_CONFIG_DIR=""
    local OPENCODE_MODE=false
    local STANDALONE_OVERRIDE=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--name)
                CLI_CODEBOX_NAME="$2"
                shift 2
                ;;
            -u|--update)
                UPDATE_REQUESTED=true
                shift
                ;;
            -b|--bash)
                BASH_MODE=true
                shift
                ;;
            -o|--oauth)
                OAUTH_ENABLED=true
                shift
                ;;
            -p|--prune)
                PRUNE_REQUESTED=true
                shift
                ;;
            -a|--agy)
                AGY_MODE=true
                shift
                ;;
            -c|--claude)
                CLAUDE_MODE=true
                shift
                ;;
            --claude-config)
                [ $# -ge 2 ] || exit_error "🛑 Error: --claude-config requires a directory argument"
                CLI_CLAUDE_CONFIG_DIR="$2"
                shift 2
                ;;
            --opencode)
                OPENCODE_MODE=true
                shift
                ;;
            --standalone)
                STANDALONE_OVERRIDE=true
                shift
                ;;
            --no-standalone)
                STANDALONE_OVERRIDE=false
                shift
                ;;
            -f|--force)
                FORCE_MODE=true
                shift
                ;;
            -h|--help)
                HELP_REQUESTED=true
                OPENCODE_ARGS+=("$1")
                shift
                ;;
            *)
                OPENCODE_ARGS+=("$1")
                shift
                ;;
        esac
    done

    # Path to your OpenCode Docker installation (script directory)
    local SCRIPT_SOURCE="${BASH_SOURCE[0]}"
    local SCRIPT_PATH=""
    if command -v realpath >/dev/null 2>&1; then
        SCRIPT_PATH=$(realpath "$SCRIPT_SOURCE")
    else
        SCRIPT_PATH=$(readlink -f "$SCRIPT_SOURCE")
    fi
    local OPENCODE_DOCKER_DIR="$(dirname "$SCRIPT_PATH")"

    if [ -z "$OPENCODE_DOCKER_DIR" ]; then
        exit_error "🛑 Error: failed to resolve OpenCode Docker directory"
    fi

    if [ "$HELP_REQUESTED" = true ]; then
        echo "---------------------------------------------------------------"
        echo "📦 codebox - OpenCode Docker Launcher"
        echo "---------------------------------------------------------------"
        echo "Usage: codebox [options] [tool-arguments]"
        echo "Options:"
        echo "  -n, --name NAME    Use NAME as the container root directory (temporary override)"
        echo "  -u, --update       Rebuild docker and update OpenCode before starting container"
        echo "  -b, --bash         Open an interactive bash session instead of running a tool"
        echo "  -o, --oauth        Enable OAuth callback port (127.0.0.1:1455) for OpenAI sign-in"
        echo "  -p, --prune        Prune unused Docker build cache and dangling images before start"
        echo "  -a, --agy          Launch Antigravity CLI (agy) instead of OpenCode"
        echo "  -c, --claude       Launch Claude Code CLI instead of OpenCode"
        echo "      --claude-config DIR  Use DIR as the host Claude config dir (overrides HOST_CLAUDE_CONFIG_DIR)"
        echo "      --opencode     Launch OpenCode (overrides DEFAULT_LAUNCHER)"
        echo "      --standalone   Start OpenCode v2 with --standalone (overrides OPENCODE_V2_STANDALONE)"
        echo "      --no-standalone  Start OpenCode v2 without --standalone (overrides OPENCODE_V2_STANDALONE)"
        echo "  -f, --force        Continue even in protected directories"
        echo "  -h, --help         Show this help and tool help"
        echo "---------------------------------------------------------------"
        echo "Launcher (set DEFAULT_LAUNCHER in .env): opencode (default), agy, claude"
        echo "Channel  (set OPENCODE_CHANNEL in .env): v1 = stable (default), v2 = beta"
        echo "v2 start (set OPENCODE_V2_STANDALONE in .env): false (default) or true"
        echo "---------------------------------------------------------------"
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo "---------------------------------------------------------------"
        echo "🛑 Error: Docker is not installed or not on PATH." >&2
        echo "   Install Docker and ensure the 'docker' CLI is available before running codebox." >&2
        echo "---------------------------------------------------------------"
        exit 1
    fi

    # IMPORTANT: Capture current directory BEFORE any operations
    local WORKSPACE_DIR="$PWD"
    local PROTECTED_DIRS=("$HOME")

    # Load additional protected directories from .env if present
    if [ -f "$OPENCODE_DOCKER_DIR/.env" ]; then
        local PROTECTED_DIRS_ENV=$(read_env_value PROTECTED_DIRS)
        if [ -n "$PROTECTED_DIRS_ENV" ]; then
            # Split colon-separated paths and add to PROTECTED_DIRS array
            IFS=':' read -ra ADDITIONAL_DIRS <<< "$PROTECTED_DIRS_ENV"
            for dir in "${ADDITIONAL_DIRS[@]}"; do
                if [ -n "$dir" ]; then
                    PROTECTED_DIRS+=("$dir")
                fi
            done
        fi
    fi

    # Check if running in a protected directory
    NEEDS_FORCE=false
    FORCE_REASON=""

    # Check exact matches with PROTECTED_DIRS (e.g., $HOME itself)
    for PROTECTED_DIR in "${PROTECTED_DIRS[@]}"; do
        if [ "$WORKSPACE_DIR" = "$PROTECTED_DIR" ]; then
            NEEDS_FORCE=true
            FORCE_REASON="Running in protected directory: $PROTECTED_DIR"
            break
        fi
    done

    # Check if WORKSPACE_DIR is outside $HOME (parent or sibling)
    if [ "$NEEDS_FORCE" = false ]; then
        case "$WORKSPACE_DIR" in
            "$HOME"/*)
                # Inside HOME - safe, no force needed
                ;;
            *)
                # Outside HOME - requires force
                NEEDS_FORCE=true
                FORCE_REASON="Running outside your home directory"
                ;;
        esac
    fi

    # Enforce or warn
    if [ "$NEEDS_FORCE" = true ]; then
        if [ "$FORCE_MODE" = true ]; then
            echo "---------------------------------------------------------------"
            echo "⚠️  Running in 'force' mode, use caution."
            echo "    Reason: $FORCE_REASON"
            echo "---------------------------------------------------------------"
            echo ""
        else
            echo "---------------------------------------------------------------"
            echo "⚠️  $FORCE_REASON"
            echo "    This can be dangerous. To continue anyway, rerun with:"
            echo "    codebox --force"
            echo "---------------------------------------------------------------"
            echo ""
            exit 1
        fi
    fi

    # Capture hostname and working directory name for dynamic container path
    local WORKSPACE_NAME="$(basename "$WORKSPACE_DIR")"
    local CONTAINER_HOSTNAME="$(hostname)"

    # Auto-detect current user's UID/GID
    export USER_UID=$(id -u)
    export USER_GID=$(id -g)

    # Username in container (from .env or default). The shell's USERNAME is
    # deliberately ignored: many hosts export it with the login name.
    local USERNAME=$(read_env_value USERNAME)
    USERNAME="${USERNAME:-dev}"

    # Check if OpenCode Docker directory exists
    if [ ! -d "$OPENCODE_DOCKER_DIR" ]; then
        exit_error "🛑 Error: OpenCode Docker directory not found at $OPENCODE_DOCKER_DIR"
    fi

    # Derive RELATIVE_PATH from OPENCODE_DOCKER_DIR relative to $HOME
    local RELATIVE_PATH=""
    if [[ "$OPENCODE_DOCKER_DIR" == "$HOME/"* ]]; then
        RELATIVE_PATH="${OPENCODE_DOCKER_DIR#"$HOME"/}"
        if [ -z "$RELATIVE_PATH" ]; then
            exit_error "🛑 Error: OPENCODE_DOCKER_DIR must be inside \$HOME and include at least one subdirectory"
        fi
    else
        exit_error "🛑 Error: OPENCODE_DOCKER_DIR must be under \$HOME to derive RELATIVE_PATH"
    fi

    # Resolve the OpenCode release channel (v1 = stable, v2 = beta).
    # The channel is a build-time toggle: switching it rewrites the image.
    local OPENCODE_CHANNEL=$(read_env_value OPENCODE_CHANNEL)
    OPENCODE_CHANNEL="${OPENCODE_CHANNEL:-v1}"
    if [ "$OPENCODE_CHANNEL" != "v1" ] && [ "$OPENCODE_CHANNEL" != "v2" ]; then
        exit_error "🛑 Error: OPENCODE_CHANNEL must be 'v1' or 'v2' (got: $OPENCODE_CHANNEL)"
    fi

    # Whether OpenCode v2 starts with --standalone (runtime option, no rebuild).
    # Priority: 1. --standalone/--no-standalone flags, 2. .env, 3. false
    local OPENCODE_V2_STANDALONE=$(read_env_value OPENCODE_V2_STANDALONE)
    OPENCODE_V2_STANDALONE="${OPENCODE_V2_STANDALONE:-false}"
    if [ "$OPENCODE_V2_STANDALONE" != "true" ] && [ "$OPENCODE_V2_STANDALONE" != "false" ]; then
        exit_error "🛑 Error: OPENCODE_V2_STANDALONE must be 'true' or 'false' (got: $OPENCODE_V2_STANDALONE)"
    fi
    if [ -n "$STANDALONE_OVERRIDE" ]; then
        OPENCODE_V2_STANDALONE="$STANDALONE_OVERRIDE"
    fi

    # OpenCode v2 uses isolated host data/state/cache dirs so it cannot mutate
    # the v1 session database or other stable data.
    local OC_DIR_SUFFIX=""
    if [ "$OPENCODE_CHANNEL" = "v2" ]; then
        OC_DIR_SUFFIX="2"
    fi
    local HOST_OC_DATA="$HOME/.local/share/opencode${OC_DIR_SUFFIX}"
    local HOST_OC_STATE="$HOME/.local/state/opencode${OC_DIR_SUFFIX}"
    local HOST_OC_CACHE="$HOME/.cache/opencode${OC_DIR_SUFFIX}"

    # Create required host directories for OpenCode
    if [ ! -d "$HOST_OC_DATA" ] || [ ! -d "$HOST_OC_STATE" ] || [ ! -d "$HOST_OC_CACHE" ]; then
        echo "------------------------------------------------------------------------"
        echo "📁 Missing OpenCode directories used to maintain data and state across sessions..."
        if [ ! -d "$HOST_OC_DATA" ]; then
            echo "  - Creating directory  [OCData]: ${HOST_OC_DATA}"
            mkdir -p "$HOST_OC_DATA"
        fi
        if [ ! -d "$HOST_OC_STATE" ]; then
            echo "  - Creating directory [OCState]: ${HOST_OC_STATE}"
            mkdir -p "$HOST_OC_STATE"
        fi
        if [ ! -d "$HOST_OC_CACHE" ]; then
            echo "  - Creating directory [OCCache]: ${HOST_OC_CACHE}"
            mkdir -p "$HOST_OC_CACHE"
        fi
        echo "------------------------------------------------------------------------"
        echo ""
    fi

    # Check if .env exists
    if [ ! -f "$OPENCODE_DOCKER_DIR/.env" ]; then
        echo "------------------------------------------------------------------------"
        echo "⚠️  Warning: .env file not found at $OPENCODE_DOCKER_DIR/.env"
        echo "    - Creating .env from $OPENCODE_DOCKER_DIR/.env.example..."
        if [ ! -f "$OPENCODE_DOCKER_DIR/.env.example" ]; then
            exit_error "🛑 Error: .env.example not found at $OPENCODE_DOCKER_DIR/.env.example"
        fi
        cp "$OPENCODE_DOCKER_DIR/.env.example" "$OPENCODE_DOCKER_DIR/.env"
        echo ""
        echo "📝  Please edit .env and add your API keys (if needed) before continuing"
        echo "    - Edit: vim $OPENCODE_DOCKER_DIR/.env"
        echo "    - Or: rerun codebox now to use the default settings"
        echo "------------------------------------------------------------------------"
        echo ""
        exit 1
    fi

    # Load CODEBOX_NAME from .env if not already set in environment
    # Priority: 1. CLI argument (-n), 2. Shell environment, 3. .env file, 4. default (BOX)
    local CODEBOX_NAME=""
    if [ -n "$CLI_CODEBOX_NAME" ]; then
        CODEBOX_NAME="$CLI_CODEBOX_NAME"
    elif [ -n "${CODEBOX_NAME_ENV:-}" ]; then
        # Allow persistent setting via CODEBOX_NAME_ENV to avoid pollution
        CODEBOX_NAME="${CODEBOX_NAME_ENV}"
    else
        CODEBOX_NAME=$(read_env_value CODEBOX_NAME)
    fi
    CODEBOX_NAME="${CODEBOX_NAME:-BOX}"
    local CONTAINER_WORKDIR="/${CODEBOX_NAME}/${CONTAINER_HOSTNAME}/${WORKSPACE_NAME}"

    # Claude Code CLI build settings (from .env)
    local ENABLE_CLAUDE_CLI=$(read_env_value ENABLE_CLAUDE_CLI)
    ENABLE_CLAUDE_CLI="${ENABLE_CLAUDE_CLI:-false}"
    local CLAUDE_CODE_VERSION=$(read_env_value CLAUDE_CODE_VERSION)
    CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-latest}"

    # Determine which launcher to run: opencode, agy, or claude
    # Priority: 1. explicit flags (--opencode/--claude/--agy), 2. DEFAULT_LAUNCHER
    # in .env, 3. opencode (default)
    local DEFAULT_LAUNCHER=$(read_env_value DEFAULT_LAUNCHER)
    DEFAULT_LAUNCHER="${DEFAULT_LAUNCHER:-opencode}"
    case "$DEFAULT_LAUNCHER" in
        opencode|agy|claude) ;;
        *)
            exit_error "🛑 Error: DEFAULT_LAUNCHER must be 'opencode', 'agy', or 'claude' (got: $DEFAULT_LAUNCHER)"
            ;;
    esac
    local LAUNCHER="$DEFAULT_LAUNCHER"
    if [ "$AGY_MODE" = true ]; then
        LAUNCHER="agy"
    fi
    if [ "$CLAUDE_MODE" = true ]; then
        LAUNCHER="claude"
    fi
    if [ "$OPENCODE_MODE" = true ]; then
        LAUNCHER="opencode"
    fi

    if [ "$BASH_MODE" != true ] && [ "$LAUNCHER" = "claude" ] && [ "$ENABLE_CLAUDE_CLI" != "true" ]; then
        exit_error "🛑 Error: Claude Code CLI is not installed in the image.
   Set ENABLE_CLAUDE_CLI=true in .env, then run: codebox --update"
    fi

    # Standalone mode only applies when launching OpenCode on the v2 channel
    local USE_STANDALONE=false
    if [ "$OPENCODE_V2_STANDALONE" = "true" ] && [ "$OPENCODE_CHANNEL" = "v2" ] \
        && [ "$BASH_MODE" != true ] && [ "$LAUNCHER" = "opencode" ]; then
        USE_STANDALONE=true
    elif [ -n "$STANDALONE_OVERRIDE" ] && { [ "$OPENCODE_CHANNEL" != "v2" ] || [ "$BASH_MODE" = true ] || [ "$LAUNCHER" != "opencode" ]; }; then
        echo "⚠️  Warning: --standalone/--no-standalone only applies to OpenCode v2 (OPENCODE_CHANNEL=v2); ignoring"
        echo ""
    fi

    # Ensure host directory for Antigravity CLI (agy) data persists across sessions
    if [ "$LAUNCHER" = "agy" ] && [ ! -d "$HOME/.gemini" ]; then
        echo "------------------------------------------------------------------------"
        echo "📁 Creating directory [AGYData]: ${HOME}/.gemini"
        mkdir -p "$HOME/.gemini"
        echo "------------------------------------------------------------------------"
        echo ""
    fi

    # Resolve a custom host Claude Code config directory (CLAUDE_CONFIG_DIR style).
    # Priority: 1. --claude-config, 2. HOST_CLAUDE_CONFIG_DIR in .env,
    # 3. CLAUDE_CONFIG_DIR in the host environment. Empty = default ~/.claude layout.
    local HOST_CLAUDE_CONFIG_DIR="$CLI_CLAUDE_CONFIG_DIR"
    if [ -z "$HOST_CLAUDE_CONFIG_DIR" ]; then
        HOST_CLAUDE_CONFIG_DIR=$(read_env_value HOST_CLAUDE_CONFIG_DIR)
    fi
    if [ -z "$HOST_CLAUDE_CONFIG_DIR" ]; then
        HOST_CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}"
    fi
    if [ -n "$HOST_CLAUDE_CONFIG_DIR" ]; then
        HOST_CLAUDE_CONFIG_DIR="${HOST_CLAUDE_CONFIG_DIR/#\~/$HOME}"
    fi

    # Create Claude Code host directories/files so config and sessions persist
    # and can be bind-mounted (Docker mounts a missing file path as a directory).
    # A custom config directory holds its own .claude.json, so it must already exist.
    if [ "$ENABLE_CLAUDE_CLI" = "true" ] && [ -n "$HOST_CLAUDE_CONFIG_DIR" ]; then
        if [ ! -d "$HOST_CLAUDE_CONFIG_DIR" ]; then
            exit_error "🛑 Error: Claude config directory does not exist or is not a directory.
   Path: $HOST_CLAUDE_CONFIG_DIR
   Create it first, then rerun codebox:
       mkdir -p $HOST_CLAUDE_CONFIG_DIR"
        fi
        HOST_CLAUDE_CONFIG_DIR=$(cd "$HOST_CLAUDE_CONFIG_DIR" && pwd -P)
    elif [ "$ENABLE_CLAUDE_CLI" = "true" ]; then
        if [ ! -d "$HOME/.claude" ]; then
            echo "------------------------------------------------------------------------"
            echo "📁 Creating directory [ClaudeCfg]: ${HOME}/.claude"
            mkdir -p "$HOME/.claude"
            echo "------------------------------------------------------------------------"
            echo ""
        fi
        if [ -d "$HOME/.claude.json" ]; then
            exit_error "🛑 Error: ${HOME}/.claude.json is a directory; remove or rename it before running codebox."
        elif [ ! -e "$HOME/.claude.json" ]; then
            printf '{}\n' > "$HOME/.claude.json"
        fi
    fi

    if [ "$UPDATE_REQUESTED" = true ]; then
        echo "---------------------------------------------------------------"
        echo "🔄 Updating OpenCode Docker container..."
        echo "---------------------------------------------------------------"
        # Extract build args from .env
        local DOCKER_PACKAGES=$(read_env_value DOCKER_PACKAGES)
        local OPENCODE_VERSION=$(read_env_value OPENCODE_VERSION)
        local ENABLE_SNAKEMAKE_STACK=$(read_env_value ENABLE_SNAKEMAKE_STACK)
        local SNAKEMAKE_VERSION=$(read_env_value SNAKEMAKE_VERSION)
        local ENABLE_AGY=$(read_env_value ENABLE_AGY)
        OPENCODE_VERSION="${OPENCODE_VERSION:-latest}"
        ENABLE_SNAKEMAKE_STACK="${ENABLE_SNAKEMAKE_STACK:-false}"
        SNAKEMAKE_VERSION="${SNAKEMAKE_VERSION:-8.30}"
        ENABLE_AGY="${ENABLE_AGY:-false}"
        docker build \
            --pull \
            --no-cache \
            --build-arg UID="$USER_UID" \
            --build-arg GID="$USER_GID" \
            --build-arg OPENCODE_CHANNEL="$OPENCODE_CHANNEL" \
            --build-arg OPENCODE_VERSION="$OPENCODE_VERSION" \
            --build-arg USERNAME="${USERNAME:-dev}" \
            --build-arg CODEBOX_NAME="$CODEBOX_NAME" \
            --build-arg DOCKER_PACKAGES="$DOCKER_PACKAGES" \
            --build-arg ENABLE_SNAKEMAKE_STACK="$ENABLE_SNAKEMAKE_STACK" \
            --build-arg SNAKEMAKE_VERSION="$SNAKEMAKE_VERSION" \
            --build-arg ENABLE_AGY="$ENABLE_AGY" \
            --build-arg ENABLE_CLAUDE_CLI="$ENABLE_CLAUDE_CLI" \
            --build-arg CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" \
            -t opencode-dev:latest \
            "$OPENCODE_DOCKER_DIR" || exit_error "🛑 Error: Docker build failed during update"
        echo ""
        echo "✅ Update complete!"
        echo ""
    fi

    # Optional Docker cleanup controls
    local AUTO_PRUNE=$(read_env_value AUTO_PRUNE)
    AUTO_PRUNE="${AUTO_PRUNE:-false}"
    local PRUNE_MAX_AGE=$(read_env_value PRUNE_MAX_AGE)
    PRUNE_MAX_AGE="${PRUNE_MAX_AGE:-168h}"

    # Check if image exists or if it was built with different UID/GID/CODEBOX_NAME
    IMAGE_ENV=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' opencode-dev:latest 2>/dev/null || true)
    IMAGE_UID=$(printf '%s\n' "$IMAGE_ENV" | awk -F= '$1=="UID"{print $2; exit}')
    IMAGE_GID=$(printf '%s\n' "$IMAGE_ENV" | awk -F= '$1=="GID"{print $2; exit}')
    IMAGE_CODEBOX=$(printf '%s\n' "$IMAGE_ENV" | awk -F= '$1=="CODEBOX_NAME"{print $2; exit}')
    IMAGE_ENABLE_SNAKEMAKE_STACK=$(printf '%s\n' "$IMAGE_ENV" | awk -F= '$1=="ENABLE_SNAKEMAKE_STACK"{print $2; exit}')
    IMAGE_SNAKEMAKE_VERSION=$(printf '%s\n' "$IMAGE_ENV" | awk -F= '$1=="SNAKEMAKE_VERSION"{print $2; exit}')
    IMAGE_ENABLE_AGY=$(printf '%s\n' "$IMAGE_ENV" | awk -F= '$1=="ENABLE_AGY"{print $2; exit}')
    IMAGE_OPENCODE_CHANNEL=$(printf '%s\n' "$IMAGE_ENV" | awk -F= '$1=="OPENCODE_CHANNEL"{print $2; exit}')
    IMAGE_ENABLE_CLAUDE_CLI=$(printf '%s\n' "$IMAGE_ENV" | awk -F= '$1=="ENABLE_CLAUDE_CLI"{print $2; exit}')
    IMAGE_CLAUDE_CODE_VERSION=$(printf '%s\n' "$IMAGE_ENV" | awk -F= '$1=="CLAUDE_CODE_VERSION"{print $2; exit}')

    ENV_ENABLE_SNAKEMAKE_STACK=$(read_env_value ENABLE_SNAKEMAKE_STACK)
    ENV_SNAKEMAKE_VERSION=$(read_env_value SNAKEMAKE_VERSION)
    ENV_ENABLE_AGY=$(read_env_value ENABLE_AGY)
    ENV_ENABLE_SNAKEMAKE_STACK="${ENV_ENABLE_SNAKEMAKE_STACK:-false}"
    ENV_SNAKEMAKE_VERSION="${ENV_SNAKEMAKE_VERSION:-8.30}"
    ENV_ENABLE_AGY="${ENV_ENABLE_AGY:-false}"
    ENV_OPENCODE_CHANNEL="${OPENCODE_CHANNEL:-v1}"
    ENV_ENABLE_CLAUDE_CLI="${ENABLE_CLAUDE_CLI:-false}"
    ENV_CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-latest}"

    NEEDS_REBUILD=false
    REBUILD_REASON=""
    IMAGE_REBUILT=false

    if [ -z "$IMAGE_UID" ] || [ "$IMAGE_UID" != "$USER_UID" ] || [ -z "$IMAGE_GID" ] || [ "$IMAGE_GID" != "$USER_GID" ]; then
        NEEDS_REBUILD=true
        REBUILD_REASON="UID/GID mismatch (image: ${IMAGE_UID:-none}/${IMAGE_GID:-none}, current: $USER_UID/$USER_GID)"
    fi

    if [ -n "$IMAGE_CODEBOX" ] && [ "$IMAGE_CODEBOX" != "$CODEBOX_NAME" ]; then
        NEEDS_REBUILD=true
        if [ -n "$REBUILD_REASON" ]; then
            REBUILD_REASON="$REBUILD_REASON; CODEBOX_NAME changed (image: $IMAGE_CODEBOX, current: $CODEBOX_NAME)"
        else
            REBUILD_REASON="CODEBOX_NAME changed (image: $IMAGE_CODEBOX, current: $CODEBOX_NAME)"
        fi
    fi

    if [ -n "$IMAGE_ENABLE_SNAKEMAKE_STACK" ] && [ "$IMAGE_ENABLE_SNAKEMAKE_STACK" != "$ENV_ENABLE_SNAKEMAKE_STACK" ]; then
        NEEDS_REBUILD=true
        if [ -n "$REBUILD_REASON" ]; then
            REBUILD_REASON="$REBUILD_REASON; ENABLE_SNAKEMAKE_STACK changed (image: $IMAGE_ENABLE_SNAKEMAKE_STACK, current: $ENV_ENABLE_SNAKEMAKE_STACK)"
        else
            REBUILD_REASON="ENABLE_SNAKEMAKE_STACK changed (image: $IMAGE_ENABLE_SNAKEMAKE_STACK, current: $ENV_ENABLE_SNAKEMAKE_STACK)"
        fi
    fi

    if [ -n "$IMAGE_SNAKEMAKE_VERSION" ] && [ "$IMAGE_SNAKEMAKE_VERSION" != "$ENV_SNAKEMAKE_VERSION" ]; then
        NEEDS_REBUILD=true
        if [ -n "$REBUILD_REASON" ]; then
            REBUILD_REASON="$REBUILD_REASON; SNAKEMAKE_VERSION changed (image: $IMAGE_SNAKEMAKE_VERSION, current: $ENV_SNAKEMAKE_VERSION)"
        else
            REBUILD_REASON="SNAKEMAKE_VERSION changed (image: $IMAGE_SNAKEMAKE_VERSION, current: $ENV_SNAKEMAKE_VERSION)"
        fi
    fi

    if [ -n "$IMAGE_ENABLE_AGY" ] && [ "$IMAGE_ENABLE_AGY" != "$ENV_ENABLE_AGY" ]; then
        NEEDS_REBUILD=true
        if [ -n "$REBUILD_REASON" ]; then
            REBUILD_REASON="$REBUILD_REASON; ENABLE_AGY changed (image: $IMAGE_ENABLE_AGY, current: $ENV_ENABLE_AGY)"
        else
            REBUILD_REASON="ENABLE_AGY changed (image: $IMAGE_ENABLE_AGY, current: $ENV_ENABLE_AGY)"
        fi
    fi

    if [ -n "$IMAGE_OPENCODE_CHANNEL" ] && [ "$IMAGE_OPENCODE_CHANNEL" != "$ENV_OPENCODE_CHANNEL" ]; then
        NEEDS_REBUILD=true
        if [ -n "$REBUILD_REASON" ]; then
            REBUILD_REASON="$REBUILD_REASON; OPENCODE_CHANNEL changed (image: $IMAGE_OPENCODE_CHANNEL, current: $ENV_OPENCODE_CHANNEL)"
        else
            REBUILD_REASON="OPENCODE_CHANNEL changed (image: $IMAGE_OPENCODE_CHANNEL, current: $ENV_OPENCODE_CHANNEL)"
        fi
    fi

    if [ -n "$IMAGE_ENABLE_CLAUDE_CLI" ] && [ "$IMAGE_ENABLE_CLAUDE_CLI" != "$ENV_ENABLE_CLAUDE_CLI" ]; then
        NEEDS_REBUILD=true
        if [ -n "$REBUILD_REASON" ]; then
            REBUILD_REASON="$REBUILD_REASON; ENABLE_CLAUDE_CLI changed (image: $IMAGE_ENABLE_CLAUDE_CLI, current: $ENV_ENABLE_CLAUDE_CLI)"
        else
            REBUILD_REASON="ENABLE_CLAUDE_CLI changed (image: $IMAGE_ENABLE_CLAUDE_CLI, current: $ENV_ENABLE_CLAUDE_CLI)"
        fi
    fi

    if [ -n "$IMAGE_CLAUDE_CODE_VERSION" ] && [ "$IMAGE_CLAUDE_CODE_VERSION" != "$ENV_CLAUDE_CODE_VERSION" ]; then
        NEEDS_REBUILD=true
        if [ -n "$REBUILD_REASON" ]; then
            REBUILD_REASON="$REBUILD_REASON; CLAUDE_CODE_VERSION changed (image: $IMAGE_CLAUDE_CODE_VERSION, current: $ENV_CLAUDE_CODE_VERSION)"
        else
            REBUILD_REASON="CLAUDE_CODE_VERSION changed (image: $IMAGE_CLAUDE_CODE_VERSION, current: $ENV_CLAUDE_CODE_VERSION)"
        fi
    fi

    if [ "$NEEDS_REBUILD" = true ]; then
        echo "---------------------------------------------------------------"
        echo "🏗️  Building OpenCode Docker Image"
        echo "    Reason: $REBUILD_REASON"
        echo "    UID=$USER_UID, GID=$USER_GID, CODEBOX_NAME=$CODEBOX_NAME"
        echo "---------------------------------------------------------------"
        # Extract build args from .env
        local DOCKER_PACKAGES=$(read_env_value DOCKER_PACKAGES)
        local OPENCODE_VERSION=$(read_env_value OPENCODE_VERSION)
        local ENABLE_SNAKEMAKE_STACK=$(read_env_value ENABLE_SNAKEMAKE_STACK)
        local SNAKEMAKE_VERSION=$(read_env_value SNAKEMAKE_VERSION)
        local ENABLE_AGY=$(read_env_value ENABLE_AGY)
        OPENCODE_VERSION="${OPENCODE_VERSION:-latest}"
        ENABLE_SNAKEMAKE_STACK="${ENABLE_SNAKEMAKE_STACK:-false}"
        SNAKEMAKE_VERSION="${SNAKEMAKE_VERSION:-8.30}"
        ENABLE_AGY="${ENABLE_AGY:-false}"
        docker build \
            --build-arg UID="$USER_UID" \
            --build-arg GID="$USER_GID" \
            --build-arg OPENCODE_CHANNEL="$OPENCODE_CHANNEL" \
            --build-arg OPENCODE_VERSION="$OPENCODE_VERSION" \
            --build-arg USERNAME="${USERNAME:-dev}" \
            --build-arg CODEBOX_NAME="$CODEBOX_NAME" \
            --build-arg DOCKER_PACKAGES="$DOCKER_PACKAGES" \
            --build-arg ENABLE_SNAKEMAKE_STACK="$ENABLE_SNAKEMAKE_STACK" \
            --build-arg SNAKEMAKE_VERSION="$SNAKEMAKE_VERSION" \
            --build-arg ENABLE_AGY="$ENABLE_AGY" \
            --build-arg ENABLE_CLAUDE_CLI="$ENABLE_CLAUDE_CLI" \
            --build-arg CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" \
            -t opencode-dev:latest \
            "$OPENCODE_DOCKER_DIR"
        IMAGE_REBUILT=true
    fi

    # Manual prune, or optional prune after rebuild/update
    if [ "$PRUNE_REQUESTED" = true ]; then
        run_docker_prune "$PRUNE_MAX_AGE"
    elif [ "$AUTO_PRUNE" = "true" ] && { [ "$UPDATE_REQUESTED" = true ] || [ "$IMAGE_REBUILT" = true ]; }; then
        run_docker_prune "$PRUNE_MAX_AGE"
    fi

    # Check if HOST_OPENCODE_CONFIG_DIR is set in .env
    local HOST_OPENCODE_CONFIG_DIR=$(read_env_value HOST_OPENCODE_CONFIG_DIR)
    if [ -n "$HOST_OPENCODE_CONFIG_DIR" ]; then
        if [ ! -d "$HOST_OPENCODE_CONFIG_DIR" ]; then
            echo "--------------------------------------------------------------------------------" >&2
            echo "🛑 Error: HOST_OPENCODE_CONFIG_DIR does not exist or is not a directory." >&2
            echo "   Path: $HOST_OPENCODE_CONFIG_DIR" >&2
            echo ""
            echo "   Create it first (2 options), then rerun codebox:" >&2
            echo ""
            echo "   - Option 1: Create an empty directory:" >&2
            echo "       mkdir -p $HOST_OPENCODE_CONFIG_DIR" >&2
            echo ""
            echo "   - Option 2: Copy example config to get started:" >&2
            echo "       cp -R ${OPENCODE_DOCKER_DIR}/config.opencode.example $HOST_OPENCODE_CONFIG_DIR" >&2
            echo "--------------------------------------------------------------------------------" >&2
            exit 1
        fi
    fi

    # Resolve TZ from env/.env with Edmonton default
    local TZ_VALUE="${TZ:-}"
    if [ -z "$TZ_VALUE" ]; then
        TZ_VALUE=$(read_env_value TZ)
    fi
    TZ_VALUE="${TZ_VALUE:-America/Edmonton}"

    # Run the selected launcher with current directory as workspace
    echo "---------------------------------------------------------------"
    if [ "$BASH_MODE" = true ]; then
        echo "📦 Starting bash session in: $WORKSPACE_DIR"
    elif [ "$LAUNCHER" = "agy" ]; then
        echo "📦 Starting Antigravity CLI (agy) in: $WORKSPACE_DIR"
    elif [ "$LAUNCHER" = "claude" ]; then
        echo "📦 Starting Claude Code in: $WORKSPACE_DIR"
    else
        echo "📦 Starting OpenCode in: $WORKSPACE_DIR"
    fi
    if [ "$USE_STANDALONE" = true ]; then
        echo "   OpenCode v2 mode: standalone"
    fi
    echo "   Container path: $CONTAINER_WORKDIR"
    echo "   (UID=$USER_UID, GID=$USER_GID, CODEBOX_NAME=$CODEBOX_NAME, TZ=$TZ_VALUE)"
    echo "   Environment: $OPENCODE_DOCKER_DIR/.env"

    # Read SHOW_MOUNTS setting (default to true if not set)
    local SHOW_MOUNTS=$(read_env_value SHOW_MOUNTS)
    SHOW_MOUNTS="${SHOW_MOUNTS:-true}"

    # Display volume mounts if enabled
    if [ "$SHOW_MOUNTS" = "true" ]; then
        echo "   Volume mounts:"
        echo "   - [Working]  $WORKSPACE_DIR → $CONTAINER_WORKDIR"
        if [ -n "$HOST_OPENCODE_CONFIG_DIR" ]; then
            echo "   - [OCConfig] ${HOST_OPENCODE_CONFIG_DIR} → /home/${USERNAME}/.config/opencode"
        fi
        echo "   - [OCData]   ${HOST_OC_DATA} → /home/${USERNAME}/.local/share/opencode"
        echo "   - [OCState]  ${HOST_OC_STATE} → /home/${USERNAME}/.local/state/opencode"
        echo "   - [OCCache]  ${HOST_OC_CACHE} → /home/${USERNAME}/.cache/opencode"
        if [ "$LAUNCHER" = "agy" ]; then
            echo "   - [AGYData]  ${HOME}/.gemini → /home/${USERNAME}/.gemini"
        fi
        if [ "$ENABLE_CLAUDE_CLI" = "true" ] && [ -n "$HOST_CLAUDE_CONFIG_DIR" ]; then
            echo "   - [ClaudeCfg]  ${HOST_CLAUDE_CONFIG_DIR} → /home/${USERNAME}/.claude (CLAUDE_CONFIG_DIR)"
        elif [ "$ENABLE_CLAUDE_CLI" = "true" ]; then
            echo "   - [ClaudeCfg]  ${HOME}/.claude → /home/${USERNAME}/.claude"
            echo "   - [ClaudeJSON] ${HOME}/.claude.json → /home/${USERNAME}/.claude.json"
        fi
        if [ "$OAUTH_ENABLED" = true ]; then
            echo "   OAuth callback: http://127.0.0.1:1455"
        fi
    fi
    
    # Check if a custom network was provided via environment variable
    NETWORK_FLAG=""
    if [[ -v PROJECT_NETWORK ]]; then
        NETWORK_FLAG="--network $PROJECT_NETWORK"
        echo "   Attaching CodeBox to network: $PROJECT_NETWORK"
    fi
    
    echo "---------------------------------------------------------------"
    echo ""
    local CONFIG_MOUNT_ARGS=()
    if [ -n "$HOST_OPENCODE_CONFIG_DIR" ]; then
        CONFIG_MOUNT_ARGS=(-v "${HOST_OPENCODE_CONFIG_DIR}:/home/${USERNAME}/.config/opencode")
    fi

    # Mount Claude Code config/state so global config and sessions persist on the host
    # A custom config dir is exposed via CLAUDE_CONFIG_DIR, so Claude reads
    # .claude.json from inside it (same layout as on the host). The -e flag
    # also overrides any CLAUDE_CONFIG_DIR passed through --env-file.
    local CLAUDE_MOUNT_ARGS=()
    if [ "$ENABLE_CLAUDE_CLI" = "true" ] && [ -n "$HOST_CLAUDE_CONFIG_DIR" ]; then
        CLAUDE_MOUNT_ARGS=(
            -v "${HOST_CLAUDE_CONFIG_DIR}:/home/${USERNAME}/.claude"
            -e CLAUDE_CONFIG_DIR="/home/${USERNAME}/.claude"
        )
    elif [ "$ENABLE_CLAUDE_CLI" = "true" ]; then
        CLAUDE_MOUNT_ARGS=(
            -v "${HOME}/.claude:/home/${USERNAME}/.claude"
            -v "${HOME}/.claude.json:/home/${USERNAME}/.claude.json"
        )
    fi

    # Forward the host display session so clipboard tools (wl-paste, xclip) work
    local DISPLAY_ARGS=()
    build_display_args "$(read_env_value DISPLAY_FORWARDING)"

    # Build docker run command with common arguments
    local DOCKER_ARGS=(
        --rm -it
        --cap-drop ALL
        --security-opt no-new-privileges
        $NETWORK_FLAG
        --env-file "$OPENCODE_DOCKER_DIR/.env"
        -e CODEBOX_NAME="${CODEBOX_NAME}"
        -e TZ="$TZ_VALUE"
        -e BASH_ENV="/home/${USERNAME}/.bashrc"
        -w "$CONTAINER_WORKDIR"
        -v "$WORKSPACE_DIR:$CONTAINER_WORKDIR"
        "${CONFIG_MOUNT_ARGS[@]}"
        -v "${HOST_OC_DATA}:/home/${USERNAME}/.local/share/opencode"
        -v "${HOST_OC_STATE}:/home/${USERNAME}/.local/state/opencode"
        -v "${HOST_OC_CACHE}:/home/${USERNAME}/.cache/opencode"
        "${CLAUDE_MOUNT_ARGS[@]}"
        -e TERM="$TERM"
        -e COLORTERM="truecolor"
        "${DISPLAY_ARGS[@]}"
    )

    # Add OAuth port binding if requested
    if [ "$OAUTH_ENABLED" = true ]; then
        DOCKER_ARGS+=(-p 127.0.0.1:1455:1455)
    fi

    # Add agy-specific arguments when launching Antigravity CLI
    if [ "$LAUNCHER" = "agy" ]; then
        DOCKER_ARGS+=(-e CODEBOX_MODE=agy)
        DOCKER_ARGS+=(-v "${HOME}/.gemini:/home/${USERNAME}/.gemini")
        # Enable agy's Remote SSH OAuth flow (browser-based sign-in, no keyring needed).
        # With AGY_REMOTE_AUTH=true in .env we fabricate SSH env vars so agy prints a
        # secure authorization URL even when running locally (copy URL -> sign in in
        # your browser -> paste the code back). Otherwise pass through real SSH vars
        # when the host session itself is over SSH.
        local AGY_REMOTE_AUTH=$(read_env_value AGY_REMOTE_AUTH)
        AGY_REMOTE_AUTH="${AGY_REMOTE_AUTH:-false}"
        if [ "$AGY_REMOTE_AUTH" = "true" ]; then
            DOCKER_ARGS+=(-e SSH_CONNECTION="127.0.0.1 22 127.0.0.1 22")
            DOCKER_ARGS+=(-e SSH_CLIENT="127.0.0.1 22 127.0.0.1")
            DOCKER_ARGS+=(-e SSH_TTY="/dev/pts/0")
        else
            [ -n "${SSH_CONNECTION:-}" ] && DOCKER_ARGS+=(-e SSH_CONNECTION="$SSH_CONNECTION")
            [ -n "${SSH_CLIENT:-}" ] && DOCKER_ARGS+=(-e SSH_CLIENT="$SSH_CLIENT")
            [ -n "${SSH_TTY:-}" ] && DOCKER_ARGS+=(-e SSH_TTY="$SSH_TTY")
        fi
    fi

    # Select the container entrypoint
    # Priority: bash mode > Claude Code > default entrypoint (OpenCode/agy)
    if [ "$BASH_MODE" = true ]; then
        DOCKER_ARGS+=(--entrypoint /bin/bash)
    elif [ "$LAUNCHER" = "claude" ]; then
        DOCKER_ARGS+=(--entrypoint "/home/${USERNAME}/.local/bin/claude")
    fi

    if [ "$USE_STANDALONE" = true ]; then
        OPENCODE_ARGS=(--standalone "${OPENCODE_ARGS[@]}")
    fi

    # Run the container
    docker run "${DOCKER_ARGS[@]}" opencode-dev:latest "${OPENCODE_ARGS[@]}"

}

main "$@"
