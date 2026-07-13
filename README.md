# seijaku.nvim

A fast Markdown notes manager for Neovim with filesystem associations.

## Status

Early development.

## Concept

`seijaku.nvim` manages a Markdown notes vault and lets you associate notes with files and directories in your filesystem.

A note can be global or associated with one or more filesystem paths.

## Installation

### lazy.nvim / LazyVim

Create `~/.config/nvim/lua/plugins/seijaku.lua`:

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
        default_mode = "directory",
        default_all_sort = "date",
      },
      editor = {
        wrap = true,
        linebreak = true,
        breakindent = true,
      },
      keymaps = {
        enable_default = true,
        toggle = "<A-o>",
        new_for_current = "<leader>a",
      },
    },
  },
}
```

Restart Neovim and run:

```vim
:Lazy sync
```

`lazy.nvim` clones the GitHub repository and calls
`require("seijaku").setup(opts)` automatically. Future `:Lazy sync` or
`:Lazy update seijaku-nvim` runs fetch new commits; restart Neovim after an
update so already loaded Lua modules and plugin state are recreated cleanly.

### Configuration

By default, the vault is created at `~/Notes/seijaku`. Customize the `opts`
table in the Lazy spec when needed:

```lua
opts = {
  vault_dir = "~/Notes/seijaku",
  editor = {
    wrap = true,
    linebreak = true,
    breakindent = true,
  },
  keymaps = {
    enable_default = true,
    toggle = "<A-o>",
    new_for_current = "<leader>a",
  },
}
```

Set an individual mapping to `false`, or set `enable_default = false` to
disable all global defaults.

### Local development

Add the repository as a local plugin in your Lazy specification:

```lua
{
  dir = "/home/sarudpol/main/seijaku",
  name = "seijaku.nvim",
  lazy = false,
  opts = {
    vault_dir = "~/Notes/seijaku",
  },
}
```

`lazy.nvim` automatically calls `require("seijaku").setup(opts)`, so no manual
`runtimepath` or command-line setup is needed. Because this uses `dir`, edits in
this repository are already visible and do not need `:Lazy sync`. Restart Neovim
after changing Lua code: `:Lazy sync` does not unload modules already cached in
`package.loaded` in the current session.

## Commands

```vim
:SeijakuToggle
:SeijakuOpenSidebar
:SeijakuCloseSidebar
:SeijakuModeAll
:SeijakuModeDirectory
:SeijakuModeCalendar
:SeijakuToggleMode
:SeijakuNew
:SeijakuNewForCurrent
:SeijakuNewForPath
:SeijakuAttachPath
:SeijakuDetachPath
:SeijakuOpen
:SeijakuList
:SeijakuRebuildIndex
```

Default keymap:

```txt
Alt-o       Toggle Seijaku sidebar
<leader>a   Create a note for the current buffer
```

## Sidebar

`:SeijakuToggle` opens the current notes sidebar in a real vertical split, using
`directory` mode by default. The main window is resized together with the
sidebar. Notes opened from the sidebar are treated as part of the sidebar
session and close with it.

Local sidebar mappings:

```txt
Enter  Open selected note in a horizontal split below the sidebar
a      Create note for the current filesystem context
x      Detach selected note from the current/contextual target
n      Create global note
r      Rename selected note
dd     Delete selected note
Tab    Cycle all/directory/calendar mode
s      Cycle date/updated/created sorting in all mode
R      Refresh
```

The sidebar uses an automatically sized vertical split. Its managed horizontal
preview follows the selected note and uses a normal `belowright split`; Neovim
distributes it naturally together with calendar and additional note windows.
Pressing `Enter` opens an additional note split inside the sidebar column. If
the preview is closed with `:q`, it is only recreated when a note is explicitly
opened, created, or a new sidebar mode is selected.

Automatic sidebar width is bounded between 44 and 56 columns. A fixed numeric
width can still be set with `sidebar.width`.

Note previews and editor splits use soft wrapping by default: long Markdown
lines continue visually on the next screen line, preferably at word boundaries,
without inserting newline characters into the file. These window-local options
can be disabled with `editor.wrap = false` and do not affect Markdown buffers
outside Seijaku.

All existing filesystem files can be note targets regardless of their
extension, including office and binary files. In an `oil.nvim` buffer, the item
under the cursor is used only as the target for association actions. The
`directory` view itself always follows Oil's open directory and includes notes
from that directory and its descendants. The current directory is used as the
association fallback when no item is selected.

New notes include a compact generated header before the title with their
creation time, last update time, associated targets, and explicit calendar date
when scheduled. This visible header is kept in sync when the note is saved or
its metadata changes; `index.json` remains the source of truth.

If the main window is closed while the sidebar remains open, toggling the
sidebar off replaces that last sidebar window with an empty normal buffer.

The sidebar currently supports:

- `all`: `date` groups notes by their effective calendar date (`calendar_date`,
  falling back to `created_at`); `updated` sorts by the last content or metadata
  update; `created` groups strictly by creation day. Press `s` to cycle them.
  The first associated target is shown on the right with extra space reserved
  for its filename or directory name.
- `directory`: exact notes for file contexts; for directory contexts, a filtered
  recursive tree containing annotated paths and the folders needed to reach them.
- `calendar`: a monthly Gregorian calendar and a separate notes window for the
  selected day. Notes without an explicit calendar date use their creation day.

### Calendar

Calendar mode uses two real Neovim windows in the sidebar column. The upper
window renders any month from year 1 through 9999; the lower window lists notes
for the selected day. Use normal `<C-w>j` and `<C-w>k` window navigation to move
between them. The lower window starts directly with the notes, without a title
or separator line.

The first note for the selected day opens in the managed preview by default,
and moving through the day-notes window updates that preview. A day without
notes closes a clean preview; a manually closed preview stays closed. Every
sidebar mode change resets panel cursors and scrolling to the first line and
recreates the preview from the first available note in the destination mode.

Calendar window mappings:

```txt
h/l or Left/Right  Previous/next day
j/k or Down/Up     Next/previous week
[/]                Previous/next month
gg/G               First/last day of the month
t                  Today
Enter              Focus the notes window
a                  Create contextual note for selected day
n                  Create global note for selected day
```

Day-notes window mappings:

```txt
j/k    Navigate notes normally
Enter  Open selected note
a/n    Create contextual/global note for selected day
x      Clear the selected note's explicit calendar date
r      Rename selected note
dd     Delete selected note after confirmation
Tab    Cycle to the next sidebar mode
R      Refresh calendar and day notes
```

Notes created from calendar mode store `calendar_date` in `index.json` and show
it as `Date` in their generated Markdown header. Clearing it makes the note fall
back to its creation day in the calendar.

## Vault structure

```txt
~/Notes/seijaku/
├── index.json
├── notes/
└── backups/
```

## Design

- Notes are Markdown files.
- Metadata lives in `index.json`.
- Note IDs are independent from filesystem paths.
- One path can have many notes.
- One note can be attached to many paths.
- Notes can exist without any target.
