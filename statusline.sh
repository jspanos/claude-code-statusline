#!/bin/bash
# Claude Code Status Line — optimized for low CPU/battery
#
# Optimizations vs. previous version:
#   • Single jq call (TSV parse) instead of 20 forks per redraw
#   • Single git invocation (porcelain=2 --branch) instead of 3
#   • OTLP drain throttled to ≥60s between attempts (was: every redraw)
#   • Transcript scan cached by mtime sidecar (was: 4 full-file greps per redraw)
#   • CSV write is single append; sort/merge only triggered on spill recovery

input=$(cat)

# ── Single jq parse: emit all fields as TSV ─────────────────────────────────
IFS=$'\t' read -r MODEL PROJECT CWD PCT CTX_SIZE CTX_USED IN_TOKENS OUT_TOKENS \
  CACHE_READ CACHE_WRITE COST DURATION API_DUR TRANSCRIPT \
  RATE_5H RATE_5H_RESET RATE_7D RATE_7D_RESET SESSION_ID < <(
  printf '%s' "$input" | jq -r '
    def s($v): ($v // "" | tostring);
    def n($v): ($v // 0 | tostring);
    [ (.model.display_name // "unknown")
    , (.workspace.project_dir // .cwd // "")
    , (.workspace.current_dir // .cwd // "")
    , ((.context_window.used_percentage // 0) | floor | tostring)
    , n(.context_window.context_window_size // 200000)
    , ((.context_window.current_usage |
        if . == null then 0
        else (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)
        end) | tostring)
    , n(.context_window.total_input_tokens // .context_window.current_usage.input_tokens // 0)
    , n(.context_window.total_output_tokens // .context_window.current_usage.output_tokens // 0)
    , n(.context_window.current_usage.cache_read_input_tokens // 0)
    , n(.context_window.current_usage.cache_creation_input_tokens // 0)
    , n(.cost.total_cost_usd // 0)
    , n(.cost.total_duration_ms // 0)
    , n(.cost.total_api_duration_ms // 0)
    , (.transcript_path // "")
    , s(.rate_limits.five_hour.used_percentage)
    , s(.rate_limits.five_hour.resets_at)
    , s(.rate_limits.seven_day.used_percentage)
    , s(.rate_limits.seven_day.resets_at)
    , (.session_id // "unknown")
    ] | @tsv'
)

# ── CSV logging (single append; merge only when recovering from spill) ──────
CSV_DIR="$HOME/.claude/usage-logs"
CSV_FILE="$CSV_DIR/usage_$(date +%Y-%m).csv"
CSV_LOCKDIR="$CSV_DIR/.lock.d"
CSV_SPILL="$CSV_DIR/.spill"
CSV_HEADER="timestamp,session_id,model,context_pct,context_used,context_size,in_tokens,out_tokens,cache_read,cache_write,cost_usd,duration_ms,api_duration_ms,rate_5h_pct,rate_5h_resets_at,rate_7d_pct,rate_7d_resets_at"
mkdir -p "$CSV_DIR"
CSV_ROW="$(date -u +%Y-%m-%dT%H:%M:%SZ),${SESSION_ID},${MODEL},${PCT},${CTX_USED},${CTX_SIZE},${IN_TOKENS},${OUT_TOKENS},${CACHE_READ},${CACHE_WRITE},${COST},${DURATION},${API_DUR},${RATE_5H},${RATE_5H_RESET},${RATE_7D},${RATE_7D_RESET}"

if mkdir "$CSV_LOCKDIR" 2>/dev/null; then
    [ ! -f "$CSV_FILE" ] && echo "$CSV_HEADER" > "$CSV_FILE"
    if [ -s "$CSV_SPILL" ]; then
        { tail -n +2 "$CSV_FILE"; cat "$CSV_SPILL"; echo "$CSV_ROW"; } \
            | sort -t, -k1,1 > "$CSV_DIR/.merge_tmp"
        { echo "$CSV_HEADER"; cat "$CSV_DIR/.merge_tmp"; } > "$CSV_FILE"
        rm -f "$CSV_DIR/.merge_tmp" "$CSV_SPILL"
    else
        echo "$CSV_ROW" >> "$CSV_FILE"
    fi
    rmdir "$CSV_LOCKDIR" 2>/dev/null
else
    echo "$CSV_ROW" >> "$CSV_SPILL"
fi

# ── OTLP metrics (spool always, drain at most every 60s) ────────────────────
[ -f "$HOME/.claude/otelhub.env" ] && . "$HOME/.claude/otelhub.env"
OTLP_ENDPOINT="${OTELHUB_URL:-${OTEL_EXPORTER_OTLP_ENDPOINT:-}}"
if [ -n "$OTLP_ENDPOINT" ] && [ -n "${OTELHUB_TOKEN:-}" ] && command -v curl >/dev/null 2>&1; then
    TS_NS="$(date +%s)000000000"
    PROJECT_BASENAME="${PROJECT##*/}"
    OTLP_SPOOL_DIR="${OTELHUB_SPOOL_DIR:-$CSV_DIR/.otlp-spool}"
    OTLP_SPOOL_MAX="${OTELHUB_SPOOL_MAX:-5000}"
    OTLP_DRAIN_MIN_INTERVAL="${OTELHUB_DRAIN_INTERVAL:-60}"
    mkdir -p "$OTLP_SPOOL_DIR"

    OTLP_PAYLOAD=$(jq -cn \
        --arg session "$SESSION_ID" --arg model "$MODEL" \
        --arg project "$PROJECT_BASENAME" --arg ts "$TS_NS" \
        --argjson pct "${PCT:-0}" --argjson ctx_used "${CTX_USED:-0}" \
        --argjson ctx_size "${CTX_SIZE:-0}" --argjson in_tokens "${IN_TOKENS:-0}" \
        --argjson out_tokens "${OUT_TOKENS:-0}" --argjson cache_read "${CACHE_READ:-0}" \
        --argjson cache_write "${CACHE_WRITE:-0}" --argjson cost "${COST:-0}" \
        --argjson duration "${DURATION:-0}" --argjson api_dur "${API_DUR:-0}" \
        --arg rate5h "${RATE_5H}" --arg rate7d "${RATE_7D}" '
        def strAttr($k; $v): {key:$k, value:{stringValue:$v}};
        def gauge($n; $u; $v): {name:$n, unit:$u, gauge:{dataPoints:[{timeUnixNano:$ts, asDouble:$v}]}};
        def optGauge($n; $u; $s):
            if $s == "" or $s == null then empty
            else gauge($n; $u; ($s|tonumber)) end;
        {resourceMetrics:[{
          resource:{attributes:[
            strAttr("service.name";"claude-code"),
            strAttr("session.id";$session),
            strAttr("claude.model";$model),
            strAttr("claude.project";$project)]},
          scopeMetrics:[{
            scope:{name:"claude-code-statusline", version:"1"},
            metrics:[
              gauge("claude.context.used_percentage";"%";$pct),
              gauge("claude.context.used_tokens";"tokens";$ctx_used),
              gauge("claude.context.window_size";"tokens";$ctx_size),
              gauge("claude.tokens.input";"tokens";$in_tokens),
              gauge("claude.tokens.output";"tokens";$out_tokens),
              gauge("claude.tokens.cache_read";"tokens";$cache_read),
              gauge("claude.tokens.cache_write";"tokens";$cache_write),
              gauge("claude.cost.usd";"USD";$cost),
              gauge("claude.duration.total_ms";"ms";$duration),
              gauge("claude.duration.api_ms";"ms";$api_dur),
              optGauge("claude.rate_limit.5h_pct";"%";$rate5h),
              optGauge("claude.rate_limit.7d_pct";"%";$rate7d)]}]}]}')

    printf '%s' "$OTLP_PAYLOAD" > "$OTLP_SPOOL_DIR/$(date +%s)-$$-$RANDOM.json"

    # Throttle drain: only spawn a drain subshell if last drain was ≥ N seconds ago.
    # Marker file mtime is the gate; the drain refreshes it on entry.
    DRAIN_MARKER="$OTLP_SPOOL_DIR/.last-drain"
    NOW_EPOCH=$(date +%s)
    LAST_DRAIN=0
    [ -f "$DRAIN_MARKER" ] && LAST_DRAIN=$(stat -f %m "$DRAIN_MARKER" 2>/dev/null || echo 0)
    if [ $(( NOW_EPOCH - LAST_DRAIN )) -ge "$OTLP_DRAIN_MIN_INTERVAL" ]; then
        touch "$DRAIN_MARKER"
        OTLP_URL="${OTLP_ENDPOINT%/}/v1/metrics"
        (
            DRAIN_LOCK="$OTLP_SPOOL_DIR/.drain.lock"
            if mkdir "$DRAIN_LOCK" 2>/dev/null; then
                trap 'rmdir "$DRAIN_LOCK" 2>/dev/null' EXIT
                # Cap spool size (cheap: only run when over cap)
                SPOOL_COUNT=$(find "$OTLP_SPOOL_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
                if [ "$SPOOL_COUNT" -gt "$OTLP_SPOOL_MAX" ]; then
                    find "$OTLP_SPOOL_DIR" -maxdepth 1 -name '*.json' \
                        | sort | head -n $(( SPOOL_COUNT - OTLP_SPOOL_MAX )) \
                        | xargs rm -f 2>/dev/null
                fi
                find "$OTLP_SPOOL_DIR" -maxdepth 1 -name '*.json' | sort | while read -r f; do
                    [ -f "$f" ] || continue
                    if curl -sS -m 3 --fail -X POST "$OTLP_URL" \
                        -H "Authorization: Bearer ${OTELHUB_TOKEN}" \
                        -H "Content-Type: application/json" \
                        --data @"$f" >/dev/null 2>&1; then
                        rm -f "$f"
                    else
                        break
                    fi
                done
            fi
        ) >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi
fi

# ── Colors ──────────────────────────────────────────────────────────────────
RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
GRAY='\033[37m'; CYAN='\033[96m'; BLUE='\033[94m'
GREEN='\033[92m'; YELLOW='\033[93m'; RED='\033[91m'
MAGENTA='\033[95m'; WHITE='\033[97m'

# ── Folders ─────────────────────────────────────────────────────────────────
PROJECT_NAME="${PROJECT##*/}"
CWD_NAME="${CWD##*/}"
if [ "$PROJECT" = "$CWD" ] || [ -z "$CWD_NAME" ]; then
    DIR_DISPLAY="${CYAN}${BOLD}${PROJECT_NAME}${RESET}"
else
    DIR_DISPLAY="${CYAN}${PROJECT_NAME}${RESET} ${GRAY}›${RESET} ${CYAN}${BOLD}${CWD_NAME}${RESET}"
fi

# ── Git (single porcelain=2 --branch call) ──────────────────────────────────
GIT_PART=""
GIT_OUT=$(git -C "$CWD" status --porcelain=2 --branch 2>/dev/null)
if [ -n "$GIT_OUT" ]; then
    BRANCH=$(printf '%s\n' "$GIT_OUT" | awk '/^# branch.head/ {print $3; exit}')
    if [ -n "$BRANCH" ] && [ "$BRANCH" != "(detached)" ]; then
        # porcelain=2: lines starting with "1 " or "2 " are tracked changes.
        # Field 2 (XY) — X=staged, Y=worktree. '.' means unchanged.
        STAGED=$(printf '%s\n' "$GIT_OUT" | awk '/^[12] / && substr($2,1,1) != "." {c++} END {print c+0}')
        MODIFIED=$(printf '%s\n' "$GIT_OUT" | awk '/^[12] / && substr($2,2,1) != "." {c++} END {print c+0}')
        GIT_PART=" ${GRAY}|${RESET} ${GREEN}⎇ ${BRANCH}${RESET}"
        [ "$STAGED"   -gt 0 ] && GIT_PART="${GIT_PART} ${GREEN}+${STAGED}${RESET}"
        [ "$MODIFIED" -gt 0 ] && GIT_PART="${GIT_PART} ${YELLOW}~${MODIFIED}${RESET}"
    fi
fi

# ── Context bar ─────────────────────────────────────────────────────────────
BAR_WIDTH=12
FILLED=$(( PCT * BAR_WIDTH / 100 ))
EMPTY=$(( BAR_WIDTH - FILLED ))
if   [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else                         BAR_COLOR="$GREEN"
fi
BAR=""
[ "$FILLED" -gt 0 ] && printf -v F "%${FILLED}s" && BAR="${F// /█}"
[ "$EMPTY"  -gt 0 ] && printf -v E "%${EMPTY}s"  && BAR="${BAR}${E// /░}"

COST_FMT=$(printf '$%.4f' "$COST")
SECS=$(( DURATION / 1000 )); MINS=$(( SECS / 60 )); SECS=$(( SECS % 60 ))
TIME_FMT="${MINS}m ${SECS}s"

SPEED_PART=""
if [ "$API_DUR" -gt 0 ] && [ "$OUT_TOKENS" -gt 0 ]; then
    TPS=$(( OUT_TOKENS * 1000 / API_DUR ))
    SPEED_PART=" ${DIM}(${TPS} t/s)${RESET}"
fi

CTX_USED_K=$(( CTX_USED / 1000 ))
CTX_SIZE_K=$(( CTX_SIZE / 1000 ))
IN_K=$(( IN_TOKENS / 1000 ))
OUT_K=$(( OUT_TOKENS / 1000 ))
CACHE_R_K=$(( CACHE_READ / 1000 ))
CACHE_PART=""
if [ "$CTX_USED" -gt 0 ] && [ "$CACHE_READ" -gt 0 ]; then
    CACHE_PCT=$(( CACHE_READ * 100 / CTX_USED ))
    CACHE_PART="  ⚡${CACHE_R_K}k(${CACHE_PCT}%)"
fi
CTX_TOKENS="${CTX_USED_K}k / ${CTX_SIZE_K}k  ↑${IN_K}k ↓${OUT_K}k${CACHE_PART}"

# ── Rate limits ─────────────────────────────────────────────────────────────
RATE_PART=""
if [ -n "$RATE_5H" ]; then
    RATE_INT=$(printf '%.0f' "$RATE_5H")
    if   [ "$RATE_INT" -ge 90 ]; then RATE_COLOR="$RED"
    elif [ "$RATE_INT" -ge 70 ]; then RATE_COLOR="$YELLOW"
    elif [ "$RATE_INT" -ge 50 ]; then RATE_COLOR="$MAGENTA"
    else                              RATE_COLOR="$GREEN"
    fi
    RATE_PART=" ${GRAY}|${RESET} ${RATE_COLOR}plan: ${RATE_INT}%${RESET}"
    if [ "$RATE_INT" -ge 50 ] && [ -n "$RATE_5H_RESET" ]; then
        NOW=$(date +%s)
        REMAIN=$(( RATE_5H_RESET - NOW ))
        if [ "$REMAIN" -gt 0 ]; then
            RH=$(( REMAIN / 3600 )); RM=$(( (REMAIN % 3600) / 60 ))
            RATE_PART="${RATE_PART} ${DIM}(${RH}h${RM}m)${RESET}"
        fi
    fi
    if [ -n "$RATE_7D" ]; then
        RATE_7D_INT=$(printf '%.0f' "$RATE_7D")
        if [ "$RATE_7D_INT" -ge 80 ]; then
            RATE_PART="${RATE_PART} ${GRAY}|${RESET} ${RED}weekly: ${RATE_7D_INT}%${RESET}"
            if [ -n "$RATE_7D_RESET" ]; then
                NOW=${NOW:-$(date +%s)}
                REMAIN_W=$(( RATE_7D_RESET - NOW ))
                if [ "$REMAIN_W" -gt 0 ]; then
                    RD=$(( REMAIN_W / 86400 )); RWH=$(( (REMAIN_W % 86400) / 3600 ))
                    RATE_PART="${RATE_PART} ${DIM}(${RD}d${RWH}h)${RESET}"
                fi
            fi
        fi
    fi
fi

# ── Tool activity + Task progress (cached by transcript mtime) ──────────────
TOOL_PART=""; TASK_PART=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    CACHE_FILE="$CSV_DIR/.transcript-cache-${SESSION_ID}.tsv"
    T_MTIME=$(stat -f %m "$TRANSCRIPT" 2>/dev/null || echo 0)
    C_MTIME=0
    [ -f "$CACHE_FILE" ] && C_MTIME=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)

    # Recompute only if transcript changed since cache (mtime is monotonic for append-only files)
    if [ "$T_MTIME" -gt "$C_MTIME" ]; then
        # Single awk pass through transcript: track last tool_use, count TaskCreate/TaskUpdate completed
        awk '
            /"tool_use"/ {
                if (match($0, /"name":"[^"]+"/)) {
                    name = substr($0, RSTART+8, RLENGTH-9)
                    if (name == "TaskCreate") {
                        tc++
                        if (match($0, /"subject":"[^"]*"/)) {
                            current_task = substr($0, RSTART+11, RLENGTH-12)
                        }
                    } else if (name == "TaskUpdate") {
                        if (index($0, "\"completed\"") > 0) tu_done++
                    } else if (name != "TaskGet" && name != "TaskList" && name != "TaskStop" && name != "TaskOutput") {
                        last_tool = name
                        last_input = $0
                    }
                }
            }
            END {
                # Extract file/path/pattern from last_input
                last_file = ""
                if (last_input != "") {
                    if (match(last_input, /"file_path":"[^"]+"/)) last_file = substr(last_input, RSTART+13, RLENGTH-14)
                    else if (match(last_input, /"path":"[^"]+"/)) last_file = substr(last_input, RSTART+8, RLENGTH-9)
                    else if (match(last_input, /"pattern":"[^"]+"/)) last_file = substr(last_input, RSTART+11, RLENGTH-12)
                    n = split(last_file, parts, "/")
                    if (n > 0) last_file = parts[n]
                }
                printf "%s\t%s\t%d\t%d\t%s\n", last_tool, last_file, tc+0, tu_done+0, current_task
            }
        ' "$TRANSCRIPT" > "$CACHE_FILE" 2>/dev/null
    fi

    if [ -f "$CACHE_FILE" ]; then
        IFS=$'\t' read -r LAST_TOOL LAST_FILE TASK_TOTAL TASK_DONE CURRENT_TASK < "$CACHE_FILE"
        if [ -n "$LAST_TOOL" ]; then
            if [ -n "$LAST_FILE" ]; then
                TOOL_PART=" ${GRAY}|${RESET} ${DIM}🔧 ${LAST_TOOL} ${LAST_FILE}${RESET}"
            else
                TOOL_PART=" ${GRAY}|${RESET} ${DIM}🔧 ${LAST_TOOL}${RESET}"
            fi
        fi
        if [ "${TASK_TOTAL:-0}" -gt 0 ]; then
            TASK_REMAINING=$(( TASK_TOTAL - TASK_DONE ))
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
fi

# ── Output ──────────────────────────────────────────────────────────────────
echo -e " ${BLUE}⬡ ${MODEL}${RESET}  ${GRAY}|${RESET}  📁 ${DIR_DISPLAY}${GIT_PART}${TOOL_PART}${TASK_PART}"
echo -e " ${BAR_COLOR}${BAR}${RESET} ${BAR_COLOR}${PCT}% ctx${RESET}  ${GRAY}${CTX_TOKENS}${RESET}  ${GRAY}|${RESET}  ${YELLOW}${COST_FMT}${RESET}  ${GRAY}|${RESET}  ${GRAY}⏱ ${TIME_FMT}${RESET}${SPEED_PART}${RATE_PART}"
