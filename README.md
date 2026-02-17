# dotfiles

System configuration for Ubuntu and macOS.

## Usage

```bash
./install.sh
```

## What it does

**All platforms (`install.sh`):**
- Sets git default branch to `main`
- Prompts for git identity if not configured
- Generates a per-host SSH key (`~/.ssh/id_ed25519_<hostname>`) if one doesn't exist
- Installs a pre-commit hook with secrets detection and shellcheck

**Ubuntu (`install-ubuntu.sh`):**
- Installs tmux and keychain
- Configures keychain in `~/.bashrc` for persistent SSH agent across sessions

**macOS (`install-macos.sh`):**
- Installs tmux via Homebrew
