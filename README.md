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

## Timeline

⌘3 shows what was written lately, newest first, as the blocks that changed —
the same algorithm as `drafts -t`. Changed lines from history are mapped to
the Markdown blocks they sit in (a paragraph whole, a heading with its
section, a list item with its subtree, a nested item as its parent's line plus
its own branch, a table whole); overlapping blocks and blocks one blank line
apart are joined; and saves to nearby blocks of one draft within five minutes
fold into one entry that shows the text as it stood after that burst.
Uncommitted writing comes first. The archive is left out. Choosing an entry
opens the draft with the block flashed, and the keyboard stays in the
timeline, so ↓ reads on.

## Outline

The inspector (⌥⌘I) shows the draft's headings as a tree, marks the section
you are in as you type or scroll, and takes you there on a click or as you
arrow through it. ⇧⌘O (or `@` in ⌘K) finds a heading by name; ⌃⌘↓ and ⌃⌘↑
step through them.

## Picking up where you left off

Every draft remembers its cursor, selection and scroll, across switching
drafts and across launches; archiving or renaming a draft takes its place
along. Quitting and reopening also brings back the list you were in (and the
timeline entry), the open draft, which pane had the keyboard, the window, the
columns and the type size. This is kept in
`~/Library/Application Support/Drafter/State.json`.

The directory is `$DRAFTS_DIR`, else `~/drafts`, or whatever ⌘, chooses.

## Keys

| | |
|---|---|
| ⌘K | Go to anything: drafts by title, lines by text, `@` headings, `>` commands |
| ⇧⌘K | Run command |
| ⌘N / ⌥⌘N | New draft / open notes |
| ⌘1 / ⌘2 / ⌘3 | Inbox / Archive / Timeline |
| ⇧⌘O, ⌃⌘↓ / ⌃⌘↑ | Go to heading, next / previous heading |
| ⌥⌘I, ⌥⌘O | Show outline, move into it |
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
