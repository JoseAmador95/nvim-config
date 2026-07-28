# 0001 — Revisión in-editor de código escrito por un agente

## Status

Accepted — 2026-07-28.

Implementado en [`lua/config/agent_review/`](../../lua/config/agent_review/),
[`lua/agent_review/health.lua`](../../lua/agent_review/health.lua) y
[`lua/plugins/agent-review.lua`](../../lua/plugins/agent-review.lua). Manual de uso:
[`docs/agent-review.md`](../agent-review.md).

## Context

Trabajo con agentes de código que corren **fuera de Neovim**: Claude Code CLI en casa,
Codex CLI en el trabajo. Ninguno de los dos es un plugin: son procesos aparte que escriben
ficheros en disco. Lo que se produce en una sesión así no es un parche que llega para ser
aplicado, sino un árbol de trabajo que ya cambió, mezclado con lo que yo tuviera a medias.

De ahí los problemas concretos:

- **No hay una línea base natural.** `HEAD` no sirve: el agente puede commitear a mitad de
  su ejecución, y encima yo suelo empezar con el árbol sucio.
- **El volumen mata la atención.** Un agente cambia doce ficheros de una tacada, y ocho son
  reformateos, imports movidos y un lockfile. Leer todo por igual garantiza que lo
  load-bearing se lea peor.
- **El feedback hay que devolverlo.** Las notas de revisión no valen de nada dentro de mi
  cabeza; tienen que volver al agente en un formato que pueda ejecutar.

Este ADR existe para que la próxima sesión no vuelva a litigar estas decisiones. Varias de
ellas son contraintuitivas y parecen "simplificables"; no lo son.

## Decision

### 1. La base es un ref de snapshot, no `HEAD`

`<leader>vs` construye la foto del árbol de trabajo con un **índice desechable** bajo
`stdpath("cache")`:

```sh
GIT_INDEX_FILE=<cache>/agent-review/ar-index git read-tree HEAD
GIT_INDEX_FILE=…                             git add -A -- .
tree=$(GIT_INDEX_FILE=…                      git write-tree)
commit=$(git commit-tree $tree -p HEAD -m "agent-review snapshot")
git update-ref refs/agent-review/<AAAAMMDD-HHMMSS> $commit
```

Cada pieza está ahí por un motivo:

- **Índice desechable** (`GIT_INDEX_FILE`): el índice real del usuario no se toca jamás.
  Una herramienta de revisión no puede permitirse pisar un `git add -p` a medias.
- **`add -A`**: mete en la base tanto las modificaciones de ficheros ya trackeados como los
  **untracked**, respetando `.gitignore`. Es lo que hace que mi trabajo sucio previo quede
  _dentro_ de la base y el diff posterior muestre los cambios del agente y solo esos.
- **Un commit, no un tree pelado**: `:DiffviewOpen <ref>` y `gitsigns.change_base(<ref>)`
  exigen una revisión. Guardar el árbol como commit es lo que permite reusar las
  herramientas que ya hay en la config en vez de inventar una vista de diff propia.
- **Un ref** (`refs/agent-review/*`): sobrevive a que el agente commitee a mitad de su
  ejecución, y no está en ninguna rama, así que no se empuja ni ensucia el repo.

### 2. El descubrimiento de ficheros compara árbol contra árbol, no `git diff <ref>`

Comprobado experimentalmente: **`git diff <ref>` omite en silencio los ficheros untracked
que creó el agente** — justo la categoría más importante de una ronda de revisión. Por eso
se construye un segundo árbol "ahora" por la misma vía del índice desechable y se comparan
los dos árboles con `git diff-tree`.

Con la misma naturaleza: **`git diff -w --name-only` NO filtra los ficheros con cambios
solo de whitespace**, los sigue listando. Así que la clasificación whitespace-only se
decide **por fichero**, comprobando que `git diff -w <base_tree> <now_tree> -- <path>` sale
vacío.

Ambas cosas parecen rodeos y no lo son. Están anotadas también en el propio `git.lua` para
que nadie las "simplifique" de vuelta.

### 3. Los veredictos se indexan por hash del contenido del hunk, nunca por fichero+línea

La clave de un veredicto es `sha256` del cuerpo del hunk, sin números de línea. Las dos
consecuencias son exactamente el comportamiento que se quiere entre rondas:

- un hunk que el agente **reescribió** hashea distinto → vuelve a "sin revisar" y lo veo
  otra vez;
- un hunk que el agente **no tocó** conserva su hash → conserva su veredicto aunque haya
  derivado a otra línea.

Mezclar la posición en la clave destruiría las dos propiedades a la vez.

### 4. Rechazar solo marca

`<leader>vx` registra un veredicto y no modifica el buffer. Revertir es un acto aparte y
deliberado, y git y el undo ya lo hacen bien. Confundir revisar con revertir volvería
destructiva una pasada de revisión, y una pasada de revisión tiene que ser segura de correr
sobre un árbol sucio.

### 5. El punto de todo esto es **enrutar la atención**

El scoring de riesgo por fichero (añadido/borrado, churn, rutas o líneas sensibles —
`exec`, `eval`, `token`, `auth`…—, penalización a generados/whitespace/tests) y la
clasificación de hunks (`logic` / `comments` / `imports` / `whitespace`) no son adornos:
existen para que lo load-bearing se lea primero y el ruido se salte. De ahí que el
dashboard no se reordene nunca alfabéticamente y que su titular ("12 files, but only 4
carry logic") sea el título del picker.

Por lo mismo, **la pasada de máquina va antes que la humana**: lo que puede detectar un
programa (diagnósticos LSP, stubs en líneas añadidas, borrados silenciosos de manejo de
errores) no debe gastar atención humana.

Corolario deliberado: los hunks de clase `whitespace` se **saltan al navegar** pero
**siguen contando en el total**. El progreso `37/48` con "11 whitespace hunk(s) skipped" es
honesto; un `48/48` fabricado no lo sería.

### 6. La salida es texto, esta ronda; inyectarla en la sesión viva del agente queda aplazado

`<leader>vy` renderiza markdown a un buffer y al registro `+`. Se investigó automatizar el
paso siguiente y se decidió **no** hacerlo todavía. La investigación queda aquí para no
repetirla:

- `claude` expone `-r/--resume <id>`, `-p/--print`, `-c/--continue` y `--fork-session`.
- Sus sesiones viven en `~/.claude/projects/<cwd-con-barras-como-guiones>/<uuid>.jsonl`.
- **No hay subcomando para listar sesiones**: listarlas significa enumerar esos ficheros.
- Codex **no se verificó**.

El riesgo que lo paró: `--resume … -p` escribe en el transcript de la sesión **desde otro
proceso**. Si hay una TUI interactiva abierta sobre esa misma sesión, tenemos dos
escritores sobre el mismo fichero. Hasta no tener eso resuelto, copiar y pegar es la opción
correcta.

### 7. `present()` abre el buffer antes de intentar el portapapeles

El prompt tiene que ser visible aunque el portapapeles no esté configurado — que es el caso
**normal** por ssh. Y OSC52 no da acuse de recibo: desde Lua es imposible saber si el texto
llegó a la máquina de fuera. Por eso el orden es buffer primero, portapapeles después, y el
mensaje **nombra el proveedor** en vez de afirmar un éxito que nadie puede comprobar. La
garantía que se ofrece es la que se puede cumplir: el prompt está en pantalla.

## Consequences

- **Olvidar `<leader>vs` no tiene arreglo a posteriori.** Sin foto previa no hay contra qué
  comparar. Se mitiga como se puede: el snapshot avisa de los buffers sin guardar, y
  `:checkhealth agent_review` distingue `recorded base` de `latest snapshot (not yet
recorded as the base)` para que se vea cuándo se está cayendo a un snapshot viejo.
- **Cada snapshot deja un ref y objetos en el repo.** Son baratos y no se empujan, pero se
  acumulan; se limpian a mano con `git for-each-ref refs/agent-review/` y
  `git update-ref -d`.
- **Reconstruir el árbol "ahora" re-hashea el worktree en cada llamada** (el índice
  desechable no lleva stat cache). Se memoiza 2 s, lo justo para que una pasada de revisión
  sea internamente consistente y siga viendo las ediciones posteriores.
- **La pasada de máquina es asíncrona y acotada** (~4 s, 40 ficheros): puede devolver menos
  de lo que un análisis completo daría. Es un filtro previo, no una CI.
- **El estado vive fuera del repo** (`stdpath("state")`), así que no viaja con un clon ni
  se comparte entre máquinas. Es lo que se quiere: un veredicto es mío y de esta ronda.
- **El feedback se pega a mano.** Un paso manual por ronda a cambio de no arriesgar la
  corrupción del transcript.

## Alternatives considered

- **Comparar contra `HEAD`.** Es lo obvio y falla en los dos escenarios reales: si el
  agente commitea a mitad, sus cambios desaparecen del diff; y si yo empiezo con el árbol
  sucio, mi trabajo previo se mezcla con el suyo y ya no se sabe quién escribió qué. El
  snapshot resuelve ambos de una vez.
- **Comparar contra el índice / usar `git stash`.** Toca el estado real de git del usuario;
  descartado por el mismo motivo que el índice desechable.
- **Guardar el snapshot como tree pelado.** Más barato, pero Diffview y
  `gitsigns.change_base` no lo aceptan como revisión, y perderíamos la reutilización de las
  herramientas de diff que ya hay.
- **`git diff <ref>` para descubrir ficheros.** Más corto y **incorrecto**: se come los
  untracked que creó el agente (comprobado). Ídem `git diff -w --name-only` para clasificar
  whitespace: no filtra (comprobado).
- **Indexar veredictos por fichero+línea.** Más simple de leer en el JSON, y rompe las dos
  propiedades del punto 3 en cuanto algo se mueve o se reescribe.
- **Revertir al rechazar.** Convierte la revisión en una operación destructiva sobre un
  árbol sucio; además duplica mal lo que git y el undo ya hacen.
- **Inyectar pulsaciones en un panel de terminal/multiplexor** (tmux `send-keys`, un
  terminal de Neovim). Frágil por tres sitios a la vez: un pegado multilínea en una TUI se
  envía línea a línea y cada `\n` cuenta como envío; roba el foco; y depende del
  multiplexor que haya delante. Descartado.
- **`claude --resume … -p` desde Neovim.** La opción prometedora, aplazada por el riesgo de
  doble escritor sobre el transcript descrito en el punto 6.
