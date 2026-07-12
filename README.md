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

`:SeijakuToggle` opens the current notes sidebar in a vertical split. Notes opened from the sidebar are treated as part of the sidebar session and close with it.

Local sidebar mappings:

```txt
Enter  Open selected note in a horizontal split below the sidebar
a      Create note for the current filesystem context
x      Detach selected note from the current/contextual target
n      Create global note
r      Rename selected note
dd     Delete selected note
Tab    Cycle all/directory/agenda mode
s      Toggle date/updated sorting in all mode
R      Refresh
```

The sidebar uses an automatically sized vertical split. Its managed horizontal
preview follows the selected note. Pressing `Enter` opens an additional fixed
note split inside the sidebar column. If the preview is closed with `:q`, it is
only recreated when a note is explicitly opened or created.

The sidebar currently supports:

- `all`: `date` groups notes by creation day; `updated` sorts them by the last
  content or metadata update. The first associated target is shown on the right.
- `directory`: exact notes for file contexts; for directory contexts, a filtered
  recursive tree containing annotated paths and the folders needed to reach them.
- `agenda`: reserved for a future agenda view.

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
