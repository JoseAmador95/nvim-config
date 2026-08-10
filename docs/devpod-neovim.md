# Neovim dentro de DevPod

`scripts/devpod-nvim` mantiene el agente, Git, LazyGit, tmux y tuicr en el host,
y reemplaza únicamente el pane `editor` con Neovim dentro del workspace. Cada
arranque resuelve las últimas releases estables oficiales de DevPod y Neovim;
no acepta prereleases ni fija sus versiones en la configuración. Sólo se
aceptan providers locales `podman` o `docker`.

## Preparación del provider

El launcher crea el contexto dedicado `nvim-devpod`, pero no instala un motor
de contenedores ni registra providers implícitamente. Para Podman:

```sh
devpod --context nvim-devpod provider add docker \
  --name podman \
  -o DOCKER_PATH="$(command -v podman)"
```

El equivalente para Docker usa `--name docker` y su ruta absoluta. La selección
de provider y `devcontainer.json` se guarda por repositorio en estado privado;
el ID del workspace incluye repositorio, provider y config. Si hay más de un
`devcontainer.json`, hay que elegirlo explícitamente con `--config`.
Al entrar en el workflow, el contexto dedicado fija
`SSH_INJECT_GIT_CREDENTIALS=false`, `SSH_INJECT_DOCKER_CREDENTIALS=false` y
`GPG_AGENT_FORWARDING=false`, `SSH_ADD_PRIVATE_KEYS=false`,
`SSH_AGENT_FORWARDING=true` y `GIT_SSH_SIGNATURE_FORWARDING=false`; crear el
contexto no cambia permanentemente el contexto default que ya tenía el usuario.
Sólo se forwardea el agente que ya está cargado en `SSH_AUTH_SOCK`: no se copian
ni se buscan llaves privadas en `~/.ssh`.

Algunas releases de DevPod no aplican por sí solas el build arg automático
`TARGETARCH` al inspeccionar etapas parametrizadas del Dockerfile. Por ejemplo,
pueden interpretar mal `FROM base-$TARGETARCH`. Si el proyecto no declara ese
arg en `build.args` y en el preámbulo del Dockerfile, el
launcher genera un overlay privado y determinista bajo su estado, copia allí el
Dockerfile, completa ambos valores y pasa la arquitectura efectiva (`arm64` o
`amd64`) sin escribir en el repo. Un `credsStore` de
Docker cuyo helper ya no existe se sustituye por una config privada vacía sólo
si no contiene auths ni helpers por registro; credenciales existentes hacen que
el flujo falle cerrado.

Si existe una configuración Git global, el mismo overlay monta su archivo real
en `/tmp/nvim-devpod-host.gitconfig` como bind read-only y Neovim exporta
`GIT_CONFIG_GLOBAL` a sus terminales y procesos. El montaje no incluye `~/.ssh`
ni credential helpers de DevPod. Su ruta forma parte de la identidad del
workspace para no reutilizar un contenedor creado sin ese contrato.

## Uso

Desde el palette global de tmux (`Alt-Space`), elige `editor: DevPod`. También
puedes reemplazar el pane actual desde Neovim:

```vim
:DevPodUp
:DevPodUp!
:DevPodRecreate
:DevPodRecreate!
```

El `!` autoriza la consulta de las releases estables actuales y, si hace falta,
la descarga verificada de Neovim y el bootstrap de plugins. Sin `!`, el launcher
pregunta si posee un TTY; responder que no hace que falle cerrado porque sin red
no puede garantizar que ambas versiones sean las más actuales. En automatización
se usa `--allow-network`. `devpod up` puede además usar la red del provider para
descargar la imagen o Features del proyecto. `:HostEditor` regresa explícitamente
a Neovim del host. Salir
normalmente del editor del container deja el pane detenido por
`remain-on-exit`; no relanza nada.

El launcher escribe etapas y un heartbeat periódico en stderr mientras
`devpod up` está construyendo o reutilizando el workspace; la salida JSON de
automatización permanece limpia en stdout. También conserva el último registro
por workspace en estado privado (máximo 256 KiB, modo `0600`, poda a los 30
días); ya dentro del container, `:DevPodLog` lo abre en un popup del host.

La terminal general (`<leader>t`) pasa `<Tab>` y `<S-Tab>` literalmente al
shell. Dentro de DevPod abre explícitamente Bash interactivo con un rc mínimo de
esta configuración: carga primero el `.bashrc` de la imagen y después activa su
`bash-completion` si venía deshabilitado; fuera del container conserva el shell
configurado en el host. Esto no requiere montar dotfiles adicionales. Se puede
añadir después un rc personal acotado si se quieren aliases o prompt propios,
sin montar todo `~/.ssh` ni los dotfiles del host.

La CLI pública es:

```sh
scripts/devpod-nvim up [--provider podman|docker] [--config RUTA] [--recreate]
scripts/devpod-nvim host [--repo RUTA]
scripts/devpod-nvim exec [--cwd RUTA] -- programa argumento...
scripts/devpod-nvim status --json [--repo RUTA]
scripts/devpod-nvim log [--repo RUTA] [--pager]
scripts/devpod-nvim open-location --cwd RUTA --file ARCHIVO --line 1 --column 1
```

`up` falla cerrado fuera de la ventana tmux `editor` cuando ésta no contiene
exactamente un pane; así nunca reemplaza agent, Git o una terminal por error.

`exec --` conserva cada argumento y lo entrega a `vim.system(argv)` dentro del
editor; no construye un comando de shell. `open-location` sólo traduce rutas
relativas dentro del mapping host/container registrado. El selector de tmux
prueba primero este bridge y consulta el editor host sólo cuando la CLI devuelve
su código específico de “no hay editor DevPod activo”.

## Bootstrap y límites

La configuración se archiva desde su commit `HEAD`, se verifica por SHA-256, se
copia fuera del proyecto y queda read-only en el workspace. El modo
`--experimental-dirty-config` copia únicamente archivos tracked regulares y
excluye configuración local; nunca es el default. `--recreate` vuelve a aplicar
la snapshot.

El launcher consulta `releases/latest` de ambos proyectos. El binario DevPod del
host debe reportar exactamente la última versión estable; si falta o está
desactualizado, el flujo pide actualizarlo con el package manager del host y no
lo sustituye automáticamente. DevPod no publica todavía un digest SHA-256 para
ese asset que permita conservar el mismo límite de confianza del fallback.

Dentro de la imagen se reutiliza Neovim sólo si reporta exactamente la última
versión estable. Si no, el launcher descarga el tar oficial Linux correspondiente
a arm64/x86_64 y verifica tanto el SHA-256 como el tamaño publicados por GitHub
antes de instalarlo en el estado privado del workspace. `cc` es obligatorio. No
instala npm, Go, Cargo, compiladores ni package managers. El bootstrap de plugins
usa el lock existente y se repite cuando cambia la release efectiva de Neovim.

Las conexiones de control desactivan agent/GPG forwarding y los credential
services de DevPod. Sólo la conexión que posee el Neovim interactivo habilita el
SSH agent del host; GPG, inyección de llaves y servicios de credenciales siguen
deshabilitados. Los sockets Unix y registros del host son privados (directorios
`0700`, archivos `0600`). Para conservar compatibilidad entre releases, el
bridge host→editor termina en un puerto TCP aleatorio ligado únicamente a
`127.0.0.1` dentro del container; nunca se publica fuera de él. El bridge inverso
conserva Unix→Unix. `:TuicrReview`
delega al popup host; `:LazyGit` selecciona la ventana host. Lualine y el frame
de tmux muestran `DevPod · provider · project`.

El launcher calcula una huella Git antes y después de `devpod up`. No modifica
el proyecto por cuenta propia; si un lifecycle hook declarado por el proyecto
lo cambia, lo informa y no intenta rollback.
