#!/bin/bash
# install-hooks.sh
# Installs PreToolUse and PostToolUse hook scripts into the framework's
# configuration (settings.local.json or equivalent).
#
# Supports: Claude Code, OpenCode, generic (manual instructions)
#
# Usage:
#   ./install-hooks.sh [--framework claude|opencode|generic] [--dry-run]
#
# If --framework is not specified, auto-detection is attempted.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR"

PRE_TOOL_USE_SCRIPT="$HOOKS_DIR/pre-tool-use-bash-guard.sh"
POST_TOOL_USE_SCRIPT="$HOOKS_DIR/post-tool-use-bash-guard.sh"

DRY_RUN=false
DETECTED_FRAMEWORK=""

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------

info()  { printf "\033[0;34m[INFO]\033[0m %s\n" "$*"; }
ok()    { printf "\033[0;32m[OK]\033[0m   %s\n" "$*"; }
warn()  { printf "\033[0;33m[WARN]\033[0m %s\n" "$*" >&2; }
err()   { printf "\033[0;31m[ERR]\033[0m  %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --framework)
            shift
            DETECTED_FRAMEWORK="$1"
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --help|-h)
            echo "Usage: $0 [--framework claude|opencode|generic] [--dry-run]"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            echo "Usage: $0 [--framework claude|opencode|generic] [--dry-run]"
            exit 1
            ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Framework detection
# ---------------------------------------------------------------------------

detect_framework() {
    # Claude Code detection
    if [ -n "${CLAUDE_CODE:-}" ] || [ -f "$HOME/.claude/settings.local.json" ]; then
        echo "claude"
        return 0
    fi

    # Check for Claude Code config directory
    if [ -d "$HOME/.claude" ] && [ -f "$HOME/.claude/settings.json" ]; then
        echo "claude"
        return 0
    fi

    # OpenCode detection
    if [ -n "${OPEN_CODE:-}" ] || [ -f "$HOME/.opencode/settings.local.json" ]; then
        echo "opencode"
        return 0
    fi
    if [ -d "$HOME/.opencode" ]; then
        echo "opencode"
        return 0
    fi

    # Generic: no known framework detected
    echo "generic"
    return 0
}

# ---------------------------------------------------------------------------
# Verify hook scripts exist
# ---------------------------------------------------------------------------

verify_hook_scripts() {
    local missing=false

    if [ ! -f "$PRE_TOOL_USE_SCRIPT" ]; then
        err "PreToolUse script not found: $PRE_TOOL_USE_SCRIPT"
        missing=true
    elif [ ! -x "$PRE_TOOL_USE_SCRIPT" ]; then
        warn "PreToolUse script is not executable. Fixing..."
        chmod +x "$PRE_TOOL_USE_SCRIPT"
    fi

    if [ ! -f "$POST_TOOL_USE_SCRIPT" ]; then
        err "PostToolUse script not found: $POST_TOOL_USE_SCRIPT"
        missing=true
    elif [ ! -x "$POST_TOOL_USE_SCRIPT" ]; then
        warn "PostToolUse script is not executable. Fixing..."
        chmod +x "$POST_TOOL_USE_SCRIPT"
    fi

    if [ "$missing" = true ]; then
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Backup existing settings
# ---------------------------------------------------------------------------

backup_settings() {
    local settings_path="$1"

    if [ -f "$settings_path" ]; then
        local backup_path="${settings_path}.backup.$(date +%Y%m%d_%H%M%S)"
        info "Backing up existing settings to: $backup_path"
        if [ "$DRY_RUN" = false ]; then
            cp "$settings_path" "$backup_path"
            ok "Backup created: $backup_path"
        else
            info "[DRY-RUN] Would create backup: $backup_path"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Install hooks for Claude Code
# ---------------------------------------------------------------------------

install_claude_code() {
    info "Installing hooks for Claude Code..."

    local settings_dir="$HOME/.claude"
    local settings_file="$settings_dir/settings.local.json"
    local global_settings_file="$settings_dir/settings.json"

    mkdir -p "$settings_dir"

    # Determine which file to modify (prefer local over global)
    local target_file=""
    if [ -f "$settings_file" ]; then
        target_file="$settings_file"
    elif [ -f "$global_settings_file" ]; then
        target_file="$global_settings_file"
    else
        target_file="$settings_file"
    fi

    backup_settings "$target_file"

    # Build the hooks JSON snippet
    local hooks_json
    hooks_json=$(
        cat <<EOF
{
  "PreToolUse": [
    {
      "matcher": "Bash",
      "script": "$PRE_TOOL_USE_SCRIPT"
    }
  ],
  "PostToolUse": [
    {
      "matcher": "Bash",
      "script": "$POST_TOOL_USE_SCRIPT"
    }
  ]
}
EOF
    )

    info "Target settings file: $target_file"

    if [ "$DRY_RUN" = true ]; then
        info "[DRY-RUN] Would add the following hooks to $target_file:"
        echo "$hooks_json" | sed 's/^/         /'
        return 0
    fi

    # Check if the target file exists and has content
    if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        # Check if jq is available — use it for safe merge
        if command -v jq &>/dev/null; then
            local tmp_file="${target_file}.tmp"
            # Merge hooks into existing settings
            jq --arg pre_script "$PRE_TOOL_USE_SCRIPT" \
               --arg post_script "$POST_TOOL_USE_SCRIPT" \
               '.hooks.PreToolUse = [{"matcher": "Bash", "script": $pre_script}] |
                .hooks.PostToolUse = [{"matcher": "Bash", "script": $post_script}]' \
               "$target_file" > "$tmp_file" && mv "$tmp_file" "$target_file"
            ok "Hooks merged into $target_file"
        else
            warn "jq not found. Attempting to append hooks section manually."
            warn "This may produce invalid JSON if the file already has hooks."
            # Fallback: use sed to add hooks block before the closing brace
            sed -i '$s/}$/,\n  "hooks": '"$hooks_json"'\n}/' "$target_file" 2>/dev/null || {
                err "Failed to modify settings file. Install jq and retry."
                return 1
            }
            ok "Hooks appended to $target_file (manual mode)"
        fi
    else
        # Create new settings file with hooks
        cat > "$target_file" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "script": "$PRE_TOOL_USE_SCRIPT"
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "script": "$POST_TOOL_USE_SCRIPT"
      }
    ]
  }
}
EOF
        ok "Created $target_file with hooks configuration"
    fi

    # Verify the hooks are callable
    info "Verifying hook scripts are executable..."
    chmod +x "$PRE_TOOL_USE_SCRIPT" "$POST_TOOL_USE_SCRIPT" 2>/dev/null || true
    ok "Hook scripts are executable"

    return 0
}

# ---------------------------------------------------------------------------
# Install hooks for OpenCode
# ---------------------------------------------------------------------------

install_opencode() {
    info "Installing hooks for OpenCode..."

    local settings_dir="$HOME/.opencode"
    local settings_file="$settings_dir/settings.local.json"

    mkdir -p "$settings_dir"

    if [ -f "$settings_file" ]; then
        backup_settings "$settings_file"
    fi

    if [ "$DRY_RUN" = true ]; then
        info "[DRY-RUN] Would add hooks to $settings_file"
        return 0
    fi

    # OpenCode uses a similar hooks format to Claude Code
    if command -v jq &>/dev/null && [ -f "$settings_file" ] && [ -s "$settings_file" ]; then
        local tmp_file="${settings_file}.tmp"
        jq --arg pre_script "$PRE_TOOL_USE_SCRIPT" \
           --arg post_script "$POST_TOOL_USE_SCRIPT" \
           '.hooks.PreToolUse = [{"matcher": "Bash", "script": $pre_script}] |
            .hooks.PostToolUse = [{"matcher": "Bash", "script": $post_script}]' \
           "$settings_file" > "$tmp_file" && mv "$tmp_file" "$settings_file"
        ok "Hooks merged into $settings_file"
    else
        cat > "$settings_file" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "script": "$PRE_TOOL_USE_SCRIPT"
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "script": "$POST_TOOL_USE_SCRIPT"
      }
    ]
  }
}
EOF
        ok "Created $settings_file with hooks configuration"
    fi

    chmod +x "$PRE_TOOL_USE_SCRIPT" "$POST_TOOL_USE_SCRIPT" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# Install hooks for generic framework
# ---------------------------------------------------------------------------

install_generic() {
    info "No supported framework detected. Generating manual installation instructions."
    info "Hook scripts are located at:"
    info "  PreToolUse:  $PRE_TOOL_USE_SCRIPT"
    info "  PostToolUse: $POST_TOOL_USE_SCRIPT"

    echo ""
    echo "================================================================"
    echo "  Manual Installation Instructions"
    echo "================================================================"
    echo ""
    echo "  To install these hooks in your framework, add the following"
    echo "  to your settings.local.json (or equivalent):"
    echo ""
    echo "  {"
    echo "    \"hooks\": {"
    echo "      \"PreToolUse\": ["
    echo "        {"
    echo "          \"matcher\": \"Bash\","
    echo "          \"script\": \"$PRE_TOOL_USE_SCRIPT\""
    echo "        }"
    echo "      ],"
    echo "      \"PostToolUse\": ["
    echo "        {"
    echo "          \"matcher\": \"Bash\","
    echo "          \"script\": \"$POST_TOOL_USE_SCRIPT\""
    echo "        }"
    echo "      ]"
    echo "    }"
    echo "  }"
    echo ""
    echo "  Then ensure both scripts are executable:"
    echo ""
    echo "    chmod +x \\"
    echo "      \"$PRE_TOOL_USE_SCRIPT\" \\"
    echo "      \"$POST_TOOL_USE_SCRIPT\""
    echo ""
    echo "================================================================"
    echo ""

    if [ "$DRY_RUN" = false ]; then
        chmod +x "$PRE_TOOL_USE_SCRIPT" "$POST_TOOL_USE_SCRIPT" 2>/dev/null || true
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Verify installation
# ---------------------------------------------------------------------------

verify_installation() {
    local framework="$1"

    echo ""
    info "--- Running verification ---"

    # 1. Check hook scripts exist
    if [ ! -f "$PRE_TOOL_USE_SCRIPT" ]; then
        err "PreToolUse script missing after installation!"
        return 1
    fi
    if [ ! -f "$POST_TOOL_USE_SCRIPT" ]; then
        err "PostToolUse script missing after installation!"
        return 1
    fi
    ok "Hook scripts exist"

    # 2. Check hook scripts are executable
    if [ ! -x "$PRE_TOOL_USE_SCRIPT" ]; then
        warn "PreToolUse script not executable, fixing..."
        chmod +x "$PRE_TOOL_USE_SCRIPT"
    fi
    if [ ! -x "$POST_TOOL_USE_SCRIPT" ]; then
        warn "PostToolUse script not executable, fixing..."
        chmod +x "$POST_TOOL_USE_SCRIPT"
    fi
    ok "Hook scripts are executable"

    # 3. Check framework-specific config
    case "$framework" in
        claude)
            local files=("$HOME/.claude/settings.local.json" "$HOME/.claude/settings.json")
            local found=false
            for f in "${files[@]}"; do
                if [ -f "$f" ] && grep -q "PreToolUse" "$f" 2>/dev/null; then
                    ok "Claude Code settings file contains hooks: $f"
                    found=true
                    break
                fi
            done
            if [ "$found" = false ]; then
                warn "Could not verify hooks in Claude Code settings files."
                warn "Checked: ${files[*]}"
            fi
            ;;
        opencode)
            if [ -f "$HOME/.opencode/settings.local.json" ] && grep -q "PreToolUse" "$HOME/.opencode/settings.local.json" 2>/dev/null; then
                ok "OpenCode settings file contains hooks"
            else
                warn "Could not verify hooks in OpenCode settings"
            fi
            ;;
        generic)
            info "Skipping config verification for generic framework."
            info "Verify manually using the instructions above."
            ;;
    esac

    # 4. Quick smoke test: invoke each hook with minimal input
    info "Running smoke tests..."

    # PreToolUse smoke test
    local pre_result
    pre_result=$(echo '{}' | bash "$PRE_TOOL_USE_SCRIPT" 2>/dev/null) || true
    if [ -n "$pre_result" ]; then
        ok "PreToolUse hook: responds to input"
    else
        warn "PreToolUse hook: produced no output (may be ok if input format differs)"
    fi

    # PostToolUse smoke test
    local post_result
    post_result=$(echo '{"result":"test"}' | bash "$POST_TOOL_USE_SCRIPT" 2>/dev/null) || true
    if [ -n "$post_result" ]; then
        ok "PostToolUse hook: responds to input"
    else
        warn "PostToolUse hook: produced no output (may be ok if input format differs)"
    fi

    echo ""
    ok "--- Verification complete ---"
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    echo "================================================================"
    echo "  Safe File Ops - Hook Installer"
    echo "================================================================"
    echo ""

    # Verify hook scripts exist
    if ! verify_hook_scripts; then
        err "Hook scripts are missing. Ensure the following files exist:"
        err "  $PRE_TOOL_USE_SCRIPT"
        err "  $POST_TOOL_USE_SCRIPT"
        exit 1
    fi
    ok "All hook scripts found"

    # Detect framework if not specified
    if [ -z "$DETECTED_FRAMEWORK" ]; then
        DETECTED_FRAMEWORK=$(detect_framework)
        info "Auto-detected framework: $DETECTED_FRAMEWORK"
    else
        info "Using specified framework: $DETECTED_FRAMEWORK"
    fi

    # Install hooks based on framework
    case "$DETECTED_FRAMEWORK" in
        claude)
            install_claude_code
            ;;
        opencode)
            install_opencode
            ;;
        generic)
            install_generic
            ;;
        *)
            err "Unknown framework: $DETECTED_FRAMEWORK"
            exit 1
            ;;
    esac

    # Verify installation (skip dry-run verification)
    if [ "$DRY_RUN" = false ]; then
        verify_installation "$DETECTED_FRAMEWORK"
    else
        info "[DRY-RUN] Skipping verification."
    fi

    echo ""
    info "Installation complete for framework: $DETECTED_FRAMEWORK"
    echo ""
    info "Next steps:"
    info "  1. Restart the agent (Claude Code / OpenCode) to load the new hooks."
    info "  2. Test with: bash -c 'echo test'"
    info "  3. Test blocking: rm -rf / (should be blocked)"
    info "  4. Test auto-fix: mkdir /tmp/test/nested/dir (should get -p auto-added)"
    echo ""
}

main
