# dev-stack

A unified development environment: a provisioning script plus the actual dotfiles it manages, for macOS (laptop), Red Hat (workstation), and Ubuntu (VPS). Clone this repo anywhere and run `setup-env.sh` to get the same nvim config, tmux setup, and project launcher on a new machine.

MIT licensed, see [LICENSE](./LICENSE).

## Prerequisites

- **macOS**: [Homebrew](https://brew.sh) must already be installed. If it isn't, `setup-env.sh` just warns and skips package installation entirely, nothing else in the script depends on Homebrew, so dotfile linking and `dev-start` still work.
- **RHEL / Ubuntu**: `dnf`/`apt-get` and `sudo` access, which any normal install already has.
- `git` and `bash` on all three.

## Layout of this repo

```
setup-env.sh    Provisioning script - installs packages, links dotfiles below
nvim/           LazyVim config (dotfile source of truth, symlinked to ~/.config/nvim)
tmux/tmux.conf  tmux config (dotfile source of truth, symlinked to ~/.tmux.conf)
```

`nvim/` and `tmux/tmux.conf` are the real, live config files, not templates. Edit them here, commit, and re-run `setup-env.sh` on any machine to pick up the change (or just reload tmux/nvim directly, since the symlink means the edit already took effect).

## What it does

`setup-env.sh` is idempotent, safe to re-run any time:

- Detects your OS (macOS / RHEL / Ubuntu) and installs the right packages with the right package manager (`brew`, `dnf`, `apt-get`).
- Follows the Perl Principle, applied equally to Python: never forces a system-wide Perl or Python reinstall if a working binary is already on `PATH` (important if you manage either with something like perlbrew, pyenv, or conda, since the OS package manager installing "on top" can silently change what `perl`/`python3` resolve to, or even overwrite existing symlinks via `brew link`). Only installs `Perl::Tidy` and `Perl::Critic` via `cpanm` if they're missing, since `nvim/lua/plugins/perl.lua` already wires up `perlnavigator`, `perltidy`, and `perlcritic`.
- Installs global web tooling (`prettier`, `live-server`) to a user-owned npm prefix, not root.
- Symlinks `~/.config/nvim` to this repo's `nvim/`, and `~/.tmux.conf` to `tmux/tmux.conf`. If a real (non-symlink) config already exists at either location, it's renamed to a timestamped `.bak` next to it first - **never deleted**, so a first run on a machine with its own hand-built config is safe; nothing is lost, you just end up with a `.bak` directory to compare against and discard once you're happy.
- Keeps tmux on the factory-default `Ctrl+b` prefix intentionally, so it never collides with LazyVim's `Ctrl+h/j/k/l` pane navigation from `vim-tmux-navigator`, plus installs `tmux-persist`, `tmux-yank`, and `extrakto`.
- Installs `~/.local/bin/dev-start`, a project launcher (see below).
- Adds shell completion for `dev-start` to both `~/.bashrc` and `~/.zshrc`.

Windows is not yet supported. See the stub at the bottom of the script.

## Using this on another machine (or someone else using it)

One-liner, no manual clone needed:

```
curl -fsSL https://raw.githubusercontent.com/rshingleton/dev-stack/main/install.sh | bash
```

`install.sh` is the only thing safe to pipe into `bash` sight-unseen (it does nothing but clone/update the repo to `~/dev-stack` and hand off); everything else - packages, symlinks - lives in `setup-env.sh`, which `install.sh` runs for you. Re-running the one-liner later just pulls the latest and re-runs it, same idempotent behavior as running it locally.

Override where it's cloned or which repo it pulls from with env vars:

```
DEV_STACK_DIR=~/code/dev-stack DEV_STACK_REPO_URL=https://github.com/rshingleton/dev-stack.git \
  curl -fsSL https://raw.githubusercontent.com/rshingleton/dev-stack/main/install.sh | bash
```

Or clone it yourself and skip the bootstrap entirely:

```
git clone https://github.com/rshingleton/dev-stack.git ~/dev-stack
cd ~/dev-stack
chmod +x setup-env.sh
./setup-env.sh
```

`setup-env.sh` finds its own location (`SCRIPT_DIR`), so both paths behave identically, there's no hardcoded path back to this machine. If you're setting this up for yourself rather than forking it, you'll likely want to replace `nvim/` and `tmux/tmux.conf` with your own config before running it, the LazyVim setup here (Perl LSP, debugger, test runner) is specific to this machine's workflow.

## dev-start

`dev-start` launches (or reattaches to) a tmux session for a project, with nvim, Claude Code, and a small shell all laid out for you. No project list is hardcoded in the script; aliases are registered per machine.

```
dev-start init <name> <path>   Register an alias for a project path
dev-start list                 Show registered aliases
dev-start status               Show which aliases are running, restorable, or neither
dev-start pick                 Fuzzy-pick a registered alias and launch it (uses fzf if installed)
dev-start remove <name>        Remove an alias
dev-start export [file]        Print (or save) aliases, to move to another machine
dev-start import <file>        Merge aliases from a file (fix paths afterward)
dev-start [name-or-path] [session-name]
```

Aliases live in `~/.config/dev-start/projects`, a machine-local file (paths differ across the laptop/workstation/VPS, so this is deliberately **not** synced or committed). Use `export`/`import` to move the list between machines and fix the paths by hand.

### Layout

Each session gets one window with nvim, Claude Code, and an idle shell for git/cmd-line ops:

- **Vertical** (default): nvim on top, Claude Code in the middle, shell sliver at the bottom.
- **Horizontal**: nvim on the left (full height), Claude Code top-right, shell sliver bottom-right.

Set `DEV_START_LAYOUT=horizontal` to switch, e.g. `DEV_START_LAYOUT=horizontal dev-start myproject`.

`dev-start` also knows about `tmux-persist`: since persist auto-restores a session's saved layout the instant a session with a matching name is created, `dev-start` checks for an existing snapshot first and steps out of the way (just creating a bare session) rather than racing persist's restore with its own layout-building commands.

## Usage

```
chmod +x setup-env.sh
./setup-env.sh
```

Re-run any time; every step checks before it acts.
