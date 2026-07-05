# seijaku.nvim

A fast Markdown notes manager for Neovim with filesystem associations.

## Status

Early development.

## Concept

`seijaku.nvim` manages a Markdown notes vault and lets you associate notes with files and directories in your filesystem.

A note can be global or associated with one or more filesystem paths.

## Setup

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

## Sidebar

`:SeijakuToggle` opens the current all-notes sidebar.

Local sidebar mappings:

```txt
Enter  Open selected note
n      Create global note
r      Rename selected note
D      Delete selected note
m      Toggle all/directory mode
R      Refresh
q      Close
```

The sidebar currently supports:

- `all`: all notes, sorted by last update.
- `directory`: notes associated with the current directory and annotated paths inside it.

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
