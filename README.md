# claude-code-statusline

A two-line status bar for [Claude Code](https://github.com/anthropics/claude-code) that shows model, working directory, git branch, context usage, cost, session time, and plan rate-limit usage — all at a glance.

## Preview

![Claude Code Status Bar](screenshot.png)

**Line 1** — model · working directory · git branch + staged/modified counts
**Line 2** — context bar · % used · token counts · session cost · elapsed time · plan usage

## Requirements

- Claude Code (any recent version with `statusLine` support)
- `jq` — for parsing the JSON input Claude Code passes to the script
- `git` — for branch info (already on your system)
- A terminal with 256-color / ANSI color support

Install `jq` if needed:

```bash
# macOS
brew install jq

# Debian/Ubuntu
sudo apt install jq
```

## Installation

### Automatic (recommended)

```bash
git clone https://github.com/jspanos/claude-code-statusline.git
cd claude-code-statusline
./install.sh
```

The script copies `statusline.sh` to `~/.claude/` and adds (or merges) the `statusLine` key into `~/.claude/settings.json`. Then restart Claude Code.

### Manual

1. **Copy the script** to your Claude Code config directory:

   ```bash
   cp statusline.sh ~/.claude/statusline.sh
   chmod +x ~/.claude/statusline.sh
   ```

2. **Add the `statusLine` block** to your `~/.claude/settings.json`:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh",
       "padding": 0
     }
   }
   ```

3. **Restart Claude Code** — the status bar appears immediately at the bottom of the session.

## What each field shows

| Field | Description |
|---|---|
| `⬡ Model` | The active Claude model name |
| `📁 project › cwd` | Project root and current subdirectory (collapsed when identical) |
| `⎇ branch` | Current git branch, `+N` staged, `~N` modified |
| Context bar | 12-char block bar (green → yellow → red as context fills) |
| `% ctx` | Percentage of context window used |
| `Xk / Yk` | Tokens used vs total context window size |
| `↑ ↓` | Input / output token totals for the session |
| `$X.XXXX` | Estimated session cost in USD |
| `⏱ Xm Xs` | Total session wall-clock time |
| `plan: X%` | 5-hour rate limit usage (only shown when available) |

## Customization

The script is a single self-contained Bash file — every section is clearly labeled with comments. Common tweaks:

- **Bar width** — change `BAR_WIDTH=12` to any integer
- **Color thresholds** — adjust the `PCT -ge 90` / `PCT -ge 70` conditionals
- **Remove a field** — delete or comment out the relevant `echo` segment at the bottom

## License

MIT
