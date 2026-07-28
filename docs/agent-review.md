# agent-review — revisar en el editor lo que escribió un agente

Un agente de código (aquí: `claude` en casa, `codex` en el trabajo) corre **fuera** de
Neovim y escribe ficheros en disco. Este flujo sirve para revisar exactamente lo que
tocó ese agente —y nada más—, hunk a hunk, y devolverle un prompt con lo que hay que
corregir.

No hay plugin externo: el código vive en
[`lua/config/agent_review/`](../lua/config/agent_review/) y el spec de lazy que lo
declara está en [`lua/plugins/agent-review.lua`](../lua/plugins/agent-review.lua). Los
porqués del diseño están en [`docs/adr/0001-agent-review.md`](adr/0001-agent-review.md).

## Requisitos

- `git` en el PATH y estar **dentro de un repo con al menos un commit** (el snapshot se
  crea con `commit-tree … -p HEAD`; un `HEAD` no nacido da error explícito).
- Opcionales, pero es lo que hace agradable el flujo: `gitsigns` (para mover su base al
  snapshot) y `snacks.picker` (el dashboard; si falta, cae a la quickfix).
- No se carga en VS Code ni en el perfil pager.

## La idea en una frase

**La base de la comparación es un _snapshot_, no `HEAD`.** Tú disparas el snapshot antes
de dejar correr al agente; todo lo que vengas arrastrando de antes (tu trabajo sucio, tus
ficheros sin commitear) queda **dentro** de la base, así que el diff posterior enseña los
cambios del agente y solo esos. Si se te olvida `<leader>vs`, no hay contra qué comparar.

## El ciclo, en cinco pasos

### 1. Armar la ronda — `<leader>vs` (`:AgentReviewSnapshot`)

Antes de lanzar el agente. Toma una foto del árbol de trabajo y la guarda como un ref
`refs/agent-review/<fecha>-<hora>`, la registra como base de la ronda y apunta la base de
gitsigns a ella (a partir de ahí, la columna de signos de cualquier buffer enseña lo que
cambió el agente, no lo que cambió desde el índice).

Dos preguntas pueden salir aquí, y las dos son el motivo de que armar sea un paso
explícito:

- **Buffers sin guardar.** Si tienes buffers modificados te los lista y te da tres
  opciones: _escribirlos y luego snapshotear_, _snapshotear igual_ o _abortar_. Importa
  porque el agente va a escribir esos mismos ficheros desde fuera: si dejas cambios sin
  guardar, no están en la base y tu siguiente `:write` pisará (o te dará un W11) lo que
  escribió el agente. Lo normal es escribirlos.
- **Veredictos de la ronda anterior.** Si ya habías revisado hunks, te pregunta si
  conservarlos o tirarlos. Conservarlos tiene sentido porque los veredictos van por hash
  del contenido del hunk: un hunk que el agente reescribió vuelve a "sin revisar" solo;
  uno que no tocó mantiene su veredicto aunque se haya movido de línea.

### 2. Correr el agente

Fuera de Neovim, como siempre. Puede incluso commitear a mitad: el snapshot es un ref, no
se pierde.

### 3. Pasada de máquina — `<leader>vf` (`:AgentReviewCheck`)

Primero la máquina, después tú: lo que puede cazar un programa no debería gastar atención
humana. Corre tres comprobaciones **solo sobre los ficheros del diff** y las vuelca en la
quickfix:

- `lsp` — diagnósticos (ERROR/WARN) de cada fichero cambiado. Es el detector barato de
  APIs alucinadas: una función inventada o un campo mal escrito se enciende gratis.
- `stub` — restos de "ya lo haré": `TODO`, `FIXME`, `NotImplementedError`, `todo!`,
  `unimplemented!`, un `pass` como cuerpo entero… y solo en líneas **añadidas**.
- `deletion` — borrados silenciosos: ≥ 4 líneas quitadas sin nada a cambio, o manejo de
  errores (`try`/`catch`/`except`/`pcall`/`if err`/`raise`/`throw`) que desapareció y no
  volvió.

Es asíncrona por narices (los diagnósticos LSP llegan cuando llegan) con un techo de
~4 s. Sus hallazgos se guardan hasta que armes otra ronda y se añaden al prompt del
paso 5.

### 4. Pasada humana — `<leader>vv`, `]v` / `[v`, `<leader>va` / `vx` / `vc`

`<leader>vv` (`:AgentReviewDashboard`) es lo primero que abres. Una fila por fichero
cambiado, **en orden de riesgo, nunca alfabético** — ese orden _es_ la función. Cada fila
lleva score, estado (`A`/`M`/`D`), churn `+n/-m`, un resumen de clases de sus hunks
("3 logic, 1 imports") y el progreso `revisados/total`; los lockfiles y los ficheros
solo-whitespace salen marcados `[noise: …]` y en gris. El título del picker es el titular:

```
Agent review: 12 files, 48 hunks, 0/48 reviewed — 9 logic, 31 noise (whitespace/imports), 2 generated skipped
```

Enter abre el fichero en su pestaña, en el primer hunk aún sin revisar.
`:AgentReviewDashboard <ref>` acepta otro ref si quieres mirar contra otra base.

Luego se camina la cola:

- `]v` / `[v` — siguiente / anterior hunk **sin revisar**, atravesando todos los ficheros
  en ese mismo orden de riesgo. No cicla por el buffer actual: drena una cola.
- `<leader>va` — aceptar el hunk bajo el cursor.
- `<leader>vx` — **rechazar: es solo una marca.** No toca el buffer, no revierte nada.
  Deshacer un cambio del agente es un acto aparte y deliberado (`git`, `u`, Diffview);
  meterlo aquí convertiría una pasada de revisión en algo destructivo, y la revisión tiene
  que ser segura de correr sobre un árbol sucio.
- `<leader>vc` — comentar (te pide el texto); ese texto es el que acaba en el prompt.

Cada hunk lleva su marca en la columna de signos: `▎` sin revisar, `✓` aceptado,
`✗` rechazado, `≡` comentado, `┊` whitespace (atenuado).

**Los hunks de clase `whitespace` se saltan al navegar pero siguen contando** en el total.
Es a propósito: el progreso no miente. Por eso el final de la cola dice cosas como

```
No unreviewed hunks left [37/48 reviewed], 11 whitespace hunk(s) skipped
```

y no un `48/48` inventado. Si algún día quieres verlos:
`:lua require("config.agent_review.review").skip_whitespace = false`.

### 5. Construir el prompt — `<leader>vy` (`:AgentReviewPrompt`)

Junta los veredictos humanos de tipo _reject_ y _comment_ (los _accept_ no producen nada:
no son feedback) más los hallazgos de la última pasada de máquina, y los renderiza en
markdown agrupado por fichero.

El prompt **se abre siempre en un buffer** (`agent-review://prompt`, markdown, editable a
propósito: retocarlo antes de mandarlo es parte del flujo; `q` cierra, `<leader>y` lo
vuelve a copiar) y **luego** se intenta copiar al registro `+`.

Ese orden es la garantía: el buffer es la mitad fiable. La copia al portapapeles **no se
puede confirmar** por ssh, que es el caso normal — el camino es OSC52 y OSC52 no
responde, así que desde Lua es imposible saber si el texto llegó a la máquina de fuera.
Por eso el mensaje nombra el proveedor de portapapeles en vez de cantar victoria:

```
Prompt written to the + register (clipboard provider: OSC 52). Buffer open — <leader>y re-yanks it.
```

Si no hay nada que mandar te lo dice, y no abre un buffer vacío.

## Atajos y comandos

Todos los atajos están agrupados como **`review`** en which-key bajo `<leader>v`, y
aparecen también en el menú `<leader><leader>`, sección _Agent review_.

| Atajo        | Comando                 | Qué hace                                            |
| ------------ | ----------------------- | --------------------------------------------------- |
| `<leader>vs` | `:AgentReviewSnapshot`  | Armar: snapshot del árbol **antes** del agente      |
| `<leader>vv` | `:AgentReviewDashboard` | Dashboard por riesgo (acepta un ref opcional)       |
| `<leader>vf` | `:AgentReviewCheck`     | Pasada de máquina → quickfix                        |
| `]v`         | `:AgentReviewNext`      | Siguiente hunk sin revisar                          |
| `[v`         | `:AgentReviewPrev`      | Hunk anterior sin revisar                           |
| `<leader>va` | `:AgentReviewAccept`    | Aceptar el hunk bajo el cursor                      |
| `<leader>vx` | `:AgentReviewReject`    | Rechazar (**solo marca**, no edita)                 |
| `<leader>vc` | `:AgentReviewComment`   | Comentar el hunk bajo el cursor                     |
| `<leader>vy` | `:AgentReviewPrompt`    | Construir el prompt (buffer + `+`)                  |
| —            | `:AgentReviewReset`     | Borrar veredictos y base; gitsigns vuelve al índice |

Diagnóstico: `:checkhealth agent_review`.

> `<leader>vy` recalcula los hallazgos; `:AgentReviewPrompt` re-renderiza el último
> conjunto ya construido. Si lanzas el comando sin haber pulsado antes `<leader>vy`, dirá
> que no hay hallazgos.

## Ejemplo del prompt generado

Con dos comentarios humanos, un hunk rechazado sin nota y dos hallazgos de la pasada de
máquina, `<leader>vy` produce:

```markdown
Revisé los cambios que hiciste en esta rama. Corrige los puntos siguientes.
Cada entrada es `ruta:línea` seguida del comentario.

## lua/config/agent_review/git.lua

- `lua/config/agent_review/git.lua:118` — LSP warning: unused local `err` [lua_ls unused-local]
- `lua/config/agent_review/git.lua:204-211` — esto asume que write-tree nunca falla; devuelve nil, err como el resto del módulo

## src/api/client.py

- `src/api/client.py:42` — Silent deletion: error handling removed: try, except
- `src/api/client.py:77` — hunk rechazado

No toques nada fuera de estos puntos.
```

- El encabezado y el pie son fijos. Cada punto es `` `ruta:línea` `` (o
  `` `ruta:desde-hasta` ``) más tu comentario; si rechazaste sin escribir nada, sale el
  texto por defecto (`hunk rechazado`, `comentario`, `revisar` según el tipo).
- Con `include_diff = true` cada punto lleva debajo su hunk en un bloque ` ```diff `.
- El orden es determinista: por fichero, luego línea, luego línea final, luego texto.

## Opciones por host — `~/.nvim-local.lua`

`~/.nvim-local.lua` es el fichero de config local (ver
[`lua/config/local_config.lua`](../lua/config/local_config.lua); `:NvimLocalTemplate`
escupe la plantilla completa). El bloque de este flujo:

```lua
return {
  -- Agent review workflow (<leader>v): snapshot, review, prompt.
  agent_review = {
    clipboard = true,     -- además del buffer, copiar el prompt al registro +
    include_diff = false, -- incrustar el diff de cada hunk en el prompt
    -- Patrones Lua contra la ruta relativa al root; lo que casa no genera hallazgos.
    ignore = {
      -- "^vendor/",
    },
  },
}
```

- `clipboard = false` no rompe nada: el buffer del prompt sigue abriéndose, simplemente no
  se toca el registro `+`. Útil en hosts donde el portapapeles no va a ninguna parte.
- `include_diff = true` engorda mucho el prompt; sirve cuando el agente ya no tiene el
  contexto de lo que escribió.
- `ignore` son **patrones Lua**, no globs: `"^vendor/"`, `"%.pb%.go$"`. Filtra tanto los
  hallazgos humanos como los de máquina, y el mensaje te dice cuántos descartó. Un patrón
  malformado no rompe el prompt (va con `pcall`).

## `:checkhealth agent_review`

Te contesta cinco cosas, en este orden:

1. Que `git` existe y que estás dentro de un repo (y cuál es el root).
2. Qué snapshot se está usando y **de dónde sale**: `recorded base` (lo registraste con
   `<leader>vs`) o `latest snapshot (not yet recorded as the base)` — ojo con el segundo,
   ver más abajo. Si no hay ninguno, te dice que tomes uno.
3. Cuántos ficheros cambiaron desde ese snapshot.
4. El progreso `revisados/total` de la ronda (con `]v` como pista si va a medias).
5. Cómo llegaría el prompt al portapapeles: qué proveedor hay (o aviso de que no hay
   ninguno, con el recordatorio de que el buffer se abre igual y `<leader>y` copia a
   mano), y un aviso si detecta sesión ssh (`SSH_TTY`/`SSH_CONNECTION`) recordando que
   OSC52 no se puede confirmar: la única prueba es pegar una vez.

## Dónde vive el estado

Nada de esto ensucia el árbol de trabajo ni entra en un commit:

- **Snapshots**: refs `refs/agent-review/<AAAAMMDD-HHMMSS>` dentro del propio repo. Son
  commits de verdad, así que `:DiffviewOpen refs/agent-review/…` y
  `:Gitsigns change_base refs/agent-review/…` los aceptan. No están en ninguna rama, no se
  empujan, y `git for-each-ref refs/agent-review/` los lista si quieres limpiarlos a mano
  (`git update-ref -d <ref>`).
- **Veredictos**: `stdpath("state")/agent-review/<hash-del-root>/state.json`
  (`~/.local/state/nvim/…` en Linux). Escritura atómica; un JSON corrupto degrada a estado
  vacío con aviso, nunca se borra a tus espaldas.
- **Índices desechables** de git para construir los árboles:
  `stdpath("cache")/agent-review/`. Tu índice real no se toca jamás.

## Solución de problemas

- **"no agent-review snapshot yet: take one first (`<leader>vs`)"** — se te olvidó armar.
  No hay reparación posible a posteriori: sin foto previa no hay contra qué comparar. Arma
  la ronda y, si quieres mirar lo que ya escribió el agente, hazlo con `:DiffviewOpen` /
  `git diff` a mano; la próxima ronda ya sale bien.
- **Estás revisando contra un snapshot viejo.** Si no hay base registrada se cae al ref
  `refs/agent-review/*` **más reciente** y lo adopta como base. Cuando olvidas `<leader>vs`
  y hay una foto de anteayer, todo "funciona" pero mezcla tus cambios con los del agente.
  `:checkhealth agent_review` es quien lo canta: mira si dice `recorded base` o
  `latest snapshot (not yet recorded as the base)`. Para empezar limpio,
  `:AgentReviewReset` y luego `<leader>vs`.
- **El dashboard dice "No changes since the snapshot"** — o el agente no tocó nada, o
  hiciste el snapshot _después_ de que corriera (con lo cual sus cambios ya estaban dentro
  de la base).
- **"no agent hunk on line N of this file"** — el cursor no está dentro del rango de ningún
  hunk. `]v` te lleva a uno; no se adivina el hunk vecino a propósito.
- **"… is outside \<root>"** — el buffer no cuelga del root del repo. Todo el flujo es
  relativo al root.
- **"gitsigns unavailable, base unchanged"** — gitsigns no está cargado. La revisión
  funciona igual; solo pierdes los signos de gitsigns contra el snapshot (las marcas de
  veredicto `▎✓✗≡┊` las pone este flujo, no gitsigns).
- **Sale la quickfix en vez del picker en el dashboard** — `snacks.picker` no estaba
  disponible o falló; es el respaldo previsto, con la misma información.
- **`]v` dice "N in deleted files"** — quedan hunks en ficheros que el agente borró. No hay
  nada que abrir; míralos desde el dashboard (estado `D`) o con `git show`.
- **La pasada de máquina tarda o no saca diagnósticos** — hay un techo de ~4 s y un margen
  corto para que un servidor LSP se enganche; un fichero cuyo lenguaje no tiene servidor
  configurado no produce nada. Se limita a los 40 ficheros de mayor riesgo. Los buffers que
  ya tenías abiertos no se tocan; los que se cargaron solo para inspeccionar se descartan.
- **El prompt no aparece en el portapapeles** — pega para comprobarlo, es la única prueba.
  Con tmux hace falta `set -g set-clipboard on`, y un terminal con OSC52 (iTerm2, kitty,
  WezTerm, Ghostty, Alacritty). Mientras tanto el buffer está abierto: `<leader>y` recopia,
  o seleccionas y copias con el ratón.
- **"repository has no commits yet (unborn HEAD)"** — commitea algo antes de snapshotear.
- **Empezar de cero**: `:AgentReviewReset` borra todos los veredictos y la base, y devuelve
  gitsigns al índice. Los refs de snapshot siguen ahí (bórralos con `git update-ref -d`).
