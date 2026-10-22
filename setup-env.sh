#!/bin/bash
# =====================================================================
# setup-env.sh - Unified Development Stack Setup Script
# Targets: macOS, Red Hat, Ubuntu
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
# dev-stack takes a project path as an argument (dev-stack [path]) -
# there is no hardcoded project list to maintain.
# =====================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

ensure_line_in_file() {
    local file="$1"
    local line="$2"
    touch "$file"
    grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

# ensure_path_line <line>
# ~/.profile covers login shells; ~/.bashrc covers the non-login
# interactive shells most terminals and tmux panes start. Write to both
# so the line takes effect without a fresh login.
ensure_path_line() {
    ensure_line_in_file "$HOME/.profile" "$1"
    ensure_line_in_file "$HOME/.bashrc" "$1"
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
# 0. Options
#    --no-sudo        Don't install system packages; list the missing
#                     ones for an admin instead (also DEV_STACK_NO_SUDO=1).
#    --print-prereqs  Only report which system packages are missing,
#                     then exit without changing anything.
# -----------------------------------------------------------------

usage() {
    echo "Usage: setup-env.sh [--no-sudo] [--print-prereqs]"
}

NO_SUDO="${DEV_STACK_NO_SUDO:-0}"
PRINT_PREREQS=0
for arg in "$@"; do
    case "$arg" in
        --no-sudo)       NO_SUDO=1 ;;
        --print-prereqs) PRINT_PREREQS=1 ;;
        -h|--help)       usage; exit 0 ;;
        *)               warn "Unknown option: $arg"; usage >&2; exit 1 ;;
    esac
done

echo "Starting environment setup..."
echo "Using dotfiles from: $SCRIPT_DIR"

# -----------------------------------------------------------------
# 1. Perl & Python discovery (same principle, applied to both)
#    Never force a reinstall if a working binary is already
#    discoverable. perl.lua's perlnavigator config uses perlPath =
#    "perl", so whatever resolves on PATH is what LSP/prove/perltidy
#    will use too. Same idea for Python: plenty of setups manage it
#    via pyenv/perlbrew-style version managers instead of the OS
#    package manager, and installing over that via brew/dnf/apt can
#    silently change what `python3` resolves to system-wide (brew's
#    `link` step will even overwrite existing python3/pip3 symlinks).
# -----------------------------------------------------------------

ACTIVE_PERL_BIN="$(command -v perl 2>/dev/null || true)"
if [ -n "$ACTIVE_PERL_BIN" ]; then
    PERL_VERSION_STRING="$("$ACTIVE_PERL_BIN" -e 'print $^V' 2>/dev/null || echo "unknown")"
    log "Perl already available: $ACTIVE_PERL_BIN ($PERL_VERSION_STRING)"
else
    warn "No perl binary discoverable on PATH yet. It will be installed below."
fi

ACTIVE_PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
if [ -n "$ACTIVE_PYTHON_BIN" ]; then
    PYTHON_VERSION_STRING="$("$ACTIVE_PYTHON_BIN" --version 2>&1)"
    log "Python already available: $ACTIVE_PYTHON_BIN ($PYTHON_VERSION_STRING)"
else
    warn "No python3 binary discoverable on PATH yet. It will be installed below."
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
# 2b. Package install rights
#     All system package installs go through pkg_install. When this
#     run can't install them itself (no root or sudo, Homebrew owned by
#     another user, --no-sudo, --print-prereqs), the packages are
#     collected instead and handed off at the end - printed, and
#     written to ~/dev-stack-prereqs.sh for an admin to run - while
#     every step that doesn't need root still runs. Re-running after
#     the admin has installed them finishes the setup.
# -----------------------------------------------------------------

SUDO=""
CAN_INSTALL=1
MISSING_PKGS=()
HANDOFF_NOTES=()
PREREQS_FILE="$HOME/dev-stack-prereqs.sh"

resolve_install_rights() {
    if [ "$PRINT_PREREQS" = 1 ]; then
        CAN_INSTALL=0
    elif [ "$NO_SUDO" = 1 ]; then
        log "--no-sudo set; missing packages will be listed for an admin instead of installed"
        CAN_INSTALL=0
    elif [ "$OS_FAMILY" = "macos" ]; then
        # brew never uses sudo, but needs write access to its own prefix.
        if have brew && [ ! -w "$(brew --prefix)" ]; then
            warn "Homebrew at $(brew --prefix) isn't writable by $(id -un); missing packages will be listed for its owner instead."
            CAN_INSTALL=0
        fi
    elif [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    elif ! have sudo; then
        warn "sudo not found; missing packages will be listed for an admin instead of installed."
        CAN_INSTALL=0
    elif sudo -n true 2>/dev/null; then
        SUDO="sudo"
    elif (: </dev/tty) 2>/dev/null \
        && log "Package installs need sudo (re-run with --no-sudo to skip this prompt)" \
        && sudo -v; then
        # sudo prompts on /dev/tty, so this also works under curl | bash.
        SUDO="sudo"
    else
        warn "Couldn't get sudo; missing packages will be listed for an admin instead of installed."
        CAN_INSTALL=0
    fi
}

# pkg_install <pkg>... - install with the OS package manager, or record
# the packages for the admin hand-off when this run can't install them.
pkg_install() {
    local tool
    case "$OS_FAMILY" in
        macos)  tool="brew" ;;
        rhel)   tool="dnf" ;;
        ubuntu) tool="apt" ;;
    esac

    if [ "$CAN_INSTALL" = 0 ]; then
        log "$tool: $* missing, adding to the prerequisites list"
        MISSING_PKGS+=("$@")
        return
    fi

    log "$tool: installing $*"
    case "$OS_FAMILY" in
        macos)  brew install "$@" ;;
        rhel)   $SUDO dnf install -y "$@" ;;
        ubuntu) $SUDO apt-get install -y "$@" ;;
    esac
}

# Print the collected packages as the commands to install them, and
# (unless --print-prereqs) write the same commands to $PREREQS_FILE.
report_missing_prereqs() {
    if [ ${#MISSING_PKGS[@]} -eq 0 ] && [ ${#HANDOFF_NOTES[@]} -eq 0 ]; then
        if [ "$PRINT_PREREQS" = 1 ]; then
            log "No missing prerequisites."
        else
            # Drop a hand-off file left by an earlier run; it's done.
            rm -f "$PREREQS_FILE"
        fi
        return
    fi

    local user runner pkgs note
    user="$(id -un)"
    pkgs="${MISSING_PKGS[*]:-}"
    if [ "$OS_FAMILY" = "macos" ]; then
        runner="the user that owns Homebrew"
    elif [ "$PRINT_PREREQS" = 1 ]; then
        runner="root"
    else
        runner="root (e.g. sudo bash $PREREQS_FILE)"
    fi

    if [ "$OS_FAMILY" = "rhel" ] && echo " $pkgs " | grep -qE ' (neovim|fd-find|ripgrep) '; then
        HANDOFF_NOTES+=("neovim, fd-find and ripgrep aren't in the base RHEL repos. Enable EPEL first (https://docs.fedoraproject.org/en-US/epel/).")
    fi

    local script=()
    script+=("#!/bin/bash")
    script+=("# dev-stack prerequisites for $user on $(hostname) ($OS_FAMILY), written by setup-env.sh.")
    script+=("# Run as $runner, then have $user re-run ./setup-env.sh.")
    if [ ${#HANDOFF_NOTES[@]} -gt 0 ]; then
        for note in "${HANDOFF_NOTES[@]}"; do
            script+=("# NOTE: $note")
        done
    fi
    if [ -n "$pkgs" ]; then
        # One package at a time, so a package the repos don't carry
        # doesn't stop the rest from installing.
        local install_cmd
        case "$OS_FAMILY" in
            macos)  install_cmd="brew install" ;;
            rhel)   install_cmd="dnf install -y" ;;
            ubuntu) install_cmd="apt-get install -y"; script+=("apt-get update -y") ;;
        esac
        script+=("failed=\"\"")
        script+=("for pkg in $pkgs; do")
        script+=("    $install_cmd \"\$pkg\" || failed=\"\$failed \$pkg\"")
        script+=("done")
        script+=("if [ -n \"\$failed\" ]; then")
        script+=("    echo \"Couldn't install:\$failed - see the NOTE lines at the top of this script.\" >&2")
        script+=("    exit 1")
        script+=("fi")
    fi

    echo
    echo "-----------------------------------------------------------------"
    echo "Missing prerequisites - these need to be installed by $runner:"
    echo
    printf '%s\n' "${script[@]}"
    echo "-----------------------------------------------------------------"

    if [ "$PRINT_PREREQS" = 0 ]; then
        printf '%s\n' "${script[@]}" > "$PREREQS_FILE"
        chmod +x "$PREREQS_FILE"
        warn "Wrote $PREREQS_FILE - hand it to $runner, then re-run ./setup-env.sh to finish."
    fi
}

resolve_install_rights

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

    # A system perl's site library needs root to write to, so install
    # into ~/perl5 instead when it isn't writable (perlbrew and brew
    # perls are user-owned and keep installing to their own library).
    local cpanm_args=(--notest)
    local sitelib
    sitelib="$(perl -MConfig -e 'print $Config{installsitelib}' 2>/dev/null)"
    if [ -n "$sitelib" ] && [ ! -w "$sitelib" ]; then
        log "Perl site library $sitelib isn't writable; using ~/perl5 for Perl tools"
        cpanm_args+=(--local-lib "$HOME/perl5")
        export PATH="$HOME/perl5/bin:$PATH"
        export PERL5LIB="$HOME/perl5/lib/perl5${PERL5LIB:+:$PERL5LIB}"
        ensure_path_line 'export PATH="$HOME/perl5/bin:$PATH"'
        ensure_path_line 'export PERL5LIB="$HOME/perl5/lib/perl5${PERL5LIB:+:$PERL5LIB}"'
    fi

    if have perltidy; then
        log "perltidy already installed, skipping"
    else
        log "Installing Perl::Tidy via cpanm"
        cpanm "${cpanm_args[@]}" Perl::Tidy
    fi

    if have perlcritic; then
        log "perlcritic already installed, skipping"
    else
        log "Installing Perl::Critic via cpanm"
        cpanm "${cpanm_args[@]}" Perl::Critic
    fi
}

# -----------------------------------------------------------------
# 4. OS-specific provisioning
# -----------------------------------------------------------------

provision_macos() {
    log "Syncing macOS toolchain..."

    if ! have brew; then
        warn "Homebrew is required on macOS. Install it from https://brew.sh, then re-run this script."
        HANDOFF_NOTES+=("Install Homebrew from https://brew.sh, then re-run ./setup-env.sh to list the remaining packages.")
        return
    fi

    local pkgs=(tmux neovim git lazygit fzf fd ripgrep go node)
    for pkg in "${pkgs[@]}"; do
        if brew list --versions "$pkg" >/dev/null 2>&1; then
            log "brew: $pkg already installed, skipping"
        else
            pkg_install "$pkg"
        fi
    done

    if [ -z "$ACTIVE_PERL_BIN" ]; then
        log "No base Perl found. Need perl + cpanminus"
        pkg_install perl cpanminus
    elif ! have cpanm; then
        log "Perl present but cpanm missing. Need cpanminus"
        pkg_install cpanminus
    else
        log "Perl ($ACTIVE_PERL_BIN) and cpanm already present, skipping brew perl/cpanminus"
    fi

    if [ -z "$ACTIVE_PYTHON_BIN" ]; then
        log "No base Python3 found. Need python3"
        pkg_install python3
    else
        log "Python3 ($ACTIVE_PYTHON_BIN) already present, skipping brew python3"
    fi
}

provision_rhel() {
    log "Syncing Red Hat Enterprise workspace..."

    if ! have dnf; then
        warn "dnf not found. Cannot provision packages."
        return
    fi

    if [ "$CAN_INSTALL" = 1 ]; then
        $SUDO dnf check-update || true
    fi

    # lazygit isn't in the RHEL/EPEL repos; install_lazygit handles it.
    local pkgs=(tmux neovim fzf fd-find ripgrep gcc make golang nodejs)
    for pkg in "${pkgs[@]}"; do
        if rpm -q "$pkg" >/dev/null 2>&1; then
            log "dnf: $pkg already installed, skipping"
        else
            pkg_install "$pkg"
        fi
    done

    if [ -z "$ACTIVE_PERL_BIN" ]; then
        log "No base Perl found. Need perl-interpreter + cpanminus"
        pkg_install perl-interpreter perl-App-cpanminus
    elif ! have cpanm; then
        log "Perl present but cpanm missing. Need perl-App-cpanminus"
        pkg_install perl-App-cpanminus
    fi

    if [ -z "$ACTIVE_PYTHON_BIN" ]; then
        log "No base Python3 found. Need python3 + pip"
        pkg_install python3 python3-pip
    elif ! have pip3; then
        log "Python3 present but pip3 missing. Need python3-pip"
        pkg_install python3-pip
    else
        log "Python3 ($ACTIVE_PYTHON_BIN) and pip3 already present, skipping dnf python3/pip"
    fi
}

provision_ubuntu() {
    log "Syncing Debian/Ubuntu cloud layer..."

    if ! have apt-get; then
        warn "apt-get not found. Cannot provision packages."
        return
    fi

    if [ "$CAN_INSTALL" = 1 ]; then
        $SUDO apt-get update -y
    fi

    # lazygit isn't packaged for every Ubuntu release; install_lazygit handles it.
    local pkgs=(tmux neovim fzf fd-find ripgrep build-essential golang-go nodejs npm)
    for pkg in "${pkgs[@]}"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            log "apt: $pkg already installed, skipping"
        else
            pkg_install "$pkg"
        fi
    done

    if [ -z "$ACTIVE_PERL_BIN" ]; then
        log "No base Perl found. Need perl + cpanminus"
        pkg_install perl cpanminus
    elif ! have cpanm; then
        log "Perl present but cpanm missing. Need cpanminus"
        pkg_install cpanminus
    fi

    if [ -z "$ACTIVE_PYTHON_BIN" ]; then
        log "No base Python3 found. Need python3 + pip"
        pkg_install python3 python3-pip
    elif ! have pip3; then
        log "Python3 present but pip3 missing. Need python3-pip"
        pkg_install python3-pip
    else
        log "Python3 ($ACTIVE_PYTHON_BIN) and pip3 already present, skipping apt python3/pip"
    fi
}

case "$OS_FAMILY" in
    macos)  provision_macos ;;
    rhel)   provision_rhel ;;
    ubuntu) provision_ubuntu ;;
    *) warn "Unrecognized OS ($OSTYPE). Skipping package provisioning; continuing with config steps." ;;
esac

if [ "$PRINT_PREREQS" = 1 ]; then
    report_missing_prereqs
    exit 0
fi

install_perl_cpan_tools

# -----------------------------------------------------------------
# 4b. lazygit on RHEL / Ubuntu (macOS gets it from brew above)
#     Not in the RHEL/EPEL repos or every Ubuntu release, and it needs
#     no root: build it with `go install` when Go is on PATH, otherwise
#     (or if that fails) use the checksum-verified release binary.
#     Either way it lands in ~/.local/bin.
# -----------------------------------------------------------------

LAZYGIT_REPO="github.com/jesseduffield/lazygit"

# fetch <url> <dest>
fetch() {
    if have curl; then
        curl -fsSL -o "$2" "$1"
    elif have wget; then
        wget -qO "$2" "$1"
    else
        return 1
    fi
}

install_lazygit_release() {
    local arch version asset tmp status=1
    case "$(uname -m)" in
        x86_64)        arch="x86_64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv6l|armv7l) arch="armv6" ;;
        *) warn "No lazygit release binary for $(uname -m)"; return 1 ;;
    esac

    if ! have curl && ! have wget; then
        warn "Need curl or wget to download the lazygit release binary"
        pkg_install curl
        return 1
    fi

    # Newest release tag via git (already required), not the
    # rate-limited GitHub API.
    version="$(git ls-remote --tags --refs "https://$LAZYGIT_REPO" 'v*' 2>/dev/null \
        | sed 's|.*refs/tags/v||' | sort -V | tail -1)"
    if [ -z "$version" ]; then
        warn "Couldn't determine the latest lazygit release"
        return 1
    fi

    asset="lazygit_${version}_linux_${arch}.tar.gz"
    tmp="$(mktemp -d)"
    log "Downloading lazygit $version release binary ($arch)"
    if fetch "https://$LAZYGIT_REPO/releases/download/v$version/$asset" "$tmp/$asset" \
        && fetch "https://$LAZYGIT_REPO/releases/download/v$version/checksums.txt" "$tmp/checksums.txt" \
        && (cd "$tmp" && grep " $asset\$" checksums.txt | sha256sum -c --status -) \
        && tar -xzf "$tmp/$asset" -C "$tmp" lazygit \
        && install -m 755 "$tmp/lazygit" "$HOME/.local/bin/lazygit"; then
        status=0
    fi
    rm -rf "$tmp"
    return $status
}

install_lazygit() {
    if [ "$OS_FAMILY" != "rhel" ] && [ "$OS_FAMILY" != "ubuntu" ]; then
        return
    fi
    if have lazygit || [ -x "$HOME/.local/bin/lazygit" ]; then
        log "lazygit already installed, skipping"
        return
    fi

    mkdir -p "$HOME/.local/bin"
    ensure_path_line 'export PATH="$HOME/.local/bin:$PATH"'

    if have go; then
        log "Building lazygit with go install"
        # Distro Go packages can pin GOTOOLCHAIN=local; let Go fetch the
        # newer toolchain lazygit may require.
        if GOTOOLCHAIN=auto GOBIN="$HOME/.local/bin" go install "$LAZYGIT_REPO@latest"; then
            return
        fi
        warn "go install failed; falling back to the lazygit release binary"
    else
        log "go not found; using the lazygit release binary"
    fi

    if ! install_lazygit_release; then
        warn "Couldn't install lazygit; get it from https://$LAZYGIT_REPO/releases and put it on PATH."
    fi
}

install_lazygit

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

    # nvm-managed npm already installs globals into a user-writable
    # prefix, and nvm refuses to run when .npmrc sets "prefix". Leave the
    # prefix alone there, and undo the one an earlier run of this script set.
    if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
        log "nvm detected; using its npm prefix instead of $npm_prefix"
        # A non-interactive shell hasn't loaded nvm, so npm may be the system one.
        set +u
        # shellcheck disable=SC1091
        . "${NVM_DIR:-$HOME/.nvm}/nvm.sh" >/dev/null 2>&1
        set -u
        if [ "$(npm config get prefix 2>/dev/null)" = "$npm_prefix" ]; then
            npm config delete prefix >/dev/null 2>&1
        fi
    else
        mkdir -p "$npm_prefix"
        npm config set prefix "$npm_prefix" >/dev/null 2>&1
        ensure_path_line 'export PATH="$HOME/.npm-global/bin:$PATH"'
        export PATH="$npm_prefix/bin:$PATH"
    fi

    for tool in neovim live-server prettier; do
        if npm ls -g --depth=0 "$tool" >/dev/null 2>&1; then
            log "npm: $tool already installed globally, skipping"
        else
            log "npm: installing $tool"
            npm install -g "$tool"
        fi
    done
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
# 8. Project workspace launcher (dev-stack, aliased as dev-start)
#    No hardcoded project list in the script - projects are either
#    passed as a path, or registered once as a named alias:
#      dev-stack init myproject /my/project/location
#      dev-stack myproject
#    Aliases live in ~/.config/dev-start/projects, not in this script,
#    so adding/removing a project never requires re-running setup-env.sh.
#    Paths differ from machine to machine, so this file is
#    machine-local by design - `dev-stack export` / `import <file>`
#    move the list between machines, with paths fixed up by hand.
#    Opens an "editor" window running nvim, plus a "claude-cli" split
#    if the claude CLI is installed (matches the ai.claudecode LazyVim
#    extra in lazyvim.json).
# -----------------------------------------------------------------

setup_dev_start() {
    mkdir -p "$HOME/.local/bin"
    log "Writing ~/.local/bin/dev-stack"

    # Older installs had dev-stack as a symlink to dev-start; remove it so
    # the write below creates a real file instead of following the link.
    rm -f "$HOME/.local/bin/dev-stack"
    cat << 'DEV_START_EOF' > "$HOME/.local/bin/dev-stack"
#!/bin/bash
# Managed by setup-env.sh - re-run the script to regenerate this file.
# Usage:
#   dev-stack init <name> <path>   Register an alias for a project path
#   dev-stack list                 Show registered aliases
#   dev-stack status                Show which aliases are running / restorable
#   dev-stack pick                 Fuzzy-pick a registered alias and launch it
#   dev-stack remove <name>        Remove an alias
#   dev-stack export [file]        Print (or save) aliases, to move to another machine
#   dev-stack import <file>        Merge aliases from a file (fix paths after - see below)
#   dev-stack [name-or-path] [session-name]
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
    # Paths differ per machine, so this file is
    # machine-local by design. Use export/import to move the list over
    # and fix paths by hand, rather than syncing this file as-is.
    cat > "$CONFIG_FILE" <<'CFG_HEADER'
# dev-stack project aliases - machine-local, not meant to be synced
# across machines as-is (paths differ per host). Use `dev-stack export`
# and `dev-stack import <file>` to carry the list over and fix paths.
# One "name=/absolute/path" per line. Managed by `dev-stack init`/`remove`.
CFG_HEADER
fi

usage() {
    cat >&2 <<USAGE
Usage:
  dev-stack init <name> <path>   Register an alias for a project path
  dev-stack list                 Show registered aliases
  dev-stack status                Show which aliases are running / restorable
  dev-stack pick                 Fuzzy-pick a registered alias and launch it
  dev-stack remove <name>        Remove an alias
  dev-stack export [file]        Print (or save) aliases, to move to another machine
  dev-stack import <file>        Merge aliases from a file (fix paths after)
  dev-stack [name-or-path] [session-name]
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

# tmux session names can't contain '.' or ':' - same sanitization used
# both when launching and when checking status, so the two agree on
# what a given alias's session is actually named.
sanitize_session_name() {
    local n="$1"
    echo "${n//[.:]/_}"
}

# tmux-persist auto-restores on its `session-created` hook, async, the
# instant a session with a matching snapshot name is created - and
# since a brand-new session always starts with exactly 1 pane, persist
# will overwrite that pane if a snapshot exists. Building our own
# layout at the same time would race it, so the main launch path below
# checks this before deciding what to do. `status` also uses it, to
# show which non-running aliases could still be restored.
PERSIST_DIR="$(tmux show-option -gqv @persist-dir 2>/dev/null)"
PERSIST_DIR="${PERSIST_DIR:-$HOME/.tmux/persist}"
PERSIST_DIR="${PERSIST_DIR/#\~/$HOME}"

has_persist_snapshot() {
    local session="$1"
    [ -d "$PERSIST_DIR" ] || return 1
    compgen -G "$PERSIST_DIR/${session}_*" > /dev/null 2>&1
}

cmd_init() {
    local name="${1:-}" path="${2:-}"
    [ -n "$name" ] && [ -n "$path" ] || { echo "dev-stack init: need a name and a path" >&2; usage; }
    case "$name" in *=*) echo "dev-stack init: name can't contain '='" >&2; exit 1 ;; esac
    [ -d "$path" ] || { echo "dev-stack init: '$path' is not a directory" >&2; exit 1; }
    path="$(cd "$path" && pwd)"

    alias_drop "$name"   # idempotent: re-running init on the same name overwrites it
    echo "${name}=${path}" >> "$CONFIG_FILE"
    echo "Registered '$name' -> $path"
}

cmd_list() {
    local lines
    lines="$(valid_lines)"
    if [ -z "$lines" ]; then
        echo "No projects registered yet. Use: dev-stack init <name> <path>"
        return
    fi
    echo "$lines" | column -t -s= 2>/dev/null || echo "$lines"
}

cmd_pick() {
    local lines choice
    lines="$(valid_lines)"
    if [ -z "$lines" ]; then
        echo "No projects registered yet. Use: dev-stack init <name> <path>" >&2
        exit 1
    fi
    if command -v fzf >/dev/null 2>&1; then
        choice="$(echo "$lines" | awk -F= '{print $1}' | fzf --prompt='dev-stack> ')"
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
    [ -n "$name" ] || { echo "dev-stack remove: need a name" >&2; usage; }
    alias_drop "$name"
    echo "Removed '$name' (if it existed)"
}

cmd_status() {
    local lines
    lines="$(valid_lines)"
    if [ -z "$lines" ]; then
        echo "No projects registered yet. Use: dev-stack init <name> <path>"
        return
    fi

    printf '%-20s %-9s %-10s %s\n' "NAME" "RUNNING" "SNAPSHOT" "PATH"
    while IFS='=' read -r name path; do
        local sess running snap
        sess="$(sanitize_session_name "$name")"
        if tmux has-session -t "$sess" 2>/dev/null; then running="yes"; else running="no"; fi
        if has_persist_snapshot "$sess"; then snap="yes"; else snap="no"; fi
        printf '%-20s %-9s %-10s %s\n' "$name" "$running" "$snap" "$path"
    done <<< "$lines"
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
    [ -n "$file" ] && [ -f "$file" ] || { echo "dev-stack import: need an existing file to import" >&2; usage; }
    while IFS='=' read -r name path; do
        case "$name" in ""|\#*) continue ;; esac
        [ -z "$path" ] && continue
        alias_drop "$name"
        echo "${name}=${path}" >> "$CONFIG_FILE"
        count=$((count + 1))
        if [ ! -d "$path" ]; then
            echo "  '$name' -> '$path' doesn't exist on this machine (fix with: dev-stack init $name <path>)" >&2
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
    status) cmd_status; exit 0 ;;
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
    echo "dev-stack: '$ARG' is not a registered alias or a directory" >&2
    echo "Run 'dev-stack list' to see aliases, or 'dev-stack init $ARG <path>' to add one." >&2
    exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
    echo "dev-stack: '$PROJECT_DIR' is not a directory" >&2
    exit 1
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

SESSION_NAME="$(sanitize_session_name "${SESSION_OVERRIDE:-$DEFAULT_SESSION_NAME}")"

# tmux-persist auto-restores on its `session-created` hook, async, the
# instant a session with a matching snapshot name is created - and
# since a brand-new session always starts with exactly 1 pane, persist
# will overwrite that pane if a snapshot exists. Building our own
# layout at the same time would race it. So: if a persist snapshot
# exists for this session name, just create the bare session and let
# persist's hook populate it; only build our own default layout when
# there's nothing for persist to restore. (has_persist_snapshot and
# PERSIST_DIR are defined above, shared with `dev-stack status`.)

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Session '$SESSION_NAME' already running."
elif has_persist_snapshot "$SESSION_NAME"; then
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
    chmod +x "$HOME/.local/bin/dev-stack"
    # dev-start is kept as an alias for the original name; a symlink (rather
    # than a shell alias) so it also works from scripts and non-interactive
    # shells. -f replaces the real dev-start file older installs wrote.
    ln -sfn dev-stack "$HOME/.local/bin/dev-start"
    ensure_path_line 'export PATH="$HOME/.local/bin:$PATH"'
}

setup_dev_start

# -----------------------------------------------------------------
# 8b. Shell completion for dev-stack (subcommands + registered aliases)
#     dev-start is a compatibility symlink only and gets no completion.
#     Added to both ~/.bashrc and ~/.zshrc, guarded by a marker so
#     re-running this script never stacks duplicate blocks.
# -----------------------------------------------------------------

setup_dev_start_completion() {
    local marker_start="# >>> dev-start completion >>>"
    local marker_end="# <<< dev-start completion <<<"

    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        touch "$rc"

        if grep -qF "$marker_start" "$rc"; then
            # Strip the old managed block first, so re-running always
            # picks up new subcommands instead of freezing whatever
            # completion list was installed the first time.
            sed -i.bak "/$marker_start/,/$marker_end/d" "$rc"
            rm -f "$rc.bak"
        fi

        log "Updating dev-stack completion in $(basename "$rc")"
        {
            echo ""
            if [ "$rc" = "$HOME/.zshrc" ]; then
                echo "autoload -U +X bashcompinit && bashcompinit 2>/dev/null"
            fi
            cat <<'COMPLETION'
# >>> dev-start completion >>>
_dev_stack_complete() {
    local cur names
    cur="${COMP_WORDS[COMP_CWORD]}"
    names="$(awk -F= '!/^#/ && NF>1 {print $1}' "$HOME/.config/dev-start/projects" 2>/dev/null)"
    COMPREPLY=( $(compgen -W "init list status pick remove export import ${names}" -- "$cur") )
}
complete -F _dev_stack_complete dev-stack
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
#   - WSL2 + Ubuntu distro for tmux, perl toolchain, dev-stack
#   - Reuse this script's OS_FAMILY=ubuntu path *inside* WSL

report_missing_prereqs

echo "Environment setup complete for OS family: $OS_FAMILY"
echo "Perl binary in use: ${ACTIVE_PERL_BIN:-$(command -v perl 2>/dev/null || echo 'still not found')}"
echo "Open a new shell (or run 'source ~/.bashrc') so PATH picks up ~/.local/bin, then run 'dev-stack'."
