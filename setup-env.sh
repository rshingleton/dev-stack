#!/bin/bash
# =====================================================================
# setup-env.sh - Unified Development Stack Setup Script
# Targets: macOS (Laptop), Red Hat (Workstation), Ubuntu (VPS)
# Windows support: not yet implemented, see stub at bottom.
# =====================================================================
#
# Design rules:
#   1. Perl Principle - never force a system-wide Perl reinstall if a
#      working binary is already discoverable on PATH.
#   2. Idempotency - every block is safe to re-run.
#   3. Conflict isolation - tmux keeps the factory-default Ctrl+b
#      prefix so it never collides with LazyVim navigation keys
#      (vim-tmux-navigator binds C-h/j/k/l directly).
#
# This script provisions system packages, and treats nvim/ and
# tmux/tmux.conf in this repo as the dotfiles source of truth:
# ~/.config/nvim and ~/.tmux.conf are symlinked back to them (any
# existing real config is backed up first, never deleted). Edit the
# files in this repo, not the symlink targets, and commit your
# changes - that's what makes this reusable by anyone who clones it.
#
# dev-start takes a project path as an argument (dev-start [path]) -
# there is no hardcoded project list to maintain.
# =====================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Starting environment setup..."
echo "Using dotfiles from: $SCRIPT_DIR"

log()  { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

ensure_line_in_file() {
    local file="$1"
    local line="$2"
    touch "$file"
    grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

# link_dotfile <source-in-repo> <target-in-home>
# Idempotent: if target is already a symlink to source, does nothing.
# If target is a real file/directory, backs it up (never deletes) and
# then symlinks. Works for both files and directories.
link_dotfile() {
    local src="$1" dest="$2"

    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
        log "$dest already linked to $src, skipping"
        return
    fi

    if [ -e "$dest" ] || [ -L "$dest" ]; then
        local backup="${dest}.bak.$(date +%Y%m%d%H%M%S)"
        warn "Existing $dest found - backing it up to $backup before linking"
        mv "$dest" "$backup"
    fi

    mkdir -p "$(dirname "$dest")"
    ln -s "$src" "$dest"
    log "Linked $dest -> $src"
}

# -----------------------------------------------------------------
# 1. Perl discovery (Perl Principle)
#    Never force a reinstall if a working binary is already
#    discoverable. perl.lua's perlnavigator config uses perlPath =
#    "perl", so whatever resolves on PATH is what LSP/prove/perltidy
#    will use too.
# -----------------------------------------------------------------

ACTIVE_PERL_BIN="$(command -v perl 2>/dev/null || true)"
if [ -n "$ACTIVE_PERL_BIN" ]; then
    PERL_VERSION_STRING="$("$ACTIVE_PERL_BIN" -e 'print $^V' 2>/dev/null || echo "unknown")"
    log "Perl already available: $ACTIVE_PERL_BIN ($PERL_VERSION_STRING)"
else
    warn "No perl binary discoverable on PATH yet. It will be installed below."
fi

# -----------------------------------------------------------------
# 2. OS detection
# -----------------------------------------------------------------

OS_FAMILY="unknown"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS_FAMILY="macos"
elif [ -f /etc/redhat-release ]; then
    OS_FAMILY="rhel"
elif [ -f /etc/os-release ] && grep -qi ubuntu /etc/os-release; then
    OS_FAMILY="ubuntu"
fi

log "Detected OS family: $OS_FAMILY"

# -----------------------------------------------------------------
# 3. Perl tooling needed by lua/plugins/perl.lua, installed via cpanm
#    so it works the same way across all three OS families, and only
#    runs if the module isn't already present (idempotent).
#    - Perl::Tidy   -> `perltidy` binary, used by conform.nvim
#    - Perl::Critic -> `perlcritic` binary, used by perlnavigator
# -----------------------------------------------------------------

install_perl_cpan_tools() {
    if ! have cpanm; then
        warn "cpanm not found; skipping Perl::Tidy / Perl::Critic install. Install cpanminus first."
        return
    fi

    if have perltidy; then
        log "perltidy already installed, skipping"
    else
        log "Installing Perl::Tidy via cpanm"
        cpanm --notest Perl::Tidy
    fi

    if have perlcritic; then
        log "perlcritic already installed, skipping"
    else
        log "Installing Perl::Critic via cpanm"
        cpanm --notest Perl::Critic
    fi
}

# -----------------------------------------------------------------
# 4. OS-specific provisioning
# -----------------------------------------------------------------

provision_macos() {
    log "Syncing macOS toolchain..."

    if ! have brew; then
        warn "Homebrew is required on macOS. Install it from https://brew.sh, then re-run this script."
        return
    fi

    local pkgs=(tmux neovim git lazygit fzf fd ripgrep go python3 node perl cpanminus)
    for pkg in "${pkgs[@]}"; do
        if brew list --versions "$pkg" >/dev/null 2>&1; then
            log "brew: $pkg already installed, skipping"
        else
            log "brew: installing $pkg"
            brew install "$pkg"
        fi
    done
}

provision_rhel() {
    log "Syncing Red Hat Enterprise workspace..."

    if ! have dnf; then
        warn "dnf not found. Cannot provision packages."
        return
    fi

    sudo dnf check-update || true

    local pkgs=(tmux neovim lazygit fzf fd-find ripgrep gcc make golang python3 nodejs)
    for pkg in "${pkgs[@]}"; do
        if rpm -q "$pkg" >/dev/null 2>&1; then
            log "dnf: $pkg already installed, skipping"
        else
            log "dnf: installing $pkg"
            sudo dnf install -y "$pkg"
        fi
    done

    if [ -z "$ACTIVE_PERL_BIN" ]; then
        log "No base Perl found. Installing perl-interpreter + cpanminus"
        sudo dnf install -y perl-interpreter perl-App-cpanminus
    elif ! have cpanm; then
        log "Perl present but cpanm missing. Installing perl-App-cpanminus"
        sudo dnf install -y perl-App-cpanminus
    fi
}

provision_ubuntu() {
    log "Syncing Debian/Ubuntu cloud layer..."

    if ! have apt-get; then
        warn "apt-get not found. Cannot provision packages."
        return
    fi

    sudo apt-get update -y

    local pkgs=(tmux neovim lazygit fzf fd-find ripgrep build-essential golang-go python3 python3-pip nodejs npm)
    for pkg in "${pkgs[@]}"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            log "apt: $pkg already installed, skipping"
        else
            log "apt: installing $pkg"
            sudo apt-get install -y "$pkg"
        fi
    done

    if [ -z "$ACTIVE_PERL_BIN" ]; then
        log "No base Perl found. Installing perl + cpanminus"
        sudo apt-get install -y perl cpanminus
    elif ! have cpanm; then
        log "Perl present but cpanm missing. Installing cpanminus"
        sudo apt-get install -y cpanminus
    fi
}

case "$OS_FAMILY" in
    macos)  provision_macos ;;
    rhel)   provision_rhel ;;
    ubuntu) provision_ubuntu ;;
    *) warn "Unrecognized OS ($OSTYPE). Skipping package provisioning; continuing with config steps." ;;
esac

install_perl_cpan_tools

# -----------------------------------------------------------------
# 5. Global web tooling (HTML/CSS/JS ecosystem)
#    npm's default prefix is often root-owned on Linux; install to a
#    user-writable prefix instead of using sudo npm install -g.
# -----------------------------------------------------------------

setup_web_tools() {
    if ! have npm; then
        warn "npm not found. Skipping global web tool install."
        return
    fi

    local npm_prefix="$HOME/.npm-global"
    mkdir -p "$npm_prefix"
    npm config set prefix "$npm_prefix" >/dev/null 2>&1

    for tool in neovim live-server prettier; do
        if npm ls -g --depth=0 "$tool" >/dev/null 2>&1; then
            log "npm: $tool already installed globally, skipping"
        else
            log "npm: installing $tool"
            npm install -g "$tool"
        fi
    done

    ensure_line_in_file "$HOME/.profile" 'export PATH="$HOME/.npm-global/bin:$PATH"'
    log "Added $npm_prefix/bin to PATH in ~/.profile (restart shell or 'source ~/.profile')"
}

setup_web_tools

# -----------------------------------------------------------------
# 6. LazyVim config as a dotfile
#    nvim/ in this repo IS the LazyVim config (including perl.lua /
#    tmux.lua) - ~/.config/nvim gets symlinked to it. Any existing
#    real ~/.config/nvim is backed up first, never deleted, so editing
#    is always done in the repo, not at the symlink target.
# -----------------------------------------------------------------

setup_nvim_dotfiles() {
    if ! have nvim; then
        warn "nvim not found on PATH. Install it via your OS package manager above."
        return
    fi

    if [ ! -f "$SCRIPT_DIR/nvim/lua/config/lazy.lua" ]; then
        warn "No LazyVim config found in $SCRIPT_DIR/nvim - skipping. Bootstrap one from https://github.com/LazyVim/starter and commit it to this repo."
        return
    fi

    link_dotfile "$SCRIPT_DIR/nvim" "$HOME/.config/nvim"

    for plugin_file in perl.lua tmux.lua; do
        if [ -f "$HOME/.config/nvim/lua/plugins/$plugin_file" ]; then
            log "lua/plugins/$plugin_file present"
        else
            warn "lua/plugins/$plugin_file missing from the repo - perl/tmux integration will not load."
        fi
    done

    # perl.lua's perlnavigator + Mason entries install the LSP server and
    # perl-debug-adapter on first nvim launch; nothing to do here.
    log "Mason will install perlnavigator / perl-debug-adapter on first nvim launch."
}

setup_nvim_dotfiles

# -----------------------------------------------------------------
# 7. tmux + plugin stack
#    Factory-default Ctrl+b prefix kept intentionally (explicit bind
#    below), so it never shadows LazyVim's Ctrl+h/j/k/l pane/split
#    navigation from vim-tmux-navigator in lua/plugins/tmux.lua.
# -----------------------------------------------------------------

setup_tmux() {
    if ! have tmux; then
        warn "tmux not found on PATH. Skipping tmux setup."
        return
    fi

    local tpm_dir="$HOME/.tmux/plugins/tpm"
    if [ ! -d "$tpm_dir" ]; then
        log "Cloning Tmux Plugin Manager"
        git clone https://github.com/tmux-plugins/tpm "$tpm_dir"
    else
        log "TPM already installed, skipping clone"
    fi

    link_dotfile "$SCRIPT_DIR/tmux/tmux.conf" "$HOME/.tmux.conf"
}

setup_tmux

# -----------------------------------------------------------------
# 8. Project workspace launcher (dev-start)
#    No hardcoded project list in the script - projects are either
#    passed as a path, or registered once as a named alias:
#      dev-start init myproject /my/project/location
#      dev-start myproject
#    Aliases live in ~/.config/dev-start/projects, not in this script,
#    so adding/removing a project never requires re-running setup-env.sh.
#    Paths differ across the laptop/workstation/VPS, so this file is
#    machine-local by design - `dev-start export` / `import <file>`
#    move the list between machines, with paths fixed up by hand.
#    Opens an "editor" window running nvim, plus a "claude-cli" split
#    if the claude CLI is installed (matches the ai.claudecode LazyVim
#    extra in lazyvim.json).
# -----------------------------------------------------------------

setup_dev_start() {
    mkdir -p "$HOME/.local/bin"
    log "Writing ~/.local/bin/dev-start"

    cat << 'DEV_START_EOF' > "$HOME/.local/bin/dev-start"
#!/bin/bash
# Managed by setup-env.sh - re-run the script to regenerate this file.
# Usage:
#   dev-start init <name> <path>   Register an alias for a project path
#   dev-start list                 Show registered aliases
#   dev-start pick                 Fuzzy-pick a registered alias and launch it
#   dev-start remove <name>        Remove an alias
#   dev-start export [file]        Print (or save) aliases, to move to another machine
#   dev-start import <file>        Merge aliases from a file (fix paths after - see below)
#   dev-start [name-or-path] [session-name]
#       name-or-path defaults to the current directory if omitted.
#       session-name defaults to the alias name (or the directory's
#       basename, if you passed a plain path instead of an alias).
#
# DEV_START_LAYOUT=vertical|horizontal (default vertical) controls the
# nvim/claude split direction - vertical stacks nvim on top of claude
# (today's default), horizontal puts them side by side.
set -uo pipefail

CONFIG_DIR="$HOME/.config/dev-start"
CONFIG_FILE="$CONFIG_DIR/projects"
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
    # Paths differ per machine (laptop/workstation/VPS), so this file is
    # machine-local by design. Use export/import to move the list over
    # and fix paths by hand, rather than syncing this file as-is.
    cat > "$CONFIG_FILE" <<'CFG_HEADER'
# dev-start project aliases - machine-local, not meant to be synced
# across machines as-is (paths differ per host). Use `dev-start export`
# and `dev-start import <file>` to carry the list over and fix paths.
# One "name=/absolute/path" per line. Managed by `dev-start init`/`remove`.
CFG_HEADER
fi

usage() {
    cat >&2 <<USAGE
Usage:
  dev-start init <name> <path>   Register an alias for a project path
  dev-start list                 Show registered aliases
  dev-start pick                 Fuzzy-pick a registered alias and launch it
  dev-start remove <name>        Remove an alias
  dev-start export [file]        Print (or save) aliases, to move to another machine
  dev-start import <file>        Merge aliases from a file (fix paths after)
  dev-start [name-or-path] [session-name]
USAGE
    exit 1
}

# Config format: one "name=/absolute/path" line per alias, plus '#' comments.
alias_lookup() {
    awk -F= -v n="$1" '$1==n {v=substr($0, length($1)+2)} END{if (v) print v}' "$CONFIG_FILE"
}

alias_drop() {
    awk -F= -v n="$1" '$1!=n' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

# Real alias lines only - skips comments and blanks (both have no '=', so NF==1).
valid_lines() {
    awk -F= '!/^#/ && NF>1' "$CONFIG_FILE"
}

cmd_init() {
    local name="${1:-}" path="${2:-}"
    [ -n "$name" ] && [ -n "$path" ] || { echo "dev-start init: need a name and a path" >&2; usage; }
    case "$name" in *=*) echo "dev-start init: name can't contain '='" >&2; exit 1 ;; esac
    [ -d "$path" ] || { echo "dev-start init: '$path' is not a directory" >&2; exit 1; }
    path="$(cd "$path" && pwd)"

    alias_drop "$name"   # idempotent: re-running init on the same name overwrites it
    echo "${name}=${path}" >> "$CONFIG_FILE"
    echo "Registered '$name' -> $path"
}

cmd_list() {
    local lines
    lines="$(valid_lines)"
    if [ -z "$lines" ]; then
        echo "No projects registered yet. Use: dev-start init <name> <path>"
        return
    fi
    echo "$lines" | column -t -s= 2>/dev/null || echo "$lines"
}

cmd_pick() {
    local lines choice
    lines="$(valid_lines)"
    if [ -z "$lines" ]; then
        echo "No projects registered yet. Use: dev-start init <name> <path>" >&2
        exit 1
    fi
    if command -v fzf >/dev/null 2>&1; then
        choice="$(echo "$lines" | awk -F= '{print $1}' | fzf --prompt='dev-start> ')"
    else
        echo "Registered projects:" >&2
        echo "$lines" | awk -F= '{print NR") "$1}' >&2
        read -rp "Pick a number: " num
        choice="$(echo "$lines" | awk -F= -v n="$num" 'NR==n{print $1}')"
    fi
    [ -n "$choice" ] || { echo "No selection made." >&2; exit 1; }
    exec "$0" "$choice"
}

cmd_remove() {
    local name="${1:-}"
    [ -n "$name" ] || { echo "dev-start remove: need a name" >&2; usage; }
    alias_drop "$name"
    echo "Removed '$name' (if it existed)"
}

cmd_export() {
    local out="${1:-}" lines
    lines="$(valid_lines)"
    if [ -z "$lines" ]; then
        echo "No projects registered yet." >&2
        exit 1
    fi
    if [ -n "$out" ]; then
        echo "$lines" > "$out"
        echo "Exported $(echo "$lines" | wc -l | tr -d ' ') project(s) to $out"
    else
        echo "$lines"
    fi
}

cmd_import() {
    local file="${1:-}" name path count=0 missing=0
    [ -n "$file" ] && [ -f "$file" ] || { echo "dev-start import: need an existing file to import" >&2; usage; }
    while IFS='=' read -r name path; do
        case "$name" in ""|\#*) continue ;; esac
        [ -z "$path" ] && continue
        alias_drop "$name"
        echo "${name}=${path}" >> "$CONFIG_FILE"
        count=$((count + 1))
        if [ ! -d "$path" ]; then
            echo "  '$name' -> '$path' doesn't exist on this machine (fix with: dev-start init $name <path>)" >&2
            missing=$((missing + 1))
        fi
    done < "$file"
    if [ "$missing" -gt 0 ]; then
        echo "Imported $count project(s), $missing need a path fix on this machine."
    else
        echo "Imported $count project(s)."
    fi
}

case "${1:-}" in
    init)   shift; cmd_init "$@"; exit 0 ;;
    list)   cmd_list; exit 0 ;;
    pick)   cmd_pick; exit 0 ;;
    remove) shift; cmd_remove "$@"; exit 0 ;;
    export) shift; cmd_export "$@"; exit 0 ;;
    import) shift; cmd_import "$@"; exit 0 ;;
esac

# --- resolve the project directory + default session name ---
ARG="${1:-}"
SESSION_OVERRIDE="${2:-}"

if [ -z "$ARG" ]; then
    PROJECT_DIR="$PWD"
    DEFAULT_SESSION_NAME="$(basename "$PROJECT_DIR")"
elif ALIAS_PATH="$(alias_lookup "$ARG")" && [ -n "$ALIAS_PATH" ]; then
    PROJECT_DIR="$ALIAS_PATH"
    DEFAULT_SESSION_NAME="$ARG"
elif [ -d "$ARG" ]; then
    PROJECT_DIR="$ARG"
    DEFAULT_SESSION_NAME="$(basename "$PROJECT_DIR")"
else
    echo "dev-start: '$ARG' is not a registered alias or a directory" >&2
    echo "Run 'dev-start list' to see aliases, or 'dev-start init $ARG <path>' to add one." >&2
    exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
    echo "dev-start: '$PROJECT_DIR' is not a directory" >&2
    exit 1
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

SESSION_NAME="${SESSION_OVERRIDE:-$DEFAULT_SESSION_NAME}"
# tmux session names can't contain '.' or ':'
SESSION_NAME="${SESSION_NAME//[.:]/_}"

# tmux-persist auto-restores on its `session-created` hook, async, the
# instant a session with a matching snapshot name is created - and
# since a brand-new session always starts with exactly 1 pane, persist
# will overwrite that pane if a snapshot exists. Building our own
# layout at the same time would race it. So: if a persist snapshot
# exists for this session name, just create the bare session and let
# persist's hook populate it; only build our own default layout when
# there's nothing for persist to restore.
PERSIST_DIR="$(tmux show-option -gqv @persist-dir 2>/dev/null)"
PERSIST_DIR="${PERSIST_DIR:-$HOME/.tmux/persist}"
PERSIST_DIR="${PERSIST_DIR/#\~/$HOME}"

has_persist_snapshot() {
    [ -d "$PERSIST_DIR" ] || return 1
    compgen -G "$PERSIST_DIR/${SESSION_NAME}_*" > /dev/null 2>&1
}

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Session '$SESSION_NAME' already running."
elif has_persist_snapshot; then
    echo "Found a tmux-persist snapshot for '$SESSION_NAME' - letting tmux-persist restore it."
    tmux new-session -d -s "$SESSION_NAME" -c "$PROJECT_DIR"
    # tmux-persist's session-created hook takes it from here.
else
    tmux new-session -d -s "$SESSION_NAME" -c "$PROJECT_DIR" -n "editor"
    tmux send-keys -t "$SESSION_NAME:1" "nvim" C-m

    # One window, three panes: nvim, claude, and a small idle shell
    # carved off the bottom of the claude pane for git/cmd-line ops.
    # Vertical (default) stacks nvim on top of claude. Horizontal puts
    # nvim on the left (full height) and claude on the right - in both
    # cases the shell sliver sits at the bottom of the claude pane.
    if command -v claude >/dev/null 2>&1; then
        case "${DEV_START_LAYOUT:-vertical}" in
            horizontal) tmux split-window -h -t "$SESSION_NAME:1" -c "$PROJECT_DIR" -p 50 ;;
            *)          tmux split-window -v -t "$SESSION_NAME:1" -c "$PROJECT_DIR" -p 40 ;;
        esac
        tmux send-keys -t "$SESSION_NAME:1.2" "claude" C-m

        # Shell sliver at the bottom of the claude pane (pane 2).
        tmux split-window -v -t "$SESSION_NAME:1.2" -c "$PROJECT_DIR" -p 10
    fi
fi

if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$SESSION_NAME"
else
    tmux attach-session -t "$SESSION_NAME"
fi
DEV_START_EOF
    chmod +x "$HOME/.local/bin/dev-start"
    ensure_line_in_file "$HOME/.profile" 'export PATH="$HOME/.local/bin:$PATH"'
}

setup_dev_start

# -----------------------------------------------------------------
# 8b. Shell completion for dev-start (subcommands + registered aliases)
#     Added to both ~/.bashrc and ~/.zshrc, guarded by a marker so
#     re-running this script never stacks duplicate blocks.
# -----------------------------------------------------------------

setup_dev_start_completion() {
    local marker="# >>> dev-start completion >>>"

    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        touch "$rc"
        if grep -qF "$marker" "$rc"; then
            log "dev-start completion already present in $(basename "$rc"), skipping"
            continue
        fi

        log "Adding dev-start completion to $(basename "$rc")"
        {
            echo ""
            if [ "$rc" = "$HOME/.zshrc" ]; then
                echo "autoload -U +X bashcompinit && bashcompinit 2>/dev/null"
            fi
            cat <<'COMPLETION'
# >>> dev-start completion >>>
_dev_start_complete() {
    local cur names
    cur="${COMP_WORDS[COMP_CWORD]}"
    names="$(awk -F= '!/^#/ && NF>1 {print $1}' "$HOME/.config/dev-start/projects" 2>/dev/null)"
    COMPREPLY=( $(compgen -W "init list pick remove export import ${names}" -- "$cur") )
}
complete -F _dev_start_complete dev-start
# <<< dev-start completion <<<
COMPLETION
        } >> "$rc"
    done
}

setup_dev_start_completion

# -----------------------------------------------------------------
# 9. Install tmux plugins non-interactively
# -----------------------------------------------------------------

install_tmux_plugins() {
    if ! have tmux; then
        return
    fi
    local tpm_dir="$HOME/.tmux/plugins/tpm"
    if [ ! -x "$tpm_dir/bindings/install_plugins" ]; then
        warn "TPM install script not found at $tpm_dir; skipping plugin install."
        return
    fi
    log "Bootstrapping tmux plugins"
    tmux start-server
    if ! tmux has-session -t _setup_env_dummy 2>/dev/null; then
        tmux new-session -d -s _setup_env_dummy
    fi
    bash "$tpm_dir/bindings/install_plugins"
    tmux kill-session -t _setup_env_dummy 2>/dev/null || true
}

install_tmux_plugins

# -----------------------------------------------------------------
# 10. Windows (future work - not implemented yet)
#     Placeholder only. A Windows pass should live in its own
#     setup-env.ps1 using winget/scoop + WSL for the Perl/tmux pieces
#     (tmux has no native Windows build), rather than branching this
#     bash script on $OS.
# -----------------------------------------------------------------
# TODO: setup-env.ps1
#   - winget/scoop installs for neovim, git, go, python, node
#   - WSL2 + Ubuntu distro for tmux, perl toolchain, dev-start
#   - Reuse this script's OS_FAMILY=ubuntu path *inside* WSL

echo "Environment setup complete for OS family: $OS_FAMILY"
echo "Perl binary in use: ${ACTIVE_PERL_BIN:-$(command -v perl 2>/dev/null || echo 'still not found')}"
echo "Run 'dev-start' to launch your tmux project sessions."
