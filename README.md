# Drafter

A Mac app for a directory of Markdown drafts — the same directory, and the same
rules, as [`drafts`](../cmd/drafts).

- `*.md` at the top of the directory is the **Inbox**; `archive/` is the
  **Archive**. `<name>-notes.md` beside a draft is its notes, and is not listed.
- A draft's title is its frontmatter `title:`, else its first H1, else its
  first line. A new draft is filed under a slug of its title on first save, and
  is never renamed on its own (Rename to Match Title does that).
- Saves land on disk a second after typing stops (and on switching drafts,
  leaving the app, quitting). Each save is committed and pushed in the
  background; the directory is synced (commit, fetch, merge, push) every five
  minutes and on ⌘R. A conflicting merge is aborted and reported, never left
  behind.

The directory is `$DRAFTS_DIR`, else `~/drafts`, or whatever ⌘, chooses.

## Keys

| | |
|---|---|
| ⌘K | Go to anything: drafts by title, lines by text, `>` for commands |
| ⇧⌘K | Run command |
| ⌘N / ⌥⌘N | New draft / open notes |
| ⌘1 / ⌘2 | Inbox / Archive |
| ⌃⌘A | Archive (or move back to Inbox) |
| ⌥⌘↓ / ⌥⌘↑ | Next / previous draft |
| Return, Esc | From the list into the editor, and back |
| ⌘R | Sync now |
| ⌘+ / ⌘- / ⌘0 | Type size |

## Building

```sh
scripts/build-app.sh        # build/Drafter.app
scripts/build-app.sh run    # and launch it
swift test
```
