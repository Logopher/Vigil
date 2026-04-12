# Claude Configuration

## Installation

This repository is at `~/code/claude-config` for me, and I'm using it for my other project TCard. Here's how I set it up:

Add this to .bashrc:
```
[ -f ~/code/claude-config/claude.sh ] && source ~/code/claude-config/claude.sh
```

And create symlinks to ensure the files show up where they are needed.
```
ln -s ~/code/claude-config/project-settings.json ~/code/TCard/.claude/settings.json
ln -s ~/code/claude-config/global-settings.json ~/.claude/settings.json
```