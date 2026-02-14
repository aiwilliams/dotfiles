# dotfiles

Personal system configuration for Ubuntu and macOS.

## Usage

```bash
./install.sh
```

## What it does

**All platforms (`install.sh`):**
- Sets git default branch to `main`
- Sets git user name
- Generates a per-host SSH key (`~/.ssh/id_ed25519_<hostname>`) if one doesn't exist

**Ubuntu (`install-ubuntu.sh`):**
- Installs tmux and keychain
- Configures keychain in `~/.bashrc` for persistent SSH agent across sessions

**macOS (`install-macos.sh`):**
- Installs tmux via Homebrew
