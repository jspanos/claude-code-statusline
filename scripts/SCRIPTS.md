# scripts/

| script | purpose | options |
| --- | --- | --- |
| `test_task_segment.sh` | Regression test for the task-progress segment. Builds throwaway task dirs under a temp `CLAUDE_CONFIG_DIR` and asserts the rendered statusline. Touches no real Claude state. | `-v` show rendered lines, `-h` help |

```sh
./scripts/test_task_segment.sh -v
```

Run this after changing the task block in `statusline.sh`, and after a Claude
Code upgrade — the task file layout it depends on is not a public API.
