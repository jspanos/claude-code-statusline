#!/bin/bash
# Claude Code Status Line
# Displays: model | project dir → cwd | git branch | context bar | cost | time

input=$(cat)

# ── Extract fields ──────────────────────────────────────────────────────────
MODEL=$(echo "$input"      | jq -r '.model.display_name // "unknown"')
PROJECT=$(echo "$input"    | jq -r '.workspace.project_dir // .cwd // ""')
CWD=$(echo "$input"        | jq -r '.workspace.current_dir // .cwd // ""')
PCT=$(echo "$input"        | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
CTX_SIZE=$(echo "$input"   | jq -r '.context_window.context_window_size // 200000')
CTX_USED=$(echo "$input"   | jq -r '
  (.context_window.current_usage |
    if . == null then 0
    else (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)
    end
  )')
IN_TOKENS=$(echo "$input"  | jq -r '.context_window.total_input_tokens // .context_window.current_usage.input_tokens // 0')
OUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_output_tokens // .context_window.current_usage.output_tokens // 0')
COST=$(echo "$input"       | jq -r '.cost.total_cost_usd // 0')
DURATION=$(echo "$input"   | jq -r '.cost.total_duration_ms // 0')
RATE_5H=$(echo "$input"    | jq -r '.rate_limits.five_hour.used_percentage // empty')

# ── Colors ───────────────────────────────────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
GRAY='\033[37m'
CYAN='\033[96m'
BLUE='\033[94m'
GREEN='\033[92m'
YELLOW='\033[93m'
RED='\033[91m'
MAGENTA='\033[95m'
WHITE='\033[97m'

# ── Folders ──────────────────────────────────────────────────────────────────
PROJECT_NAME="${PROJECT##*/}"
CWD_NAME="${CWD##*/}"

if [ "$PROJECT" = "$CWD" ] || [ -z "$CWD_NAME" ]; then
    DIR_DISPLAY="${CYAN}${BOLD}${PROJECT_NAME}${RESET}"
else
    DIR_DISPLAY="${CYAN}${PROJECT_NAME}${RESET} ${GRAY}›${RESET} ${CYAN}${BOLD}${CWD_NAME}${RESET}"
fi

# ── Git branch ───────────────────────────────────────────────────────────────
GIT_PART=""
if git -C "$CWD" rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
    if [ -n "$BRANCH" ]; then
        STAGED=$(git -C "$CWD" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
        MODIFIED=$(git -C "$CWD" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
        GIT_PART=" ${GRAY}|${RESET} ${GREEN}⎇ ${BRANCH}${RESET}"
        [ "$STAGED" -gt 0 ]   && GIT_PART="${GIT_PART} ${GREEN}+${STAGED}${RESET}"
        [ "$MODIFIED" -gt 0 ] && GIT_PART="${GIT_PART} ${YELLOW}~${MODIFIED}${RESET}"
    fi
fi

# ── Context bar ──────────────────────────────────────────────────────────────
BAR_WIDTH=12
FILLED=$(( PCT * BAR_WIDTH / 100 ))
EMPTY=$(( BAR_WIDTH - FILLED ))

if [ "$PCT" -ge 90 ]; then
    BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then
    BAR_COLOR="$YELLOW"
else
    BAR_COLOR="$GREEN"
fi

BAR=""
[ "$FILLED" -gt 0 ] && printf -v F "%${FILLED}s" && BAR="${F// /█}"
[ "$EMPTY"  -gt 0 ] && printf -v E "%${EMPTY}s"  && BAR="${BAR}${E// /░}"

# ── Cost ─────────────────────────────────────────────────────────────────────
COST_FMT=$(printf '$%.4f' "$COST")

# ── Duration ─────────────────────────────────────────────────────────────────
SECS=$(( DURATION / 1000 ))
MINS=$(( SECS / 60 ))
SECS=$(( SECS % 60 ))
TIME_FMT="${MINS}m ${SECS}s"

# ── Token counts (human-readable k) ─────────────────────────────────────────
CTX_USED_K=$(( CTX_USED / 1000 ))
CTX_SIZE_K=$(( CTX_SIZE / 1000 ))
IN_K=$(( IN_TOKENS / 1000 ))
OUT_K=$(( OUT_TOKENS / 1000 ))
CTX_TOKENS="${CTX_USED_K}k / ${CTX_SIZE_K}k  ↑${IN_K}k ↓${OUT_K}k"

# ── Rate limits ──────────────────────────────────────────────────────────────
RATE_PART=""
if [ -n "$RATE_5H" ]; then
    RATE_INT=$(printf '%.0f' "$RATE_5H")
    RATE_PART=" ${GRAY}|${RESET} ${MAGENTA}plan: ${RATE_INT}%${RESET}"
fi

# ── Output ───────────────────────────────────────────────────────────────────
# Line 1: model | dirs | git
echo -e " ${BLUE}⬡ ${MODEL}${RESET}  ${GRAY}|${RESET}  📁 ${DIR_DISPLAY}${GIT_PART}"
# Line 2: context bar + % + tokens | cost | time | rate limit
echo -e " ${BAR_COLOR}${BAR}${RESET} ${BAR_COLOR}${PCT}% ctx${RESET}  ${GRAY}${CTX_TOKENS}${RESET}  ${GRAY}|${RESET}  ${YELLOW}${COST_FMT}${RESET}  ${GRAY}|${RESET}  ${GRAY}⏱ ${TIME_FMT}${RESET}${RATE_PART}"
