---
name: clearwise-cleaner
description: Clean a Mac with Clearwise Cleaner through its MCP server — find junk, leftovers of removed apps, old and duplicate files, Docker waste, startup items and Mac health, and remove what the user approves. Use when the user asks to free disk space, clean caches, uninstall an app completely, find what takes space, or check the health of their Mac.
---

# Clearwise Cleaner (MCP)

Clearwise Cleaner is a macOS cleaner. Its MCP server `clearwise-mcp` exposes the same engines the app
uses, with the same safety rules. It runs on the user's Mac over stdio.

## Connect

The server ships inside the app: `/Applications/Clearwise Cleaner.app/Contents/MacOS/clearwise-mcp`
(or `swift build --product clearwise-mcp` from the source tree).

- Claude Code: `claude mcp add clearwise -- "/Applications/Clearwise Cleaner.app/Contents/MacOS/clearwise-mcp"`
- Claude Desktop / Cursor / any MCP client (`mcpServers` in its JSON config):
  ```json
  { "clearwise": { "command": "/Applications/Clearwise Cleaner.app/Contents/MacOS/clearwise-mcp" } }
  ```

Full Disk Access is granted to the host (Terminal, Claude, Cursor), not to the server. Without it, parts of
`~/Library`, other apps' containers and the Trash are invisible; `scan_junk` reports `full_disk_access: false`.
Tell the user: System Settings → Privacy & Security → Full Disk Access → add the host app.

## Rules

1. **Dry run first, always.** Every removing tool (`clean_junk`, `uninstall_app`, `remove_leftovers`,
   `trash_files`, `set_startup_item`, `empty_trash`) returns a plan unless `confirm: true`. Show the user
   what would go (counts, sizes, the notable items), and call again with `confirm: true` only after they
   agreed to that exact list. Never pass `confirm: true` on the first call.
2. **Nothing is lost by default.** Files go to the macOS Trash and can be put back. Two exceptions, and the
   tools say so in `destination`: `permanent` (emptying the Trash, or the «Корзина/Trash» junk category)
   and `docker` (Docker frees images and build cache at once). Say this to the user before confirming.
3. **Modes are presets, not permissions.** `gentle` ticks what apps recreate by themselves; `enhanced` adds
   what is downloaded or rebuilt again (developer caches, Docker build cache, firmware); `maximum` adds
   what is unlikely to be needed (unused Docker images, installers not opened for a month, Xcode archives
   older than half a year, older iPhone backups). No mode ever ticks the Trash, the newest backup of a
   device, or Docker volumes. Start with `gentle` unless the user asks for more.
4. **The user's own files are theirs.** `old_files`, `large_files` and `duplicates` only report. Propose,
   never pick for them; `trash_files` needs their explicit choice.
5. **Do not empty the Trash on your own.** Only when the user asks for it in so many words.
6. **Report honestly.** After a removal, quote `freed_bytes`, `in_trash_bytes`, `freed_at_once_bytes` and
   every `failed` item with its reason (an app still running, a file macOS protects, the password dialog
   cancelled). Space in the Trash is not free yet.

## Tools

| Tool | Does | Removes |
|---|---|---|
| `scan_junk` | Caches, logs, developer caches, temporary files, installers, iPhone backups, firmware, the Trash, Docker; what each mode ticks | no |
| `clean_junk` | By `mode`, `categories` or `items` from the scan | dry run → `confirm` |
| `disk_usage` | Total and free space of the startup disk | no |
| `list_apps` | Installed apps, size, last use; `unused_for_months` | no |
| `app_footprint` | One app's bundle and leftovers in Library | no |
| `uninstall_app` | App and leftovers to the Trash; `keep_data` keeps settings | dry run → `confirm` |
| `find_leftovers` | Files left by apps already removed | no |
| `remove_leftovers` | By group id or path | dry run → `confirm` |
| `old_files` / `large_files` / `duplicates` | The user's own files worth a look | no |
| `trash_files` | Chosen paths to the Trash; protected places refused | dry run → `confirm` |
| `mac_health` | Battery and SSD wear, free and purgeable space, snapshots, memory pressure, Intel-only apps | no |
| `startup_items` | Agents, daemons, login items with owner and signer | no |
| `set_startup_item` | disable (reversible) / enable / remove | dry run → `confirm` |
| `empty_trash` | Everything in the Trash, for good | dry run → `confirm` |

Sizes are bytes (`*_human` is a readable copy). Paths are absolute; Docker items use ids like
`docker-cleanup:///build-cache`. Items the system owns (root-owned logs, App Store apps in the Trash,
daemons) make macOS show its own administrator-password dialog on the Mac.

## A typical run

1. `disk_usage`, then `scan_junk` with `mode: "gentle"`: tell the user the total, the biggest categories,
   and what `gentle` would tick.
2. If they want it: `clean_junk` with the same mode (dry run), show the plan, then `confirm: true`.
3. For more space: `list_apps` with `unused_for_months: 6`, `find_leftovers`, `large_files`, `duplicates`;
   propose, let them choose, remove with the matching tool after a dry run.
4. End with what was freed, what is in the Trash, and anything that failed.
