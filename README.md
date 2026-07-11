# seijaku.nvim

A fast Markdown notes manager for Neovim with filesystem associations.

## Status

Early development.

## Concept

`seijaku.nvim` manages a Markdown notes vault and lets you associate notes with files and directories in your filesystem.

A note can be global or associated with one or more filesystem paths.

## Setup

By default, the vault is created at `~/Notes/seijaku`.

```lua
require("seijaku").setup({
  vault_dir = "~/Notes/seijaku",
})
```

## Commands

```vim
:SeijakuToggle
:SeijakuOpenSidebar
:SeijakuCloseSidebar
:SeijakuModeAll
:SeijakuModeDirectory
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
```

## Sidebar

`:SeijakuToggle` opens the current notes sidebar in a vertical split. Notes opened from the sidebar are treated as part of the sidebar session and close with it.

Local sidebar mappings:

```txt
Enter  Open selected note in a horizontal split below the sidebar
a      Create note for the current filesystem context
x      Detach selected note from the current/contextual target
n      Create global note
r      Rename selected note
dd     Delete selected note
m      Toggle all/directory mode
R      Refresh
```

The sidebar currently supports:

- `all`: all notes, sorted by last update.
- `directory`: for file buffers, notes attached to the current file; for directory buffers, annotated elements inside that directory.

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
