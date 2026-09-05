# tkt

`tkt` is a minimal, file-based ticket system with dependency tracking. It stores tickets as Markdown files with YAML frontmatter in a `.tickets/` directory and provides a small CLI to create, link, and query tickets.

## Motivation
This tool is built to give humans using coding agents a persistent memory for long-horizon work. By storing tasks as structured tickets with dependencies, it replaces ad-hoc markdown notes with a stable graph of work, so agents can resume, prioritize, and unblock complex tasks without losing context.

## Install
- Clone the repository.
- Local to a project:
  - Copy `tkt` into your repo root and run it as `./tkt`.
- Global install (example):
  - `install -m 0755 ./tkt ~/.local/bin/tkt`
  - Ensure `~/.local/bin` is in your `PATH`.

## Requirements
- Bash 3.2 or later
- Standard Unix tools (`awk`, `sort`, `stat`, `mktemp`, `od`, etc.) on macOS or Linux
- `jq` for the `query` command

## Usage
```bash
Commands:
  create [title] [options]   Create ticket, prints ID
    -d, --description TEXT     Description text
    --design TEXT              Design notes
    --acceptance TEXT          Acceptance criteria
    -t, --type TYPE            Type: bug|feature|task|epic|chore [default: task]
    -p, --priority N           Priority 0|1|2|3|4, lowest=highest priority [default: 2]
    -a, --assignee NAME        Assignee [default: git user.name]
    --external-ref REF         External reference (e.g., gh-123, JIRA-456)
    --parent ID                Parent ticket ID
    --tags TAGS                Comma-separated tags (e.g., ui,backend,urgent)
  start <id>                 Set status to in_progress
  close <id>                 Set status to closed
  reopen <id>                Set status to open
  status <id> <status>       Update status (open in_progress closed)
  add-note <id> [text]       Append timestamped note (or pipe via stdin)
  archive                    Move closed tickets with no active connections to .tickets/archive/
  dep <id> <dep-id>          Add dependency (id depends on dep-id)
  undep <id> <dep-id>        Remove dependency
  dep tree [--full] <id>     Show tree; --full expands shared dependencies again
  dep cycle                  Find dependency cycles in unclosed tickets
  link <id> <id> [id...]     Link tickets together (symmetric)
  unlink <id> <target-id>    Remove link between tickets
  cat <id>                   View ticket
  edit <id>                  Open ticket in $EDITOR
  query [jq-filter]          Output tickets as JSON, optionally filtered
  ls [options]               List tickets (default: active)
    --ready                  Workable now: active + all deps closed
    --blocked                Stuck: active + has unclosed deps
    --closed                 Recently closed by mtime
    -a, --assignee=NAME      Filter by assignee
    --type=TYPE              Filter by type: bug|feature|task|epic|chore
    --tag=TAG                Filter by tag
    --limit=N                Limit output (closed mode only, default 20)
```

The dependency tree expands each ticket once in dependency-list order. Repeated tickets have a `(seen)` marker. Cycles have a `(cycle)` marker and are not expanded, even with `--full`.

`query` outputs one JSON object per ticket. Inline lists become JSON arrays; scalar fields, including priority, remain strings. The optional filter selects tickets:

```bash
./tkt query '.status == "open"'
./tkt query '.deps | length == 0'
```

## Storage
Without an override, `tkt` searches the current directory and its parents for `.tickets`. If none exists, it creates `.tickets` in the current directory. Set `TICKETS_DIR_PATH` to use an explicit path:

```bash
TICKETS_DIR_PATH=/path/to/tickets ./tkt ls
```

Only the initial `---` block is metadata. Supported fields are single-line text and comma-separated inline lists. This is not a full YAML parser: YAML quoting, comments, nested structures, and block scalars are not decoded. Ticket bodies can contain normal Markdown, including `---` separators.

New IDs use a project prefix and 12 random hex characters. Existing short IDs still work. Creation retries collisions and never replaces an existing ticket. Archive also refuses to replace an existing file. Archived tickets are excluded from lookup and queries; move them back to `.tickets` before reopening them.

File updates use temporary files, but edits to the same ticket are not serialized. Link updates across multiple tickets are not a transaction.

## Tests
Run `bash tests/run.sh`. Tests require `jq` and write only to temporary directories.

## Agent setup
Add this line to your `AGENTS.md` / `CLAUDE.md` / `GEMINI.md` and etc.:

```
This project uses a CLI ticket system for task management. Run `./tkt help` when you need to use it.
```

## Configuration
Edit the variables at the top of `tkt` to customize behavior:
- `TICKETS_DIR_NAME` (default: `.tickets`) - directory name used for parent search.
- `TICKETS_DIR_PATH` - optional environment override for the ticket directory.
- `VALID_STATUSES` (default: `open in_progress closed`)
- `VALID_TYPES` (default: `bug feature task epic chore`)
- `VALID_PRIORITIES` (default priorities `0 1 2 3 4`) - must be integers only (lower = higher priority).
- `DEFAULT_PRIORITY` (default `2`) - must be one of VALID_PRIORITIES.
- `DEFAULT_ISSUE_TYPE` (default: `task`) - must be one of VALID_TYPES.
