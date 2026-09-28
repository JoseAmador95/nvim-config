# Neovim dentro de un Dev Container

`scripts/devcontainer-editor` usa exclusivamente la versión certificada de
`@devcontainers/cli` activa en `verified-tools.nvim`. Resolver o instalar el
dist-tag `latest` sólo ocurre mediante el comando explícito
`:NvimConfigToolsInstall devcontainers-cli`; abrir Neovim o un workspace nunca
consulta npm ni descarga la CLI, Neovim, plugins o herramientas. El proyecto
instala cada release como un bundle privado e inmutable con Node `24.20.0`; el
puntero activo sólo se publica después de verificar de nuevo el bundle y su
closure. Tanto el editor como el helper headless de tmux resuelven ese mismo
puntero offline y no consultan `PATH`, Node/npm del host ni metadata `latest`.
El repositorio conserva como source of truth su propio
`.devcontainer/devcontainer.json` o
`.devcontainer.json`; una ruta explícita inválida falla sin elegir otra
configuración.

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
:DevContainerDoctor
```

El adapter resuelve la CLI certificada y
`plugins.devcontainer_editor.docker_path` (`docker` por defecto), canonicaliza
ambos ejecutables y ejecuta un `doctor` read-only antes de reservar un nuevo
claim. El doctor comprueba las superficies `up`, `run-user-commands` y `exec`
que realmente usa, incluye en el probe de `up` un mount representativo
construido por el mismo helper de producción, valida el modo de lockfile y
recorre en lectura la closure de configuración. Con macOS y Podman Machine
también contrasta la conexión rootless seleccionada, la identidad SSH exacta de
la VM y cualquier pin
`known_hosts` ya existente, pero no abre el gate, el reverse forwarding ni el
proxy del container; el doctor no crea estado ni reserva un lifecycle. Luego
valida la ventana tmux `editor` de un único pane y arranca un coordinador detached
con `tmux run-shell -b`; el identificador `%N` del pane se transmite
explícitamente, nunca se redescubre desde el entorno del coordinador.
El adapter no confirma el arranque hasta observar el `claim_id` exacto en un
record `starting` o `running`; un timeout no retira ningún record fail-closed.
Mientras tanto mantiene una sola notificación con spinner, etapa y tiempo
transcurrido. Las actualizaciones directas no entran en `:messages`; el resultado
final sí pasa una sola vez por el broker normal de notificaciones. Al completar
el handoff, el proceso host ya fue sustituido; por eso el `claim_id` se transmite
como señal one-shot. Después de `VeryLazy`, el Neovim nuevo envía la acción
interna `editor_ready` por el spool autenticado y sólo publica el éxito cuando
recibe el ACK del coordinador. Ese ACK sólo puede emitirse después de verificar
el pane exacto, persistir `running` y escribir la entrada de log correspondiente.
El tracker queda ligado a `{root, claim_id}`, tolera durante cinco segundos una lectura
transitoria del record y se detiene si cambia el claim o muere el coordinador.
El coordinador persiste `starting`, revalida los dos paths exactos, ejecuta
`devcontainer up --docker-path ...`, reemplaza el pane mediante
un `respawn-pane` comprobado y sólo publica `running` tras verificar PID vivo y
el marker exacto del workspace. Una salida rápida queda `dead` o `error`, nunca
como éxito. `DevContainerHostEditor` restaura Neovim host, verifica PID nuevo y
marker retirado, persiste la transición y elimina explícitamente el record. En
el host, el mismo comando puede retirar y recuperar records `error`, `stopped`
o `dead`; rehúsa competir con un lifecycle `starting` o `running`.

`:DevContainerLog` abre o enfoca un único split vertical a la derecha que sigue
el log privado en vivo. `q` cierra el visor y detiene ese follower; alejar el
cursor del final conserva la posición mientras siguen llegando líneas. Un
estado terminal de error observado para el `claim_id` exacto antes del handoff
abre el split automáticamente por defecto. Un error de preflight o del monitor
visual sólo deja la notificación. Después de `respawn-pane`, el editor host que
poseía ese split ya no existe; cualquier fallo posterior permanece en el log
privado para `:DevContainerLog` desde el siguiente editor disponible.
El ancho efectivo se limita a media pantalla, salvo en terminales de menos de
40 columnas, donde conserva el mínimo utilizable de 20.

La política visual es host-only en `~/.nvim-local.lua`:

```lua
return {
  plugins = {
    devcontainer_editor = {
      ui = {
        progress = true,
        progress_interval_ms = 500, -- 200..5000
        log_width = 72, -- 30..160; luego se limita a media pantalla
        auto_open_log_on_error = true,
      },
    },
  },
}
```

El intervalo de 500 ms evita redibujos agresivos en una terminal sobre SSH.
Estas opciones no cruzan al plugin local ni se aceptan desde la configuración
del proyecto.

## Recuperación explícita

Si `DevContainerUp` o `DevContainerRecreate` encuentra un record `error` o
`stopped`, no inicia otro lifecycle encima del anterior. El flujo de recuperación
es:

```vim
:DevContainerLog
:DevContainerHostEditor
```

Hay que esperar la confirmación `Dev Container lifecycle recovered; retry
:DevContainerUp` antes de volver a ejecutar `DevContainerUp` o
`DevContainerRecreate`. Un record `starting` debe terminar primero; un record
`running` continúa perteneciendo al editor registrado del container.

Si Neovim host fue reiniciado y el PID guardado ya no coincide, la recuperación
explícita puede adoptar el pane actual sin hacer `respawn`. Para ello comprueba en
una sola observación que sea exactamente el pane registrado, esté vivo, pertenezca
a la ventana `editor` de un solo pane, ejecute `nvim`, conserve el cwd canónico del
repo y no tenga marker de container. Cualquier identidad ambigua falla cerrada.
Retirar así un record v2/v3 es una acción solicitada por el usuario, no una
migración ni limpieza implícita durante el arranque.

El router de tmux usa `scripts/devcontainer-runtime`, un Neovim headless con
`-u NONE` que carga sólo los módulos config/locales necesarios. `prepare-up`
lee la política host de `~/.nvim-local.lua`, resuelve CLI y engine, ejecuta el
mismo doctor y emite una única pareja tab-delimited antes del claim;
`preflight-record` no emite paths y valida un record v4/v5/v6 `dead` con sus
rutas persistidas. Un editor ya activo sólo se verifica y enfoca: no vuelve a
resolver ni a sondear herramientas.

`!` transmite autorización de red al runtime como
`NVIM_CONFIG_OFFLINE=0`. Sin `!`, el editor recibe
`NVIM_CONFIG_OFFLINE=1`: `verified-tools.nvim` puede planificar/probar, pero un
claim que requiera red queda `blocked/offline` sin consumir el intento. La CLI
del Dev Container puede necesitar red por la propia imagen o Features del
proyecto; esta configuración no intenta ocultar ni sustituir esa política del
runtime.

La CLI pública es:

```sh
scripts/devcontainer-editor up --cli-path RUTA --docker-path RUTA --tmux-pane %N --claim-id UUID [--repo RUTA] [--config RUTA] [--recreate] [--allow-network]
scripts/devcontainer-editor exec [--cwd RUTA] -- programa argumento...
scripts/devcontainer-editor status [--json] [--repo RUTA]
scripts/devcontainer-editor log [--repo RUTA] [--pager]
scripts/devcontainer-editor open-location --cwd RUTA --file ARCHIVO [--line N] [--column N]
scripts/devcontainer-editor host [--repo RUTA] [--tmux-pane %N]
scripts/devcontainer-editor doctor --cli-path RUTA --docker-path RUTA [--repo RUTA] [--config RUTA]
```

`exec --` conserva el cwd traducido y cada elemento de argv, incluidos vacíos y
metacaracteres. Para no depender de que la release activa ofrezca `--workdir`,
usa un único trampoline constante `/bin/sh -c`: el cwd y argv se pasan sólo
como parámetros posicionales y nunca se interpolan en el código del shell. Las rutas
se traducen sólo por el mapping exacto `{host_root, container_root}` y se
revalidan contra el filesystem host antes de escribir una petición.

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

El log también es un fichero regular privado `0600`, de un solo link y dentro
de esa jerarquía `0700`. `devcontainer up --log-format json` se drena de forma
concurrente: stderr alimenta el log incremental y stdout queda reservado al
resultado JSON acotado. Eventos desconocidos, bytes UTF-8 inválidos y secuencias
de control se presentan de forma segura sin decidir el lifecycle. Sólo se
conservan los 256 KiB más recientes, con un marcador explícito al truncar.

Los mensajes y secretos siguen en schema v2. Los records v6 fijan `cli_path`,
`docker_path`, una fase cerrada y la identidad opcional
`podman_connection = {name,machine_pin}`. Las fases son `claimed`,
`preparing-config`, `starting-container`, `checking-ssh-agent`, `checking-editor-config`,
`opening-editor`, `monitoring-editor` o `returning-host`. En engines que no son
Podman Machine ese campo es `null`. Los records v2/v3/v4/v5 continúan siendo
legibles para status y transporte autenticado ya activo. Los v2/v3 no pueden
ejecutar ni reiniciar porque no identifican ambos ejecutables; un v4/v5 `dead`
con Docker sólo se actualiza al reiniciarlo de forma explícita. Un record macOS
Podman anterior a v6 queda recovery-only: no se enlaza silenciosamente con la
Machine que sea default hoy. No se reescriben ni borran como parte de una
migración implícita. La autoridad de
limpieza
del snapshot es un sidecar v1 separado, de modo que un record v4 anterior a
esta protección todavía se puede recuperar cuando no existe ni sidecar ni
artefacto de snapshot.

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

La configuración de Neovim no se monta directamente. Antes de `up`, el
coordinador copia una closure explícita (`init.lua`, `lazy-lock.json`, `lua`,
`local-plugins` y `scripts`, más `after` y `tombi` si existen) a
`<spool>/config-<claim_id>`. Sólo admite directorios y ficheros regulares de un
único link, propiedad del usuario y sin escritura de grupo/mundo; rechaza
symlinks, especiales, cambios de identidad y límites superiores a 32 niveles,
1024 ficheros, 1024 directorios, 1024 entradas en un solo directorio o 16 MiB.
Esos límites se aplican durante el scan sin materializar un directorio no
acotado. La copia contiene bytes independientes, queda sin bits de escritura
(`0500` para directorios/ejecutables y `0400` para los demás ficheros), incorpora
un marker opaco `0400` y se publica no-clobber por basename respecto al spool
fijado. Una segunda pasada valida la closure de origen y, ya congelada, se
recorre completa para comprobar tipos, ownership, modos, links, límites y el
marker.

Inmediatamente después de `up` y de sus probes opcionales, el coordinador
comprueba que el basename publicado todavía coincide con el descriptor y la
identidad `{device,inode,owner}` retenidos, y vuelve a recorrer la closure. A
continuación ejecuta un probe remoto fijo con `/bin/sh -c`: `init.lua`, la ruta
del marker y su valor se pasan como argumentos posicionales, sin `--workdir` ni
interpolación de datos en el shell. Así confirma que el mount reutilizado puede
leer el snapshot del claim actual. Justo antes de `respawn-pane` repite la
validación local de identidad y closure; un fallo local o remoto aborta antes de
reemplazar el editor.

El snapshot permanece accesible durante `up`, la comprobación del agent, el
respawn y todo el monitor del editor. Neovim arranca con
`-u <remote_spool>/config-<claim_id>/init.lua`; no usa el `--workdir` inexistente.
Cambios posteriores en la configuración host no afectan al editor ya abierto:
se necesita un lifecycle o restart explícito para crear otro snapshot. El
handoff al host y todas las salidas manejadas lo retiran antes del ACK positivo
o del record; una limpieza fallida conserva el error original y deja la entrada
claim-addressable para recuperación. Un crash no se barre implícitamente: el
restart o la recuperación host explícitos sólo pueden retirar ese orphan usando
un sidecar owner-only `0600`, no montado, llamado
`workspaces/<workspace-id>.snapshot`. El schema cerrado liga `host_root`, claim,
basename, marker y la identidad exacta del directorio. El retiro compara esa
identidad antes de tocar el directorio y elimina después únicamente la identidad
de fichero del sidecar que se leyó. Handoff, restart y recuperación inactiva
rehúsan borrar un directorio sustituto. Si un crash ocurre después de publicar
el snapshot pero antes del sidecar, el artefacto sin autoridad falla cerrado y
requiere intervención manual; no se adivina ni se borra por nombre.

Estas comprobaciones detectan sustituciones cooperativas y mounts obsoletos,
pero no constituyen un sandbox ni prometen inmutabilidad frente a otro proceso
host del mismo UID, `root` o un owner mapeado desde el container. El marker es
una prueba de identidad/frescura legible, no un secreto; un actor dentro de ese
límite puede leerlo y puede efectuar mutaciones de igual tamaño entre
comprobaciones. La seguridad de borrado se apoya en la identidad host-only del
sidecar, además de la reserva condicional ya descrita.

El coordinador host conserva un `fcntl.flock` advisory sobre un inode privado
`0600` durante toda su vida: un fichero unlocked antiguo se reutiliza, pero un
coordinador concurrente no puede entrar. También reconcilia el outbox para
LazyGit, log, retorno host y refresh de sesión mientras monitoriza el pane. Un
`editor: host` solicitado desde tmux durante el estado `running` se publica en
ese outbox y espera el ACK autenticado; no intenta competir por el flock que ya
posee el coordinador. Volver a seleccionar `editor: Dev Container` valida el
record, pane, PID y marker activos y sólo enfoca la ventana, sin reiniciarla. Un
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

Si `SSH_AUTH_SOCK` existe con la política `auto`, debe ser un socket canónico
propiedad del usuario y conservar exactamente su identidad hasta iniciar el
lifecycle. `--ssh-agent off` lo desactiva. La comprobación dentro del container
no se limita a `test -S`: ejecuta `ssh-add -l` y acepta tanto un agent con
identidades como uno vacío. Nunca se copian las llaves Git ni el socket host a
un fichero regular.

Docker y los runtimes Linux que comparten el filesystem host conservan el bind
directo del socket. En macOS con `podman`/`podman-remote`, un socket launchd como
`/var/run/com.apple.launchd.../Listeners` no existe dentro de Podman Machine y
por tanto nunca se entrega como bind source. El coordinador descubre una única
conexión Machine rootless, local y loopback; cruza `connection list`, `machine
list` e `inspect`, y fija nombre, usuario, UID, creación e identity file. La
conexión SSH usa `/usr/bin/ssh`, sólo autenticación public-key, un
`known_hosts` privado `0600` por generación de VM y ninguna configuración,
proxy, agent forwarding, X11, TTY ni control master heredados. Antes de añadir
la identity file exacta con `-i`, fija `IdentityFile=none`; si esa clave
desaparece entre validación y ejecución, OpenSSH no recurre a las claves
privadas por defecto del usuario.
El primer `accept-new` sólo se permite mientras un descriptor demuestra que el
pin sigue vacío. Después se usa siempre `StrictHostKeyChecking=yes` y
`UpdateHostKeys=no`; una clave aprendida se sincroniza a disco y directorio y se
conserva incluso si ese primer intento SSH termina en error. Reemplazar el inode
durante la matrícula o persistencia falla cerrado y preserva la evidencia.

La selección inicial puede usar `CONTAINER_CONNECTION` o `CONTAINER_HOST`, pero
debe resolver exactamente una conexión; un `CONTAINER_SSHKEY` ambiental se
rechaza. Antes de crear el container se persisten el nombre y un fingerprint
estable de la generación de Machine. Desde ese punto, el coordinador elimina
los overrides heredados y pasa a cada `up`, `exec`, probe, relay y editor
detached el `CONTAINER_HOST` SSH exacto y el `CONTAINER_SSHKEY` exacto.
`exec` y `restart-dead` vuelven a buscar sólo el nombre persistido, cruzan otra
vez la metadata y comparan el fingerprint antes de ejecutar o mutar el record.
Un cambio de default no redirige el lifecycle; desaparición, ambigüedad o cambio
de identidad requieren recuperación explícita.

El transporte de agent no modifica ni desactiva SELinux y no crea un volumen.
Que la Machine siga en enforcing y que el proceso proxy tenga el dominio
esperado `container_t` son pruebas del canary real; el launcher no
lee ni afirma esos estados. El coordinador abre un gate Unix host dentro de un
directorio `0700`; el socket es `0600`, conserva una identidad exacta y sólo
acepta conexiones autenticadas. También captura y revalida identidad,
propietario y modo de cada ancestro canónico del agent host. Sólo admite como
excepción escribible el runtime launchd exacto de macOS,
`/private/var/run` `root:daemon` `0775`, seguido directamente por el directorio
`com.apple.launchd.*` `0700` del UID actual. OpenSSH lo reverse-forwardea a un puerto TCP
elegido para ese lifecycle, ligado exclusivamente a `127.0.0.1` dentro de la
Machine. El helper remoto confirma una vez al arrancar, mediante
`/usr/bin/ss`, que existe exactamente ese listener loopback antes de declararlo
listo; no se acepta un wildcard ni una dirección distinta. Si el proceso SSH
termina antes de readiness, el coordinador prueba como máximo tres puertos
distintos y recoge por completo cada hijo fallido antes del siguiente intento.

Los requisitos concretos de esta ruta son `/usr/bin/ssh` en el host;
`/bin/sh` y `/usr/bin/ss` dentro de la Machine; y red `host`,
`/usr/bin/test`, `/usr/bin/python3` ejecutable, `/bin/sh` y
`/usr/bin/ssh-add` dentro del container. El `doctor` exige además que la CLI exponga las opciones usadas de
`up`, `exec` y `run-user-commands`, incluidas `--skip-post-create`,
`--container-id` y `--remote-env`.

El coordinador ejecuta primero `devcontainer up --skip-post-create`: así puede
crear o seleccionar el container sin que los lifecycle hooks observen un
`SSH_AUTH_SOCK` anunciado pero todavía ausente. Cuando `up` devuelve el
container, exige su ID hexadecimal completo, una única coincidencia todavía en
ejecución, `Config.Labels["devcontainer.local_folder"]` igual a la raíz
canónica, `Config.Labels["devcontainer.config_file"]` igual al config canónico
y `HostConfig.NetworkMode` exactamente `host`. Repite esa atestación antes y
después de que el proxy anuncie readiness. Los comandos
`devcontainer exec --container-id` se ejecutan como el usuario remoto configurado por Dev
Containers: con esa autoridad comprueban `/usr/bin/test -x /usr/bin/python3` y
arrancan `/usr/bin/python3 -I -S` para el proxy, sin derivar ni comparar por
separado un UID numérico ni aceptar módulos del entorno. Cada lifecycle usa un
nombre aleatorio nuevo para su directorio `0700`; el proxy exige que éste y su
socket `0600` pertenezcan a su propio UID efectivo. Ése es el único socket
publicado como `SSH_AUTH_SOCK`; el socket launchd host no se monta ni se copia.

Gate y proxy comparten un token aleatorio de 256 bits nuevo para cada lifecycle.
El token entra únicamente por stdin del proceso proxy, nunca por argv, entorno,
log ni TCP loopback. Cada conexión TCP usa un challenge nuevo y dos
HMAC-SHA256 con dominios distintos: la respuesta autentica el proxy antes de
abrir el agent host, y el ACK autentica el gate antes de que el proxy transmita
tráfico. Sólo esos frames derivados cruzan loopback. La conexión
SSH valida y aplica el `known_hosts` privado al arrancar. Cada comprobación del
relay revalida la identity file de la Machine, la identidad del agent host, el
socket y el hilo de aceptación del gate, y que los procesos SSH y proxy sigan
vivos; además, el gate revalida el agent host antes de abrirlo para cada
conexión autenticada. El proxy valida propietario y modos al crear su directorio
y socket, y al cerrar sólo elimina primero la identidad exacta de socket que
creó y después el mismo directorio si conserva identidad, UID y modo y sigue
vacío. Un fallo de cleanup sale como error del proceso y el coordinador lo
conserva. No se
ofrece confidencialidad frente a un proceso capaz de capturar tráfico loopback
dentro de la VM; esa capacidad queda fuera de esta frontera.

Sólo después de crear el proxy y superar `/usr/bin/ssh-add -l`, el coordinador ejecuta
`devcontainer run-user-commands` con `--container-id <ID-exacto>` y
`--remote-env SSH_AUTH_SOCK=...`. Por tanto, los hooks reciben el mismo socket
ya atestado y no pueden desviarse a otro container resuelto de nuevo. Al
terminar los hooks, repite la sonda de protocolo contra el mismo ID y socket.
Un fallo de los hooks o de esa segunda sonda detiene el lifecycle antes de
abrir el editor. El mismo UID host, root y el principal de sistema del grupo
`daemon` de macOS permanecen dentro del trust boundary del host.

El SSH remoto, el gate y el proxy viven sólo mientras vive el coordinador. Los
stdin de los procesos SSH y proxy funcionan como leash y ambos se supervisan y
recogen; el gate vive dentro del coordinador y se detiene mediante su evento,
cierre del listener y sockets activos, y join de sus hilos. El cleanup sólo
retira sockets y directorios que conservan la identidad creada por ese
lifecycle. La publicación de cada worker del gate se serializa con el cierre,
por lo que el cleanup nunca observa un hilo antes de que `Thread.start()` haya
terminado.
`@devcontainers/cli` sigue montando únicamente el spool mediante su gramática
pública `type=bind,source=...,target=...`; no existe un mount de agent.
Por ello un container compatible puede reutilizarse sin `Recreate` sólo para
adquirir este transporte. Si falta cualquiera de los requisitos anteriores, la
ruta falla cerrada y exige corregir el host, la Machine, la CLI o la imagen y
configuración del container, según corresponda.

Herramientas, PATH, perfiles y sesiones se siguen componiendo desde los adapters
host existentes sobre el snapshot congelado.
