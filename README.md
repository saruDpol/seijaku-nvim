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
:SeijakuNew
:SeijakuNewForCurrent
:SeijakuList
:SeijakuRebuildIndex
```

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
