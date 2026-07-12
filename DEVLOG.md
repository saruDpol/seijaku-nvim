# Devlog

## Actualitzacio - 2026-07-13

### Carrega i instal·lacio

- Afegida documentacio per instal·lar des de `saruDpol/seijaku-nvim` amb
  `lazy.nvim` o LazyVim.
- La spec remota declara `main = "seijaku"` i executa `setup()` via `opts`.
- La configuracio local amb `dir` continua documentada per desenvolupament.
- Mappings globals configurables:
  - `Alt-o`: obrir o tancar la sidebar.
  - `<leader>a`: crear una nota pel buffer actiu, amb `nowait`.

### Persistencia i metadata

- `updated_at` s'actualitza a `BufWritePost` quan es desa una nota.
- `created_at` no canvia en editar o reanomenar.
- Reanomenar modifica la metadata, pero no reescriu la capcalera Markdown.
- Un `index.json` invalid ja no es substitueix per un index buit en sortir.
- Corregida una cursa i el tancament dels timers de desat.

### Sidebar actual

- Capcalera compacta amb marca, separador complet i modes contextuals.
- Modes en ordre `all`, `dir`, `agenda`, alternables amb `Tab`.
- `all` te ordenacio `date` o `updated`, alternable amb `s`:
  - `date` agrupa per dia de creacio, del mes recent al mes antic.
  - `updated` ordena per ultima actualitzacio.
- A `all`, cada nota mostra a la dreta el primer target associat.
- `dir` mostra un arbre recursiu filtrat pel directori actual, incloent les
  carpetes intermedies necessaries.
- Fitxers, carpetes, dates, notes i modes tenen highlights separats.
- Integracio opcional amb `nvim-web-devicons` i icones de fallback.
- Amplada automatica gestionada per Neovim, limitada entre 40 i 52 columnes.

### Preview i splits

- La preview es un split horitzontal gestionat dins de la columna de sidebar.
- Moure la seleccio actualitza la preview mentre sigui oberta.
- `Enter` crea una vista fixa addicional dins de la mateixa columna.
- Si la preview es tanca amb `:q`, no reapareix pel simple moviment del cursor.
- Crear una nota amb la sidebar oberta reutilitza o recrea la preview i hi mou
  el focus per editar-la.

## Estat inicial - 2026-07-11

## Estat actual

`seijaku.nvim` ja te una primera versio funcional per gestionar notes Markdown amb associacions a paths del filesystem.

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
"~/Notes/seijaku"
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

### Keymap global

Per defecte:

```txt
Alt-o  toggle sidebar
```

Es pot desactivar o canviar amb:

```lua
require("seijaku").setup({
  keymaps = {
    enable_default = false,
    toggle = "<A-o>",
  },
})
```

### Sidebar

La sidebar torna a ser un split vertical normal, no un popup flotant. Aixo ha simplificat focus, modes i navegacio.

Mappings locals:

```txt
Enter  obrir nota en split horitzontal sota la sidebar
a      crear nota associada al context actual
x      detach de la nota seleccionada respecte del target/context actual
n      crear nota global
r      renombrar nota
dd     eliminar nota
Tab    alternar all/directory/agenda
s      alternar date/updated en mode all
R      refrescar
```

No hi ha mapping local `q`; la sidebar es tanca amb `:SeijakuCloseSidebar` o amb el toggle global.

La sidebar renderitza:

- Capcalera minimalista `静寂 / seijaku`.
- Guia compacta centrada.
- Path de context relatiu al directori on s'ha inicialitzat Neovim/Seijaku.
- Elements anotats del directori com a noms curts:
  - `• config.lua` per fitxers.
  - `▾ /seijaku` per directoris.

### Modes de sidebar

`all`:

- Mostra totes les notes ordenades per `updated_at`.

`directory`:

- Si el context actual es un fitxer normal, mostra nomes les notes associades exactament a aquell fitxer.
- Si el context actual es un directori o un buffer Oil, mostra els elements anotats dins aquell directori i, sota cada element, les seves notes.

Aixo evita que una nota associada a `config.lua` aparegui com si estigues associada a tots els fitxers del mateix directori.

### Notes obertes des de la sidebar

Les notes obertes amb `Enter` des de la sidebar es consideren part de la sessio de sidebar:

- S'obren per defecte amb `belowright split`.
- Es guarden a `sidebar.note_wins` i `sidebar.note_bufs`.
- Es tanquen automaticament quan es tanca la sidebar.
- No actualitzen el context de la sidebar mentre el focus hi es dins.

Aixo evita que obrir una nota associada a `config.lua` faci saltar el context de la sidebar cap a `config.lua` quan l'usuari venia d'un altre buffer.

### Context

El context actual suporta:

- Buffers normals de fitxer.
- Buffers de notes del vault.
- Sidebar `seijaku`.
- Buffers `oil.nvim`.

Regles importants:

- Si el focus esta a la sidebar, es conserva l'ultim context extern real.
- Si el focus esta en una nota oberta fora de la sessio de sidebar, el plugin resol la nota cap al seu primer target associat.
- Si el focus esta en una nota oberta des de la sidebar, el plugin conserva el context extern anterior.
- Si el focus esta a Oil, el directori actual es llegeix amb `require("oil").get_current_dir()`.

L'estat manté:

- `context.last`
- `notes_by_file`
- `sidebar.note_wins`
- `sidebar.note_bufs`
- `root_dir`, capturat en `setup()`

### Index derivat

`index.rebuild_derived_indexes()` construeix caches en memoria:

- `notes_by_id`
- `notes_by_file`
- `note_ids_by_target`
- `target_paths_by_dir`

Els directoris associats s'indexen en dos llocs:

- En el propi directori, per veure les notes quan s'esta dins aquell directori.
- En el directori pare, per veure la carpeta anotada com a element `▾ /nom`.

## Validacions fetes

S'han fet proves amb Neovim headless per comprovar:

- `require("seijaku")` carrega correctament.
- `setup()` crea el vault.
- `:SeijakuToggle` obre la sidebar split.
- `Alt-o` queda registrat com a toggle global.
- La sidebar mostra paths relatius al directori inicial.
- Els targets es renderitzen com a noms curts.
- `Enter` obre notes sota la sidebar.
- Tancar la sidebar tanca les notes obertes des d'ella.
- `a` crea nota associada al context actual.
- `x` treu l'associacio del target correcte.
- `dd` elimina nota.
- Oil dona el directori correcte via `oil.get_current_dir()`.
- Una nota associada a `config.lua` no apareix quan el context es `other.lua`.
- Els buffers de notes oberts des de la sidebar no canvien el context de la sidebar.

## Com provar manualment

Des del repo:

```bash
cd /home/sarudpol/main/seijaku
nvim -u NONE
```

Dins Neovim:

```vim
:set rtp+=/home/sarudpol/main/seijaku
:lua require("seijaku").setup({ vault_dir = "~/Notes/seijaku" })
```

Crear una nota associada al fitxer actual:

```vim
:edit lua/seijaku/config.lua
:SeijakuNewForCurrent
```

Obrir la sidebar:

```vim
:SeijakuToggle
```

O amb el keymap:

```txt
Alt-o
```

Canviar entre modes:

```txt
Tab
```

Crear una nota contextual des de la sidebar:

```txt
a
```

Desassociar la nota seleccionada del target actual:

```txt
x
```

Eliminar la nota seleccionada:

```txt
dd
```

## Per on continuar

### Seguent fase recomanada

Polir el comportament amb navegadors de fitxers:

1. Millorar adapter `oil.nvim`.
   - Detectar l'item sota cursor.
   - Fer que `a` pugui crear nota per l'item seleccionat a Oil, no nomes pel directori actual.
   - Fer que `x` sigui clar quan el context es un item d'Oil.

2. Implementar adapter `netrw`.
   - Suport best-effort.
   - Fallback al directori actual si no es pot detectar l'item.

3. Netejar visualment detalls de sidebar.
   - Decidir si el contador `[n]` de targets nomes surt quan `n > 1`.
   - Afegir highlights mes subtils per notes vs targets.
   - Revisar textos buits/no-notes.

4. Backups.
   - `:SeijakuBackup`.
   - Backup automatic a `backups/canonical/seijaku-latest.tar.gz`.
   - Snapshots manuals a `backups/snapshots/`.

5. Tests reals.
   - `paths_spec.lua`
   - `index_spec.lua`
   - `notes_spec.lua`
   - `context_spec.lua`
   - `sidebar_spec.lua`

### No prioritari ara mateix

- Popup flotant tipus Telescope.
- Preview flotant.
- Fuzzy finder.

El split vertical actual es molt mes facil de mantenir i debugar.

## Notes de disseny a preservar

- No fer servir el path com a identitat de nota.
- No parsejar Markdown per metadata.
- No escanejar tot el filesystem en mode directory.
- No llegir totes les notes per renderitzar sidebar.
- `index.json` es la font operativa de metadata.
- Caches Lua en memoria per performance.
- UI, core, adapters i integracions han de continuar separats.
