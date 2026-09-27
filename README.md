# 静寂 seijaku.nvim

> A quiet Markdown notebook for Neovim.

Seijaku keeps ordinary Markdown notes in a local vault and presents them as a
compact, keyboard-first notebook. Notes can be pinned, tagged, grouped into
notebooks and linked to any file or directory without coupling their title to
that target.

The current development version is intentionally small: an all-notes view,
notebook and tag filters, an optional calendar, one reusable preview pane,
native Neovim windows, and a JSON index. There is no database, web view,
directory mode or standalone todo model.

![Seijaku](./plugin/img_1.png)

## Install

### lazy.nvim / LazyVim

```lua
return {
  {
    "saruDpol/seijaku-nvim",
    main = "seijaku",
    lazy = false,
    opts = {
      vault_dir = "~/Notes/seijaku",
      sidebar = {
        width = "auto",
        default_mode = "all",
        default_all_sort = "updated",
      },
      editor = {
        wrap = true,
        linebreak = true,
        breakindent = true,
      },
    },
  },
}
```

### Local checkout

```lua
return {
  {
    dir = "/absolute/path/to/seijaku",
    name = "seijaku.nvim",
    main = "seijaku",
    lazy = false,
    opts = { vault_dir = "~/Notes/seijaku" },
  },
}
```

## Notes

`n` opens one native composer. Move through title, template, notebook,
associated directory or file, and tags with `j`/`k`; `Enter` edits the active
field. Tags are multi-select and notebooks can carry a colour, an optional Nerd
Font icon and an optional working directory. Choosing a notebook whose name
matches a template automatically selects that template. Path selection uses a
small filesystem browser: `h` goes to the parent, `l` enters the directory
under the cursor and `Enter` selects the highlighted file or directory.

Notes are plain Markdown. Their attributes live in the index and are rendered
in an immutable context strip above the preview instead of being written into
the document body.

Templates live in `opts.notes.templates`; a template is a list of lines, a
string, or a function. Available values are `{title}`, `{template}`,
`{notebook}`, `{date}`, `{calendar_date}`, `{target}` and `{target_name}`.

On an existing note, `a` attaches another file or directory, `T` edits its tags
and `N` assigns or clears its notebook. New notes can start attached through
`:SeijakuNewForCurrent`, `:SeijakuNewForPath`, or the composer. If an attached
path belongs below a notebook working directory, that notebook is selected by
default. Deleting or moving a target never deletes its note; Seijaku marks the
target as unavailable until it exists again.

Notebooks are projects with a name, colour, optional icon and optional working
directory. Use `:SeijakuNotebook` for the complete management menu. In the
notebook selector, `n` creates one, `r` edits it and `o` opens its working
directory in Oil. Removing a notebook leaves its notes in place and clears only
their notebook assignment.

## Sidebar

`<A-o>` toggles the sidebar by default. Opening it creates one reusable preview
beside it. Selection updates that preview instead of growing managed splits.
The preview can be closed independently: the sidebar remains stable and does
not recreate it on hover; pressing `Enter` on a note opens it again. The layout
keeps the order `editors | Oil | preview | sidebar`, while the sidebar retains
its compact width.

The `all` view uses compact cards:

- The title uses your normal editor foreground and wraps as necessary.
- A pin glyph is shown only for pinned notes.
- A coloured notebook icon prefixes the title when assigned.
- The second line shows the creation date and, when different, the brighter
  calendar date.
- The third line contains coloured tag glyphs and linked targets when present.
- Notebook and tag names stay in the selector column, so cards do not repeat
  metadata unnecessarily. Tag colours are stored in the index and can be
  adjusted manually in `index.json`.

The note list has a fixed search header above it, so scrolling cards never
hides the filter. The Markdown preview is an independent, freely resizable
window with an immutable context strip for its pin, notebook and tags. The
selector column grows only as far as its longest notebook or tag name and lists
notebooks above tags. Moving over a selector entry applies that filter;
`Enter` returns to the note list. In those panels, `n` creates an entry and `r`
edits it. Notebooks with a working directory use the target colour while
unselected.

`Tab` / `Shift-Tab` cycle `all` and notebooks forward/backward; `f` /
`F` cycle tags forward/backward. Moving inside either selector applies the
notebook or tag under the cursor immediately. `C` opens or closes the calendar
for the active filters; its month markers and day list respect both notebook
and tag.
The calendar always renders six weeks, so changing month does not resize it.
Numeric input jumps to a day.

| Key | Action |
| --- | --- |
| `j` / `k` | Move between cards (or calendar days) |
| `Enter` | Focus the persistent preview for the selected note |
| `n` | New global note; on calendar, schedules it for that day |
| `a` | Attach a file or directory to the selected note |
| `r` | Rename selected note |
| `dd` | Delete selected note |
| `p` | Pin or unpin selected note |
| `T` | Add, remove or create tags for the selected note |
| `N` | Assign or clear the selected note's notebook |
| `x` | Detach the target represented by the selected card line |
| `s` | Cycle `updated`, `date`, `created` sort |
| `Tab` / `Shift-Tab` | Next / previous notebook |
| `f` / `F` | Next / previous tag |
| `C` | Open or close the filtered calendar |
| `/` | Filter visible notes by title, notebook, tag or target |
| `g/` | Telescope live grep in the active notebook/tag scope |
| `o` | Open an attached target in Oil |
| `t` | Today |
| `[` / `]` | Previous / next month in calendar |

## Commands

```text
:SeijakuToggle
:SeijakuOpenSidebar
:SeijakuFull
:SeijakuCloseSidebar
:SeijakuModeAll
:SeijakuModeCalendar
:SeijakuToggleMode             # toggle calendar
:SeijakuNew
:SeijakuNewForCurrent
:SeijakuNewForPath {path}
:SeijakuNotebook
:SeijakuOpen {note-id}
:SeijakuAttachPath {note-id} {path}
:SeijakuDetachPath {note-id} {path}
:SeijakuRebuildIndex
:SeijakuReconcile
:SeijakuList
:SeijakuGrep
```

## Vault and synchronisation

The vault contains ordinary Markdown files in `notes/` and an `index.json`.
The index is written atomically and watched for changes from other Neovim
instances. Reconcile is available when importing existing Markdown files or
repairing a vault after external edits.

This rework uses schema 5. Loading an earlier index upgrades it and removes the
legacy todo records. Those old todo entries are deliberately not migrated:
dedicated task notes and templates replace the old model.
