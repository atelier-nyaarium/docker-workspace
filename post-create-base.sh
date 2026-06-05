#!/bin/bash

# Post-create script for devcontainer

set -e


# Restore bashrc from image with version check
BASHRC_SRC="/home/agent/.bashrc"
BASHRC_DST="/home/vscode/.bashrc"
if [ -f "$BASHRC_SRC" ]; then
	VERSION_STRING=$(grep -o "Devcontainer: v.*" "$BASHRC_SRC" | head -n1)
	if [ ! -f "$BASHRC_DST" ]; then
		cp "$BASHRC_SRC" "$BASHRC_DST"
		chmod 644 "$BASHRC_DST"
	elif [ -n "$VERSION_STRING" ] && ! grep -q "$VERSION_STRING" "$BASHRC_DST" 2>/dev/null; then
		cp "$BASHRC_SRC" "$BASHRC_DST"
		chmod 644 "$BASHRC_DST"
	fi
fi


# Restore agent home into mounted vscode home (skip existing files on volume)
rsync -a --ignore-existing --exclude='/.bashrc' --exclude='/.bash_logout' --exclude='/.profile' /home/agent/ /home/vscode/


# Fix ownership of workspace files
chown vscode:vscode /workspace
find /workspace -mindepth 1 -maxdepth 1 -exec chown vscode:vscode {} +

# Fix ownership of volume mounted home dir recursively
find /home/vscode -name scripts -prune -o \( ! -user vscode -o ! -group vscode \) -exec chown vscode:vscode {} +


# Add GitHub SSH host key to known_hosts
su -c 'mkdir -p ~/.ssh' vscode
if ! su -c 'grep -q "^github.com " ~/.ssh/known_hosts 2>/dev/null' vscode; then
	su -c 'ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null' vscode
fi


# Ensure base gitconfig settings
su -c 'git config --global safe.directory /workspace' vscode
su -c 'git config --global commit.gpgSign >/dev/null 2>&1' vscode  || su -c 'git config --global commit.gpgSign false' vscode
su -c 'git config --global init.defaultBranch >/dev/null 2>&1' vscode || su -c 'git config --global init.defaultBranch main' vscode


# Detect and set editor
if su -c 'which cursor' vscode >/dev/null 2>&1; then
	DETECTED_EDITOR="cursor --wait"
	su -c "git config --global core.editor '$DETECTED_EDITOR'" vscode
elif su -c 'which code' vscode >/dev/null 2>&1; then
	DETECTED_EDITOR="code --wait"
	su -c "git config --global core.editor '$DETECTED_EDITOR'" vscode
fi


# Configure user-wide MCP servers in ~/.claude.json
if command -v jq >/dev/null 2>&1; then
	CLAUDE_JSON="/home/vscode/.claude.json"
	[ ! -f "$CLAUDE_JSON" ] && echo '{}' > "$CLAUDE_JSON"
	UPDATED=$(jq '
		.mcpServers //= {} |
		.mcpServers.playwright //= {
			command: "npx",
			args: ["@playwright/mcp@latest", "--headless", "--no-sandbox"],
			env: {}
		}
	' "$CLAUDE_JSON")
	echo "$UPDATED" > "$CLAUDE_JSON"
	chown vscode:vscode "$CLAUDE_JSON"
fi


# Trust workspace for Claude Code, Cursor, Copilot, and Codex
if [ -n "$PROJECT_NAME" ] && command -v jq >/dev/null 2>&1; then
	WORKSPACE_PATH="/workspace/$PROJECT_NAME"

	# Claude Code: ~/.claude.json
	CLAUDE_JSON="/home/vscode/.claude.json"
	[ ! -f "$CLAUDE_JSON" ] && echo '{}' > "$CLAUDE_JSON"
	UPDATED=$(jq --arg path "$WORKSPACE_PATH" '
		.projects[$path] //= {} |
		.projects[$path].hasTrustDialogAccepted = true
	' "$CLAUDE_JSON")
	echo "$UPDATED" > "$CLAUDE_JSON"

	# Cursor: ~/.cursor/projects/<folder-name>/.workspace-trusted
	FOLDER_NAME=$(echo "$WORKSPACE_PATH" | sed 's|^/||; s|/|-|g')
	CURSOR_DIR="/home/vscode/.cursor/projects/$FOLDER_NAME"
	CURSOR_TRUST="$CURSOR_DIR/.workspace-trusted"
	if [ ! -f "$CURSOR_TRUST" ]; then
		mkdir -p "$CURSOR_DIR"
		jq -n --arg path "$WORKSPACE_PATH" '{trustedAt: (now | todate), workspacePath: $path}' > "$CURSOR_TRUST"
	fi

	# Copilot: ~/.copilot/config.json
	COPILOT_JSON="/home/vscode/.copilot/config.json"
	if [ ! -f "$COPILOT_JSON" ]; then
		mkdir -p /home/vscode/.copilot
		echo '{}' > "$COPILOT_JSON"
	fi
	# Copilot writes config.json as JSONC (leading // header lines); strip them before jq
	UPDATED=$(sed 's|^[[:space:]]*//.*$||' "$COPILOT_JSON" | jq --arg path "$WORKSPACE_PATH" '
		.trustedFolders //= [] |
		if (.trustedFolders | index($path)) then . else .trustedFolders += [$path] end
	')
	echo "$UPDATED" > "$COPILOT_JSON"

	# Codex: ~/.codex/config.toml
	CODEX_DIR="/home/vscode/.codex"
	CODEX_TOML="$CODEX_DIR/config.toml"
	if [ ! -f "$CODEX_TOML" ]; then
		mkdir -p "$CODEX_DIR"
		echo "" > "$CODEX_TOML"
	fi
	if ! grep -qF "[projects.\"$WORKSPACE_PATH\"]" "$CODEX_TOML" 2>/dev/null; then
		printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$WORKSPACE_PATH" >> "$CODEX_TOML"
	fi

	chown -R vscode:vscode /home/vscode/.claude.json /home/vscode/.cursor /home/vscode/.copilot /home/vscode/.codex
fi
