#!/usr/bin/env bash
# Regression test for the statusline's task-progress segment.
#
# Builds throwaway task directories under a temp CLAUDE_CONFIG_DIR, runs
# statusline.sh against each, and checks the rendered first line. Touches no
# real Claude state.
#
# Usage:
#   ./scripts/test_task_segment.sh          # run all cases
#   ./scripts/test_task_segment.sh -v       # also print the rendered line
#
# Options:
#   -v, --verbose   show the full statusline output for each case
#   -h, --help      this text
set -euo pipefail

VERBOSE=0
case "${1:-}" in
-v | --verbose) VERBOSE=1 ;;
-h | --help)
	sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
	;;
esac

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUSLINE="$REPO/statusline.sh"
SESSION="deadbeef-0000-4000-8000-000000000000"
SHORT="deadbeef"

FIXTURE="$(mktemp -d -t sl-task-test)"
TASK_DIR="$FIXTURE/tasks/session-$SHORT"
mkdir -p "$TASK_DIR"
trap 'rm -rf "$FIXTURE"' EXIT

task() { # task <id> <status> <subject> [extra-json]
	local id="$1" status="$2" subject="$3" extra="${4:-}"
	local body="{\"id\":\"$id\",\"subject\":\"$subject\",\"description\":\"d\""
	body="$body,\"status\":\"$status\",\"blocks\":[],\"blockedBy\":[]"
	[ -n "$extra" ] && body="$body,$extra"
	printf '%s}\n' "$body" >"$TASK_DIR/$id.json"
}

render() {
	# Braces matter: without them only the final printf would be piped.
	{
		printf '{"model":{"display_name":"Opus 5"},'
		printf '"workspace":{"current_dir":"%s"},' "$REPO"
		printf '"context_window":{"used_percentage":10,"current_usage":{"input_tokens":1}},'
		printf '"cost":{"total_cost_usd":0.1,"total_duration_ms":1000},'
		printf '"session_id":"%s"}\n' "$SESSION"
	} | CLAUDE_CONFIG_DIR="$FIXTURE" bash "$STATUSLINE" | head -1
}

PASS=0
FAIL=0
check() { # check <name> <expected-substring> [must-not-contain]
	local name="$1" want="$2" avoid="${3:-}"
	local out plain
	out="$(render)"
	plain="$(printf '%s' "$out" | sed $'s/\033\[[0-9;]*m//g')"
	[ "$VERBOSE" = 1 ] && printf '    %s\n' "$plain"

	if [[ "$plain" != *"$want"* ]]; then
		printf '  FAIL  %s\n        want substring: %s\n        got: %s\n' \
			"$name" "$want" "$plain"
		FAIL=$((FAIL + 1))
		return
	fi
	if [ -n "$avoid" ] && [[ "$plain" == *"$avoid"* ]]; then
		printf '  FAIL  %s\n        must not contain: %s\n        got: %s\n' \
			"$name" "$avoid" "$plain"
		FAIL=$((FAIL + 1))
		return
	fi
	printf '  ok    %s\n' "$name"
	PASS=$((PASS + 1))
}

reset() { rm -f "$TASK_DIR"/*.json; }

echo "task-progress segment"

reset
task 1 completed "Set up Postgres"
task 2 in_progress "Wire the ingestion worker" '"activeForm":"Wiring the ingestion worker"'
task 3 pending "Add rate limiting"
check "counts done/total" "1/3"
check "labels the in-progress task by activeForm" "Wiring the ingestion worker"

reset
task 1 completed "Set up Postgres"
task 2 in_progress "Wire the worker"
check "falls back to subject when activeForm is absent" "Wire the worker"

reset
task 1 completed "Set up Postgres"
task 2 pending "Add rate limiting"
task 3 completed "Retired idea" '"metadata":{"obsolete":true}'
check "obsolete drops out of both numerator and denominator" "1/2"

reset
task 1 completed "Set up Postgres"
task 2 completed "Scrape listings"
check "all complete renders the done form" "2/2 tasks"

reset
task 1 completed "Only task"
task 2 completed "Retired" '"metadata":{"obsolete":true}'
check "obsolete does not block the all-complete form" "1/1 tasks"

reset
check "empty task dir renders no task segment" "⬡ Opus 5" "📋"

reset
task 1 pending "Check the completed run"
check "the word 'completed' in a subject is not counted as done" "0/1"

rm -rf "$FIXTURE/tasks/session-$SHORT"
check "missing task dir renders no task segment" "⬡ Opus 5" "📋"
mkdir -p "$TASK_DIR"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
