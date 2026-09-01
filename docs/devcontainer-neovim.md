# Neovim dentro de un Dev Container

`scripts/devcontainer-editor` usa exclusivamente el binario ya instalado de
`@devcontainers/cli` (`devcontainer`). No descarga la CLI, Neovim, plugins ni
herramientas durante el arranque. El proyecto conserva como source of truth su
propio `.devcontainer/devcontainer.json` o `.devcontainer.json`; una ruta
explícita inválida falla sin elegir otra configuración.

## Uso

Desde el editor terminal completo:

```vim
:DevContainerUp
:DevContainerUp!
:DevContainerRecreate
:DevContainerRecreate!
:DevContainerStatus
:DevContainerLog
:DevContainerHostEditor
```

El adapter valida la ventana tmux `editor` de un único pane y arranca un
coordinador detached con `tmux run-shell -b`; el identificador `%N` del pane se
transmite explícitamente, nunca se redescubre desde el entorno del coordinador.
El adapter no confirma el arranque hasta observar el `claim_id` exacto en un
record `starting` o `running`; un timeout no retira ningún record fail-closed.
El coordinador persiste `starting`, ejecuta `devcontainer up`, reemplaza el pane mediante
un `respawn-pane` comprobado y sólo publica `running` tras verificar PID vivo y
el marker exacto del workspace. Una salida rápida queda `dead` o `error`, nunca
como éxito. `DevContainerHostEditor` restaura Neovim host, verifica PID nuevo y
marker retirado, persiste la transición y elimina explícitamente el record.

`!` transmite autorización de red al runtime como
`NVIM_CONFIG_OFFLINE=0`. Sin `!`, el editor recibe
`NVIM_CONFIG_OFFLINE=1`: `verified-tools.nvim` puede planificar/probar, pero un
claim que requiera red queda `blocked/offline` sin consumir el intento. La CLI
del Dev Container puede necesitar red por la propia imagen o Features del
proyecto; esta configuración no intenta ocultar ni sustituir esa política del
runtime.

La CLI pública es:

```sh
scripts/devcontainer-editor up --tmux-pane %N --claim-id UUID [--repo RUTA] [--config RUTA] [--recreate] [--allow-network]
scripts/devcontainer-editor exec [--cwd RUTA] -- programa argumento...
scripts/devcontainer-editor status [--json] [--repo RUTA]
scripts/devcontainer-editor log [--repo RUTA] [--pager]
scripts/devcontainer-editor open-location --cwd RUTA --file ARCHIVO [--line N] [--column N]
scripts/devcontainer-editor host [--repo RUTA]
```

`exec --` conserva argv y nunca construye un shell. Las rutas se traducen sólo
por el mapping exacto `{host_root, container_root}` y se revalidan contra el
filesystem host antes de escribir una petición.

## Transporte y estado

Cada repo usa directorios privados `0700` y registros, locks, peticiones y ACKs
`0600` bajo `NVIM_DEVCONTAINER_STATE_HOME` o
`$XDG_STATE_HOME/nvim-devcontainer`. El único secreto vive en
`spool/auth.json`, que es owner-only y se lee con comprobaciones de identidad;
nunca entra en argv, variables de entorno, records ni logs. Peticiones y ACKs
transportan un HMAC-SHA256, UUIDv4 canónico, action y schemas cerrados ligados
también a su filename. La escritura de mensajes no reemplaza archivos
existentes. Symlinks, traversal, permisos amplios, payloads
truncados/sobredimensionados y bindings distintos fallan cerrado.

El coordinador fija con descriptores el root de estado y sus hijos; locks,
records y spool se crean, leen, publican y retiran por basename respecto a esos
descriptores. El editor del container fija igualmente `inbox`, `outbox` y
`acks`: renombrar un directorio y sustituir su ruta por un symlink no redirige
un scan, una lectura, una publicación ni un borrado. Los retiros son
condicionales a la identidad exacta leída: primero reservan con rename
no-clobber, vuelven a comprobar y restauran un reemplazo detectado. Un fallo de
validación retira su snapshot sin ocultar el error original; una petición
autenticada se retira antes de ejecutar cualquier acción host, y desaparición o
reemplazo abortan sin ese side effect. Un fallo de
`fsync` posterior a un rename/unlink ya ejecutado se
reporta como advertencia de durabilidad, no como una falsa reversión.

POSIX no ofrece un syscall compare-and-unlink. Tras la última comprobación de
la reserva, el unlink final conserva como trust boundary los demás procesos
host del mismo UID; no se afirma cierre absoluto frente a uno que mute esa
reserva en la última ventana de syscall. El container y las rutas montadas no
se confían para elegir paths o identidades: siguen sujetos a descriptores,
basenames, owner/mode/nlink y a la reserva condicional anterior.

La fuente de un bind mount sigue siendo una ruta que
`@devcontainers/cli`/Docker resuelve fuera de este proceso: no existe aquí una
fuente descriptor-bound portable y demostrada para ese contrato externo. Por
ello `devcontainer up` revalida que la ruta lexical del spool todavía nombra el
descriptor fijado inmediatamente antes y después de la llamada; cualquier
cambio detectado detiene el lifecycle y deja estado fail-closed. Ese chequeo
acota y detecta la carrera, pero no puede eliminar la ventana de resolución
interna del CLI/runtime.

El coordinador host conserva un `fcntl.flock` advisory sobre un inode privado
`0600` durante toda su vida: un fichero unlocked antiguo se reutiliza, pero un
coordinador concurrente no puede entrar. También reconcilia el outbox para
LazyGit, log, retorno host y refresh de sesión mientras monitoriza el pane. Un
record existente en cualquier estado (`starting`, `running`, `stopped`,
`error` o `dead`) deshabilita fallback. Sólo la ausencia real del record emite
la señal reservada para el editor host. Antes del fallback, el launcher toma
ese mismo lock y vuelve a comprobar la ausencia; el descriptor se marca
inheritable y sobrevive al `exec` de `exact-editor-open` hasta que termina su
RPC o su espera bloqueante. Los subprocesses de ese router cierran descriptores
ajenos, por lo que no prolongan el lock. Así ningún lifecycle cooperativo puede
publicar `starting` entre la decisión de ausencia y el handoff host. El handoff
verificado es quien retira un record existente. La publicación no forma parte
del transporte.

Si `SSH_AUTH_SOCK` es un socket vivo propiedad del usuario, se monta como socket
y se verifica con `test -S` dentro del container. Si no existe, no se inventa
ni copia ninguna llave. El runtime monta la configuración read-only y lanza
`nvim -u /tmp/nvim-config/init.lua`; herramientas, PATH, perfiles y sesiones se
siguen componiendo desde los adapters host existentes.
