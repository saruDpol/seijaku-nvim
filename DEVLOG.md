# Devlog - 2026-07-05

## Estat actual

`seijaku.nvim` ja te una primera base funcional per gestionar notes Markdown amb associacions a paths del filesystem.

El plugin esta organitzat com a plugin Lua de Neovim:

```txt
lua/
└── seijaku/
    ├── init.lua
    ├── config.lua
    ├── state.lua
    ├── util.lua
    ├── paths.lua
    ├── index.lua
    ├── notes.lua
    ├── context.lua
    ├── commands.lua
    ├── autocmds.lua
    └── sidebar.lua
plugin/
└── seijaku.lua
```

L'entrypoint public es:

```lua
require("seijaku").setup(opts)
```

Per defecte el vault es crea a:

```lua
vim.fn.stdpath("data") .. "/seijaku"
```

L'usuari tambe pot configurar-lo:

```lua
require("seijaku").setup({
  vault_dir = "~/Notes/seijaku",
})
```

## Implementat

### Core del vault

- Creacio del directori del vault.
- Creacio de `index.json`.
- Creacio de:
  - `notes/`
  - `backups/canonical/`
  - `backups/snapshots/`
- Carrega de `index.json` a memoria.
- Guardat de l'index amb debounce.
- Guardat sincron en `VimLeavePre`.
- Escriptura atomica de `index.json` amb fitxer temporal i rename.

### Model de notes

- Notes Markdown normals.
- Metadata a `index.json`.
- `note_id` independent del path.
- Notes guardades a:

```txt
notes/YYYY/MM/DD/<note_id>.md
```

- Notes globals sense target.
- Notes associades a un o mes paths.
- Un path pot tenir multiples notes.
- Una nota pot tenir multiples targets.

### Comandes disponibles

```vim
:SeijakuToggle
:SeijakuOpenSidebar
:SeijakuCloseSidebar
:SeijakuModeAll
:SeijakuModeDirectory
:SeijakuToggleMode
:SeijakuNew
:SeijakuNewForCurrent
:SeijakuNewForPath {path}
:SeijakuAttachPath {note_id} {path}
:SeijakuDetachPath {note_id} {path}
:SeijakuOpen {note_id}
:SeijakuList
:SeijakuRebuildIndex
```

### Sidebar

Ja existeix una sidebar basica a `lua/seijaku/sidebar.lua`.

Modes implementats:

- `all`: mostra totes les notes ordenades per `updated_at`.
- `directory`: mostra notes associades al directori actual i als paths anotats dins aquest directori.

Mappings locals de la sidebar:

```txt
Enter  obrir nota
n      crear nota global
r      renombrar nota
D      eliminar nota
m      alternar all/directory
R      refrescar
q      tancar
```

La sidebar renderitza des de la metadata en memoria, no llegint tots els Markdown.

### Context

El context actual suporta buffers normals.

S'ha corregit un bug important:

- Si el focus esta a la sidebar, el mode `directory` conserva l'ultim context real.
- Si el focus esta dins el Markdown d'una nota, el plugin resol la nota cap al seu target associat i mostra el directori del fitxer/directori anotat, no el directori intern del vault.

Per fer aixo, l'estat ara manté:

- `context.last`
- `notes_by_file`

## Validacions fetes

S'han fet proves amb Neovim headless per comprovar:

- `require("seijaku")` carrega correctament.
- `setup()` crea el vault.
- `:SeijakuNewForPath` crea notes associades a directoris.
- `:SeijakuToggle` obre la sidebar.
- `:SeijakuModeDirectory` mostra notes del directori correcte.
- El focus a la sidebar no trenca el context.
- Obrir el Markdown d'una nota no canvia el mode directory cap al directori intern del vault.

## Com provar manualment

Des del repo:

```bash
cd /home/sarudpol/main/seijaku
nvim -u NONE
```

Dins Neovim:

```vim
:set rtp+=/home/sarudpol/main/seijaku
:lua require("seijaku").setup({ vault_dir = "/tmp/seijaku-test" })
```

Crear una nota global:

```vim
:SeijakuNew
```

Crear una nota associada a un fitxer:

```vim
:edit /tmp/project/src/auth.lua
:write
:SeijakuNewForCurrent
```

Obrir la sidebar:

```vim
:SeijakuToggle
```

Canviar a mode directory:

```vim
:SeijakuModeDirectory
```

Crear una nota associada directament a un directori:

```vim
:SeijakuNewForPath /tmp/project/src
```

## Per on continuar

### Seguent fase recomanada: accions contextuals des de sidebar

Implementar:

```txt
a  crear nota associada al target/context actual
x  detach selected note from current target
```

Objectiu:

- Si l'usuari esta editant un fitxer, `a` crea una nota associada a aquell fitxer.
- Si l'usuari esta en mode directory, `x` treu nomes l'associacio amb el target/context actual.
- La nota no s'elimina si encara existeix com a nota global o associada a altres paths.

### Despres

1. Millorar render del mode `directory`.
   - Mostrar millor el target actual.
   - Distingir visualment directori, fitxer i notes.
   - Evitar linies buides sobreres.

2. Implementar adapter `oil.nvim`.
   - Detectar buffer oil.
   - Obtenir directori actual.
   - Obtenir item sota cursor.
   - Crear notes associades a fitxers/directoris des d'oil.

3. Implementar adapter `netrw`.
   - Suport best-effort.
   - Fallback al directori actual si no es pot detectar l'item.

4. Implementar Telescope.
   - `:SeijakuFind`.
   - Cerca per titol.
   - Fallback amb `vim.ui.select`.

5. Implementar backups.
   - `:SeijakuBackup`.
   - Backup automatic a `backups/canonical/seijaku-latest.tar.gz`.
   - Snapshots manuals a `backups/snapshots/`.

6. Afegir tests.
   - `paths_spec.lua`
   - `index_spec.lua`
   - `notes_spec.lua`

## Notes de disseny a preservar

- No fer servir el path com a identitat de nota.
- No parsejar Markdown per metadata.
- No escanejar tot el filesystem en mode directory.
- No llegir totes les notes per renderitzar sidebar.
- `index.json` es la font operativa de metadata.
- Caches Lua en memoria per performance.
- UI, core, adapters i integracions han de continuar separats.
