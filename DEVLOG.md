# Devlog

## Actualitzacio - 2026-07-14

### Calendari

- El tercer mode de sidebar ara es `cal`, accessible amb `Tab` o
  `:SeijakuModeCalendar`.
- Calendari gregoria pur en Lua, navegable entre els anys 1 i 9999 sense
  dependencies ni calculs dependents de timezone.
- La columna de Seijaku es divideix en dues finestres reals: calendari mensual a
  dalt i notes del dia seleccionat a baix.
- El panell inferior comenca directament per les notes, sense titol ni separador
  horitzontal.
- La primera nota del dia obre la preview gestionada per defecte i moure el
  cursor pel llistat actualitza la preview, respectant-ne el tancament manual.
- Cada canvi de mode retorna cursor i scroll a la primera linia dels panells.
- Passar per un dia buit ja no deixa `all` o `dir` sense preview: cada canvi de
  mode la recrea amb la primera nota disponible al mode de destinacio.
- El panell diari suporta `r` per reanomenar i `dd` per eliminar amb confirmacio,
  a mes d'`Enter`, `a`, `n`, `x`, `Tab` i `R`.
- Al mode `all`, `date` usa `calendar_date` amb fallback a `created_at`,
  `updated` conserva l'ordre per ultima modificacio i el nou `created` agrupa
  estrictament per data de creacio; `s` recorre els tres.
- Eliminada la geometria manual de la preview: calendari, llista diaria, preview
  i notes addicionals tornen a ser splits normals que Neovim distribueix segons
  el layout disponible.
- `Ctrl-w j/k` canvia de panell; `h/j/k/l`, fletxes, `[/]`, `gg/G` i `t`
  naveguen dies, setmanes, mesos i avui.
- Els dies amb notes queden marcats; avui i el dia seleccionat tenen highlights
  propis.
- Les notes sense data explicita apareixen al seu dia de creacio. Les creades
  des del calendari guarden `calendar_date` i mostren `Date` a la capcalera.
- `a` i `n` creen notes contextuals o globals pel dia seleccionat; `x` elimina
  la data explicita des del panell de notes.
- Canviar de mode o tancar Seijaku neteja el panell auxiliar i les previews sense
  deixar splits orfes, inclos quan la sidebar es l'ultima finestra.

## Actualitzacio - 2026-07-13

### Context de fitxers i layout

- El mode inicial de la sidebar ara es `directory`.
- La sidebar s'obre com un `vsplit` real i força una amplada flexible tant a la
  finestra d'origen com a la sidebar.
- Si la sidebar queda com a ultima finestra, el toggle la substitueix per un
  buffer buit en lloc de fallar en intentar tancar l'ultima finestra.
- El recompte de l'ultima finestra ignora popups i finestres flotants, evitant
  l'error `E444` en tancar la sidebar.
- Els buffers especials que representen un fitxer existent es poden associar
  encara que el fitxer sigui binari o tingui una extensio com `.xlsx` o `.docx`.
- A Oil, el target es l'entrada sota el cursor; si no n'hi ha cap, es conserva
  el directori actual com a fallback.
- El context d'associacio d'Oil esta separat del context de navegacio: `a`
  treballa amb l'entrada sota el cursor, mentre el mode `dir` sempre representa
  el directori obert i tots els seus subdirectoris.
- L'esdeveniment `OilEnter` refresca la vista immediatament despres de renderitzar
  un directori nou, sense esperar el debounce generic de canvi de buffer.
- El filtre recursiu de targets usa els paths normalitzats de l'index sense fer
  crides repetides al filesystem per cada nota.

### Carrega i instal·lacio

- Afegida documentacio per instal·lar des de `saruDpol/seijaku-nvim` amb
  `lazy.nvim` o LazyVim.
- La spec remota declara `main = "seijaku"` i executa `setup()` via `opts`.
- La configuracio local amb `dir` continua documentada per desenvolupament.
- Mappings globals configurables:
  - `Alt-o`: obrir o tancar la sidebar.
  - `<leader>a`: crear una nota pel buffer actiu, amb `nowait`.

### Persistencia i metadata

- `updated_at` s'actualitza just abans d'escriure una nota.
- `created_at` no canvia en editar o reanomenar.
- Reanomenar modifica la metadata, pero no reescriu la capcalera Markdown.
- Les notes noves mostren, abans del titol, una capcalera Markdown minima
  generada amb les dates de creacio i modificacio i tots els paths associats.
- La capcalera visible se sincronitza en desar, associar o desassociar, pero
  `index.json` continua sent la font de veritat i no es parseja el Markdown.
- Un `index.json` invalid ja no es substitueix per un index buit en sortir.
- Corregida una cursa i el tancament dels timers de desat.

### Sidebar actual

- Capcalera compacta amb marca, separador complet i modes contextuals.
- Modes en ordre `all`, `dir`, `cal`, alternables amb `Tab`.
- `all` te ordenacio `date`, `updated` o `created`, alternable amb `s`:
  - `date` agrupa per data efectiva de calendari.
  - `updated` ordena per ultima actualitzacio.
  - `created` agrupa per dia de creacio.
- A `all`, cada nota reserva mes espai a la dreta pel primer target associat.
- `dir` mostra un arbre recursiu filtrat pel directori actual, incloent les
  carpetes intermedies necessaries.
- Fitxers, carpetes, dates, notes i modes tenen highlights separats.
- Integracio opcional amb `nvim-web-devicons` i icones de fallback.
- Amplada automatica gestionada per Neovim, limitada entre 44 i 56 columnes.

### Preview i splits

- La preview es un split horitzontal gestionat dins de la columna de sidebar.
- Les finestres de notes activen `wrap`, `linebreak` i `breakindent` per defecte;
  el wrapping es visual, local a la finestra i configurable des d'`editor`.
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
    ├── calendar.lua
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
:SeijakuModeCalendar
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
Alt-o       toggle sidebar
<leader>a  crear nota pel context actual
```

Es pot desactivar o canviar amb:

```lua
require("seijaku").setup({
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
    enable_default = false,
    toggle = "<A-o>",
    new_for_current = "<leader>a",
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
Tab    alternar all/directory/calendar
s      alternar date/updated/created en mode all
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

- `date` agrupa per `calendar_date`, amb fallback a `created_at`.
- `updated` ordena per ultima modificacio.
- `created` agrupa estrictament per data de creacio.

`directory`:

- Si el context actual es un fitxer normal, mostra nomes les notes associades exactament a aquell fitxer.
- Si el context actual es un directori o un buffer Oil, mostra els elements anotats dins aquell directori i, sota cada element, les seves notes.

Aixo evita que una nota associada a `config.lua` aparegui com si estigues associada a tots els fitxers del mateix directori.

`calendar`:

- Renderitza qualsevol mes entre els anys 1 i 9999.
- Separa calendari i notes del dia en dos splits navegables amb `Ctrl-w j/k`.
- Les notes creades des del calendari guarden `calendar_date`.
- Les previews i notes addicionals son splits normals gestionats per Neovim.

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
- El mode calendari navega dies, setmanes i mesos i mostra les notes de la data efectiva.
- `all`, `dir` i `cal` mantenen una preview gestionada quan hi ha notes.
- `wrap`, `linebreak` i `breakindent` nomes s'apliquen a les finestres de notes de Seijaku.

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

1. Acabar de polir l'adapter `oil.nvim`.
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
