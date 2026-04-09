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
CACHE_READ=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
CACHE_WRITE=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
COST=$(echo "$input"       | jq -r '.cost.total_cost_usd // 0')
DURATION=$(echo "$input"   | jq -r '.cost.total_duration_ms // 0')
API_DUR=$(echo "$input"    | jq -r '.cost.total_api_duration_ms // 0')
TRANSCRIPT=$(echo "$input"  | jq -r '.transcript_path // empty')
RATE_5H=$(echo "$input"    | jq -r '.rate_limits.five_hour.used_percentage // empty')
RATE_5H_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
RATE_7D=$(echo "$input"    | jq -r '.rate_limits.seven_day.used_percentage // empty')
RATE_7D_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

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

# ── Speed (output tokens/sec) ───────────────────────────────────────────────
SPEED_PART=""
if [ "$API_DUR" -gt 0 ] && [ "$OUT_TOKENS" -gt 0 ]; then
    # tokens/sec = OUT_TOKENS / (API_DUR / 1000) = OUT_TOKENS * 1000 / API_DUR
    TPS=$(( OUT_TOKENS * 1000 / API_DUR ))
    SPEED_PART=" ${DIM}(${TPS} t/s)${RESET}"
fi

# ── Token counts (human-readable k) ─────────────────────────────────────────
CTX_USED_K=$(( CTX_USED / 1000 ))
CTX_SIZE_K=$(( CTX_SIZE / 1000 ))
IN_K=$(( IN_TOKENS / 1000 ))
OUT_K=$(( OUT_TOKENS / 1000 ))
CACHE_R_K=$(( CACHE_READ / 1000 ))
CACHE_W_K=$(( CACHE_WRITE / 1000 ))
# Cache hit ratio as percentage of total context input
CACHE_PART=""
if [ "$CTX_USED" -gt 0 ] && [ "$CACHE_READ" -gt 0 ]; then
    CACHE_PCT=$(( CACHE_READ * 100 / CTX_USED ))
    CACHE_PART="  ⚡${CACHE_R_K}k(${CACHE_PCT}%)"
fi
CTX_TOKENS="${CTX_USED_K}k / ${CTX_SIZE_K}k  ↑${IN_K}k ↓${OUT_K}k${CACHE_PART}"

# ── Rate limits ──────────────────────────────────────────────────────────────
RATE_PART=""
if [ -n "$RATE_5H" ]; then
    RATE_INT=$(printf '%.0f' "$RATE_5H")
    if [ "$RATE_INT" -ge 90 ]; then
        RATE_COLOR="$RED"
    elif [ "$RATE_INT" -ge 70 ]; then
        RATE_COLOR="$YELLOW"
    elif [ "$RATE_INT" -ge 50 ]; then
        RATE_COLOR="$MAGENTA"
    else
        RATE_COLOR="$GREEN"
    fi
    RATE_PART=" ${GRAY}|${RESET} ${RATE_COLOR}plan: ${RATE_INT}%${RESET}"
    # Show 5h reset time when above 50%
    if [ "$RATE_INT" -ge 50 ] && [ -n "$RATE_5H_RESET" ]; then
        NOW=$(date +%s)
        REMAIN=$(( RATE_5H_RESET - NOW ))
        if [ "$REMAIN" -gt 0 ]; then
            RH=$(( REMAIN / 3600 ))
            RM=$(( (REMAIN % 3600) / 60 ))
            RATE_PART="${RATE_PART} ${DIM}(${RH}h${RM}m)${RESET}"
        fi
    fi
    # Show weekly when above 80%
    if [ -n "$RATE_7D" ]; then
        RATE_7D_INT=$(printf '%.0f' "$RATE_7D")
        if [ "$RATE_7D_INT" -ge 80 ]; then
            RATE_PART="${RATE_PART} ${GRAY}|${RESET} ${RED}weekly: ${RATE_7D_INT}%${RESET}"
            if [ -n "$RATE_7D_RESET" ]; then
                NOW=${NOW:-$(date +%s)}
                REMAIN_W=$(( RATE_7D_RESET - NOW ))
                if [ "$REMAIN_W" -gt 0 ]; then
                    RD=$(( REMAIN_W / 86400 ))
                    RWH=$(( (REMAIN_W % 86400) / 3600 ))
                    RATE_PART="${RATE_PART} ${DIM}(${RD}d${RWH}h)${RESET}"
                fi
            fi
        fi
    fi
fi

# ── Tool activity (from transcript) ──────────────────────────────────────────
TOOL_PART=""
TASK_PART=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # Find last tool_use (skip meta-tools)
    LAST_TOOL_LINE=$(tail -n 100 "$TRANSCRIPT" 2>/dev/null \
        | grep '"tool_use"' \
        | grep -v '"TaskCreate"\|"TaskUpdate"\|"TaskGet"\|"TaskList"\|"TaskStop"\|"TaskOutput"' \
        | tail -1)
    if [ -n "$LAST_TOOL_LINE" ]; then
        LAST_TOOL=$(echo "$LAST_TOOL_LINE" | jq -r '
            [.message.content[] | select(.type == "tool_use")][0].name // empty' 2>/dev/null)
        if [ -n "$LAST_TOOL" ]; then
            LAST_FILE=$(echo "$LAST_TOOL_LINE" | jq -r '
                [.message.content[] | select(.type == "tool_use")][0].input
                | (.file_path // .path // .pattern // empty)' 2>/dev/null)
            if [ -n "$LAST_FILE" ]; then
                LAST_FILE="${LAST_FILE##*/}"  # basename
                TOOL_PART=" ${GRAY}|${RESET} ${DIM}🔧 ${LAST_TOOL} ${LAST_FILE}${RESET}"
            else
                TOOL_PART=" ${GRAY}|${RESET} ${DIM}🔧 ${LAST_TOOL}${RESET}"
            fi
        fi
    fi

    # Task progress
    TASK_TOTAL=$(grep '"tool_use"' "$TRANSCRIPT" 2>/dev/null | grep -c '"TaskCreate"')
    if [ "$TASK_TOTAL" -gt 0 ]; then
        TASK_DONE=$(grep '"tool_use"' "$TRANSCRIPT" 2>/dev/null | grep '"TaskUpdate"' | grep -c '"completed"')
        TASK_REMAINING=$(( TASK_TOTAL - TASK_DONE ))
        # Current task: last TaskCreate subject
        CURRENT_TASK=$(grep '"tool_use"' "$TRANSCRIPT" 2>/dev/null | grep '"TaskCreate"' | tail -1 \
            | jq -r '[.message.content[] | select(.name == "TaskCreate")][0].input.subject // empty' 2>/dev/null)
        # If all done, show checkmark; otherwise show remaining
        if [ "$TASK_REMAINING" -le 0 ]; then
            TASK_PART=" ${GRAY}|${RESET} ${GREEN}✓ ${TASK_DONE}/${TASK_TOTAL} tasks${RESET}"
        else
            TASK_PART=" ${GRAY}|${RESET} ${WHITE}📋 ${TASK_DONE}/${TASK_TOTAL}${RESET}"
            if [ -n "$CURRENT_TASK" ]; then
                [ ${#CURRENT_TASK} -gt 30 ] && CURRENT_TASK="${CURRENT_TASK:0:27}..."
                TASK_PART="${TASK_PART} ${DIM}${CURRENT_TASK}${RESET}"
            fi
        fi
    fi
fi

# ── Output ───────────────────────────────────────────────────────────────────
# Line 1: model | dirs | git | tool | tasks
echo -e " ${BLUE}⬡ ${MODEL}${RESET}  ${GRAY}|${RESET}  📁 ${DIR_DISPLAY}${GIT_PART}${TOOL_PART}${TASK_PART}"
# Line 2: context bar + % + tokens | cost | time | rate limit
echo -e " ${BAR_COLOR}${BAR}${RESET} ${BAR_COLOR}${PCT}% ctx${RESET}  ${GRAY}${CTX_TOKENS}${RESET}  ${GRAY}|${RESET}  ${YELLOW}${COST_FMT}${RESET}  ${GRAY}|${RESET}  ${GRAY}⏱ ${TIME_FMT}${RESET}${SPEED_PART}${RATE_PART}"
