# 静寂 seijaku.nvim

> A quiet Markdown notebook for Neovim.

Seijaku keeps ordinary Markdown notes in a local vault and presents them as a
compact, keyboard-first notebook. Notes can be pinned, tagged, grouped into
notebooks and linked to any file or directory without coupling their title to
that target.

The current development version is intentionally small: an all-notes view,
notebook tabs, an optional calendar, one persistent preview pane, native
Neovim windows, and a JSON index. There is no database, web view, directory
mode or standalone todo model.

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
        fold_metadata = true,
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
field. The composer stays in the same floating window while a field is being
edited or selected. Templates and notebooks are single-choice; tags are
multi-select. Notes start with generated metadata, followed by the title and
template body. The metadata stays folded when `editor.fold_metadata` is
enabled.

Templates live in `opts.notes.templates`; a template is a list of lines, a
string, or a function. Available values are `{title}`, `{template}`,
`{notebook}`, `{date}`, `{calendar_date}`, `{target}` and `{target_name}`.

Notes may be attached to files or directories through `a`,
`:SeijakuNewForCurrent`, `:SeijakuAttachPath`, or the public Lua API. Deleting
or moving a target never deletes its note; Seijaku simply marks the target as
unavailable until it exists again.

Notebooks are projects with a name, colour and optional working directory.
Use `:SeijakuNotebook` (or `b` in the sidebar) to create, edit, delete or open
their directory in Oil. Removing a notebook leaves its notes in place and
simply clears their notebook assignment.

## Sidebar

`<A-o>` toggles the sidebar by default. Opening it creates a persistent preview
window beside it. Selection updates that one preview instead of creating a
growing collection of managed splits. Closing the preview closes Seijaku too.

The `all` view uses compact cards:

- The title uses your normal editor foreground and wraps as necessary.
- A literal pin is shown only for pinned notes.
- Creation date, linked target, notebook and tags occupy only the lines they
  need.
- Tags are high-contrast colour chips; a tag colour is stored in the index and
  can be adjusted manually in `index.json`.

`Tab` cycles `all` and your notebooks. Their coloured chips are shown at the
top of the sidebar. `C` opens or closes the calendar for the active view; its
month markers and day list respect the active notebook and tag filters. The
calendar always renders six weeks, so changing month does not resize it.
Numeric input jumps to a day.

| Key | Action |
| --- | --- |
| `j` / `k` | Move between cards (or calendar days) |
| `Enter` | Focus the persistent preview for the selected note |
| `n` | New global note; on calendar, schedules it for that day |
| `a` | New note attached to the current Oil/netrw/buffer target |
| `r` | Rename selected note |
| `dd` | Delete selected note |
| `p` | Pin or unpin selected note |
| `#` | Edit note tags |
| `s` | Cycle `updated`, `date`, `created` sort |
| `F` | Cycle tag filter |
| `b` | Manage notebooks |
| `Tab` | Cycle all notes and notebooks |
| `C` | Open or close the filtered calendar |
| `/` | Telescope live grep in the active `all` scope |
| `o` | Open an attached target in Oil |
| `t` | Today |
| `[` / `]` | Previous / next month in calendar |

## Commands

```text
:SeijakuToggle
:SeijakuOpenSidebar
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
```

## Vault and synchronisation

The vault contains ordinary Markdown files in `notes/` and an `index.json`.
The index is written atomically and watched for changes from other Neovim
instances. Reconcile is available when importing existing Markdown files or
repairing a vault after external edits.

This rework uses schema 5. Loading an earlier index upgrades it and removes the
legacy todo records. Those old todo entries are deliberately not migrated:
dedicated task notes and templates replace the old model.
