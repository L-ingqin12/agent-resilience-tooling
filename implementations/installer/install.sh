#!/usr/bin/env bash
# install.sh — Agent Resilience Tooling Unified Installer
# Version: 1.0.0
#
# Auto-detects framework capabilities and installs the appropriate protection level.
# Usage:
#   bash install.sh                    # Interactive mode
#   bash install.sh --detect           # Just detect, don't install
#   bash install.sh --all              # Install everything available
#   bash install.sh --scenario S3      # Install specific scenario

set -o pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
INSTALL_DIR="${INSTALL_DIR:-$HOME/.agent}"
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  Agent Resilience Tooling Installer    ${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# ─── Step 1: Detect Framework ────────────────────────────────────
detect_framework() {
    echo -e "${YELLOW}[DETECT] Framework detection...${NC}"

    FRAMEWORK="unknown"
    FRAMEWORK_VERSION="unknown"

    # Claude Code
    if command -v claude &>/dev/null; then
        FRAMEWORK="claude-code"
        FRAMEWORK_VERSION=$(claude --version 2>/dev/null | head -1 || echo "unknown")
    # OpenAI / ChatGPT with function calling
    elif [ -n "${OPENAI_API_KEY:-}" ] || [ -f "$HOME/.openai/auth.json" ]; then
        FRAMEWORK="openai"
    # LangChain
    elif python3 -c "import langchain" 2>/dev/null; then
        FRAMEWORK="langchain"
        FRAMEWORK_VERSION=$(python3 -c "import langchain; print(langchain.__version__)" 2>/dev/null || echo "unknown")
    fi

    echo "  Framework: $FRAMEWORK ($FRAMEWORK_VERSION)"
}

# ─── Step 2: Detect Control Surfaces ─────────────────────────────
detect_controls() {
    echo -e "${YELLOW}[DETECT] Control surface detection...${NC}"

    C1_PROMPT=false; C2_SKILL=false; C3_TOOL=false
    C4_HOOK=false; C5_INTERCEPT=false; C6_SANDBOX=false

    # C1: Can we inject system prompt? (almost always yes)
    if [ -f "$HOME/.claude/CLAUDE.md" ] || [ -f "./CLAUDE.md" ] || [ -f "./agents.md" ]; then
        C1_PROMPT=true
    elif [ -n "${AGENT_SYSTEM_PROMPT:-}" ]; then
        C1_PROMPT=true
    else
        C1_PROMPT=true  # Assume we can create agents.md
    fi

    # C2: Skill support
    if [ -d "$HOME/.claude/skills/" ] || [ -d "./skills/" ]; then
        C2_SKILL=true
    fi

    # C3: Custom tool support
    if [ -n "${MCP_SERVER:-}" ] || [ -d "$HOME/.claude/plugins/" ]; then
        C3_TOOL=true
    fi
    # Python-based frameworks always support custom tools
    if [ "$FRAMEWORK" = "langchain" ] || [ "$FRAMEWORK" = "openai" ]; then
        C3_TOOL=true
    fi

    # C4: Hook support
    if [ -f "$HOME/.claude/settings.local.json" ] || [ -f "./.claude/settings.local.json" ]; then
        C4_HOOK=true
    fi

    # C5: Command interception (always possible with wrapper approach)
    C5_INTERCEPT=true

    # C6: OS sandbox
    if [ -f /proc/sys/kernel/unprivileged_bpf_disabled ] || command -v docker &>/dev/null; then
        C6_SANDBOX=true
    fi
    # Check Landlock
    if grep -q landlock /proc/filesystems 2>/dev/null; then
        C6_SANDBOX=true
    fi

    echo "  C1 (Prompt injection):    $C1_PROMPT"
    echo "  C2 (Skill support):       $C2_SKILL"
    echo "  C3 (Custom tools):        $C3_TOOL"
    echo "  C4 (Hooks/middleware):    $C4_HOOK"
    echo "  C5 (Cmd interception):    $C5_INTERCEPT"
    echo "  C6 (OS sandbox):          $C6_SANDBOX"
}

# ─── Step 3: Determine Scenario ──────────────────────────────────
determine_scenario() {
    if $C6_SANDBOX && $C5_INTERCEPT && $C4_HOOK && $C3_TOOL; then
        SCENARIO="S6"
    elif $C5_INTERCEPT && $C4_HOOK && $C3_TOOL; then
        SCENARIO="S5"
    elif $C4_HOOK && $C3_TOOL; then
        SCENARIO="S4"
    elif $C3_TOOL; then
        SCENARIO="S3"
    elif $C2_SKILL && $C1_PROMPT; then
        SCENARIO="S2"
    elif $C1_PROMPT; then
        SCENARIO="S1"
    else
        SCENARIO="S0"
    fi

    echo -e "${GREEN}[DETECT] Recommended scenario: $SCENARIO${NC}"
    echo "  Protection rate: $(case $SCENARIO in
        S6) echo "~99%";; S5) echo "~97%";; S4) echo "~92%";;
        S3) echo "~85%";; S2) echo "~75%";; S1) echo "~60%";;
        S0) echo "0% (no protection possible)";;
    esac)"
}

# ─── Step 4: Install Core Libraries (S3+) ────────────────────────
install_core_libs() {
    echo -e "${YELLOW}[INSTALL] Core libraries...${NC}"
    mkdir -p "$INSTALL_DIR"

    cp "$REPO_DIR/agent-safe-fs.sh" "$INSTALL_DIR/safe-fs.sh"
    chmod +x "$INSTALL_DIR/safe-fs.sh"
    echo "  ✓ Installed: $INSTALL_DIR/safe-fs.sh"

    cp "$REPO_DIR/06-checkpoint-recovery/agent-checkpoint.sh" "$INSTALL_DIR/agent-checkpoint.sh"
    chmod +x "$INSTALL_DIR/agent-checkpoint.sh"
    echo "  ✓ Installed: $INSTALL_DIR/agent-checkpoint.sh"

    # Verify installation
    if bash -n "$INSTALL_DIR/safe-fs.sh" && bash -n "$INSTALL_DIR/agent-checkpoint.sh"; then
        echo -e "${GREEN}  ✓ Syntax check passed${NC}"
    else
        echo -e "${RED}  ✗ Syntax check failed${NC}"
        return 1
    fi
}

# ─── Step 5: Install Prompt (S1+) ──────────────────────────────
install_prompt() {
    local scenario="${1:-S1}"
    echo -e "${YELLOW}[INSTALL] System prompt for $scenario...${NC}"

    local prompt_file="$REPO_DIR/implementations/prompts/s1-prompt-only.txt"
    case "$scenario" in
        S3|S4|S5|S6) prompt_file="$REPO_DIR/implementations/prompts/s3-prompt-minimal.txt" ;;
    esac

    if [ -f "$prompt_file" ]; then
        # For Claude Code: append to CLAUDE.md
        if [ "$FRAMEWORK" = "claude-code" ]; then
            local claude_md="${CLAUDE_MD:-$PWD/CLAUDE.md}"
            [ ! -f "$claude_md" ] && touch "$claude_md"
            echo "" >> "$claude_md"
            echo "<!-- Agent Resilience Tooling — $scenario auto-installed -->" >> "$claude_md"
            cat "$prompt_file" >> "$claude_md"
            echo "  ✓ Prompt injected into $claude_md"
        else
            cp "$prompt_file" "$INSTALL_DIR/system-prompt.txt"
            echo "  ✓ Prompt saved to $INSTALL_DIR/system-prompt.txt"
            echo "  ℹ  Manually add to your agent's system message"
        fi
    else
        echo "  ⚠ Prompt file not found: $prompt_file"
    fi
}

# ─── Step 6: Install Skill (S2+) ────────────────────────────────
install_skill() {
    echo -e "${YELLOW}[INSTALL] safe-file-ops skill...${NC}"
    local skill_src="$REPO_DIR/implementations/skills/safe-file-ops.md"

    if [ -f "$skill_src" ]; then
        if [ "$FRAMEWORK" = "claude-code" ] || [ -d "$HOME/.claude/skills/" ]; then
            mkdir -p "$HOME/.claude/skills/safe-file-ops"
            cp "$skill_src" "$HOME/.claude/skills/safe-file-ops/SKILL.md"
            echo "  ✓ Skill installed to ~/.claude/skills/safe-file-ops/"
        else
            cp "$skill_src" "$INSTALL_DIR/safe-file-ops-skill.md"
            echo "  ✓ Skill saved to $INSTALL_DIR/safe-file-ops-skill.md"
        fi
    fi
}

# ─── Step 7: Install Hooks (S4+) ────────────────────────────────
install_hooks() {
    echo -e "${YELLOW}[INSTALL] Pre/Post ToolUse hooks...${NC}"
    local hooks_dir="$REPO_DIR/implementations/hooks"

    if [ "$FRAMEWORK" = "claude-code" ] && [ -f "$hooks_dir/install-hooks.sh" ]; then
        bash "$hooks_dir/install-hooks.sh" --framework claude-code
    else
        cp "$hooks_dir/pre-tool-use-bash-guard.sh" "$INSTALL_DIR/"
        cp "$hooks_dir/post-tool-use-bash-guard.sh" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/pre-tool-use-bash-guard.sh" "$INSTALL_DIR/post-tool-use-bash-guard.sh"
        echo "  ✓ Hook scripts saved to $INSTALL_DIR/"
        echo "  ℹ  Configure PreToolUse/PostToolUse in your framework to call these scripts"
    fi
}

# ─── Step 8: Install Command Interceptor (S5+) ──────────────────
install_interceptor() {
    echo -e "${YELLOW}[INSTALL] Bash interceptor...${NC}"
    local interceptor="$REPO_DIR/implementations/wrappers/bash-interceptor.sh"

    cp "$interceptor" "$INSTALL_DIR/bash-interceptor.sh"
    chmod +x "$INSTALL_DIR/bash-interceptor.sh"

    if [ "$FRAMEWORK" = "claude-code" ]; then
        echo "  ℹ  To activate interceptor for Claude Code, set:"
        echo "     export AGENT_BASH_CMD='bash $INSTALL_DIR/bash-interceptor.sh --'"
    else
        echo "  ✓ Interceptor installed to $INSTALL_DIR/bash-interceptor.sh"
        echo "  ℹ  Configure your agent to use this as the bash command wrapper"
    fi
}

# ─── Step 9: Install Sandbox (S6) ──────────────────────────────────
install_sandbox() {
    echo -e "${YELLOW}[INSTALL] OS Sandbox...${NC}"
    local sandbox_src="$REPO_DIR/implementations/sandbox/landlock-agent-sandbox.c"

    if [ -f "$sandbox_src" ] && command -v gcc &>/dev/null; then
        gcc -Wall -o "$INSTALL_DIR/landlock-agent-sandbox" "$sandbox_src" 2>/dev/null && {
            echo "  ✓ Landlock sandbox compiled: $INSTALL_DIR/landlock-agent-sandbox"
            echo "  ℹ  Usage: $INSTALL_DIR/landlock-agent-sandbox --rw /tmp/agent --ro /usr -- /bin/bash"
        } || {
            echo "  ⚠ Landlock compilation failed (may need Linux 5.13+ headers)"
        }
    elif command -v docker &>/dev/null; then
        echo "  ℹ  Docker available. Use container-based sandbox:"
        echo "     docker run --rm -v /tmp/agent:/workspace:rw --read-only agent-image"
    else
        echo "  ⚠ No sandbox tools available (gcc for Landlock, or Docker)"
    fi
}

# ─── Step 10: Install Python Adapter ────────────────────────────
install_python() {
    if [ "$FRAMEWORK" = "langchain" ] || [ "$FRAMEWORK" = "openai" ] || command -v python3 &>/dev/null; then
        echo -e "${YELLOW}[INSTALL] Python adapter...${NC}"
        cp "$REPO_DIR/implementations/adapters/python-safe-tools.py" "$INSTALL_DIR/python-safe-tools.py"
        echo "  ✓ Installed: $INSTALL_DIR/python-safe-tools.py"

        if python3 -c "import $INSTALL_DIR/python-safe-tools" 2>/dev/null; then
            echo -e "${GREEN}  ✓ Python import test passed${NC}"
        else
            echo "  ℹ  Python import via sys.path — see $INSTALL_DIR/python-safe-tools.py"
        fi
    fi
}

# ─── Main ────────────────────────────────────────────────────────
main() {
    local target_scenario="${SCENARIO:-}"

    # Parse args
    for arg in "$@"; do
        case "$arg" in
            --detect)
                detect_framework; detect_controls; determine_scenario
                exit 0 ;;
            --all) target_scenario="" ;;  # Install everything
            --scenario) shift; target_scenario="${1:-S1}" ;;
            --help|-h)
                echo "Usage: bash install.sh [OPTIONS]"
                echo "  --detect      Detect framework and control surfaces (no install)"
                echo "  --all         Install all available protections"
                echo "  --scenario N  Install specific scenario (S1-S6)"
                exit 0 ;;
        esac
        shift 2>/dev/null || true
    done

    detect_framework
    detect_controls

    if [ -z "$target_scenario" ]; then
        determine_scenario
        target_scenario="$SCENARIO"
    fi

    echo ""
    echo -e "${CYAN}[INSTALL] Installing scenario: $target_scenario${NC}"
    echo ""

    # Install based on scenario
    case "$target_scenario" in
        S6) install_core_libs; install_prompt S6; install_skill
            install_hooks; install_interceptor; install_sandbox; install_python ;;
        S5) install_core_libs; install_prompt S5; install_skill
            install_hooks; install_interceptor; install_python ;;
        S4) install_core_libs; install_prompt S4; install_skill
            install_hooks; install_python ;;
        S3) install_core_libs; install_prompt S3; install_python ;;
        S2) install_prompt S2; install_skill ;;
        S1) install_prompt S1 ;;
        S0) echo -e "${RED}  Cannot install — no control surfaces available.${NC}"
            echo "  See: docs/llm-cognitive-guidance.md for manual guidance" ;;
    esac

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Installation Complete ($target_scenario)${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Files installed to: $INSTALL_DIR"
    echo ""
    echo "Next steps:"
    echo "  1. Verify: source $INSTALL_DIR/safe-fs.sh && ensure_directory /tmp/test"
    echo "  2. Verify: source $INSTALL_DIR/agent-checkpoint.sh && checkpoint_save 'test' 'test' 'test' 'none' 'none' '' "
    echo "  3. Restart your agent session to load the new system prompt"
    echo ""
    echo "For full documentation: $REPO_DIR/README.md"
}

main "$@"
