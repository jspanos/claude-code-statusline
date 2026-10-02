#!/bin/bash
# Per-subagent status line: shows each task's own model + context usage,
# since the main statusLine hook only ever reports the top-level session.

input=$(cat)

RESET=$'\033[0m'; DIM=$'\033[2m'
BLUE=$'\033[94m'; GREEN=$'\033[92m'; YELLOW=$'\033[93m'; RED=$'\033[91m'; GRAY=$'\033[37m'

printf '%s' "$input" | jq -r '
  .columns as $cols
  | .tasks[]
  | [
      (.id // ""),
      (.name // "agent"),
      (.model // ""),
      (.effort // ""),
      ((.contextWindowSize // 0) | tostring),
      ((.tokenCount // 0) | tostring)
    ]
  | join("\u001f")
' | while IFS=$'\x1f' read -r ID NAME MODEL EFFORT CTX_SIZE TOKENS; do
    [ -z "$ID" ] && continue

    if [ -z "$MODEL" ]; then
        CONTENT="${DIM}${NAME} · resolving model…${RESET}"
    else
        PCT=0
        if [ "${CTX_SIZE:-0}" -gt 0 ]; then
            PCT=$(( TOKENS * 100 / CTX_SIZE ))
        fi
        if   [ "$PCT" -ge 90 ]; then PCT_COLOR="$RED"
        elif [ "$PCT" -ge 70 ]; then PCT_COLOR="$YELLOW"
        else                         PCT_COLOR="$GREEN"
        fi
        TOK_K=$(( TOKENS / 1000 )); SIZE_K=$(( CTX_SIZE / 1000 ))
        EFFORT_PART=""
        [ -n "$EFFORT" ] && EFFORT_PART=" ${DIM}(${EFFORT})${RESET}"
        CONTENT="${NAME} ${GRAY}·${RESET} ${BLUE}${MODEL}${RESET}${EFFORT_PART} ${GRAY}·${RESET} ${PCT_COLOR}${PCT}% ctx${RESET} ${GRAY}(${TOK_K}k/${SIZE_K}k)${RESET}"
    fi

    jq -cn --arg id "$ID" --arg content "$CONTENT" '{id: $id, content: $content}'
done
