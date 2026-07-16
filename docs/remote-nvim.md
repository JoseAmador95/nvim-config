# remote-nvim — desarrollo remoto (estilo VSCode Remote-SSH)

`remote-nvim` ([amitds1997/remote-nvim.nvim](https://github.com/amitds1997/remote-nvim.nvim))
lanza un Neovim *headless* en un host remoto y conecta tu TUI local a él. Toda esta
config se copia al remoto, así que trabajas con el mismo entorno (plugins, LSP, atajos)
que en local, pero editando ficheros del host remoto.

El spec vive en [`lua/plugins/remote-nvim.lua`](../lua/plugins/remote-nvim.lua).

## Requisitos

**En tu máquina local:**
- `ssh`, `curl` y `nvim`.
- `devpod` >= 0.5.0 (opcional, solo si quieres devcontainers).

**En el host remoto:**
- Servidor SSH accesible.
- `bash` y `curl` (o `wget`).
- Conectividad a GitHub (para descargar Neovim/mason en el primer arranque), salvo que
  uses un modo offline.

## Paso 1 — define el host en `~/.ssh/config`

remote-nvim **solo** lee los hosts de tu `~/.ssh/config` (así está configurado en
`lua/plugins/remote-nvim.lua`, opción `ssh_config_file_paths`). Añade una entrada:

```ssh-config
Host mi-servidor
    HostName 192.168.1.50
    User jose
    IdentityFile ~/.ssh/id_ed25519
```

Comprueba que conectas a mano antes de seguir: `ssh mi-servidor`.

## Paso 2 — conecta

En Neovim (terminal, no VSCode) ejecuta `:RemoteStart` o pulsa `<leader>Rs`.

**Ojo — son dos pasos:** `:RemoteStart` **no** muestra tus hosts directamente. Primero
abre un menú de Telescope titulado **"Filter launch options"** con los *métodos* de
conexión. Elige **"Remote SSH: Set up configured SSH host"** (escribe `ssh` para filtrar
y pulsa Enter). Solo entonces se abre el segundo picker, **"Connect to remote host"**,
con los hosts de tu `~/.ssh/config`; elige uno.

Otras opciones de ese menú:
- **"Remote SSH: Set up using connection string"** — escribe `usuario@host` a mano.
- **"Remote Neovim: Connect to existing workspace"** — solo lista hosts a los que ya te
  conectaste antes.

Atajo: una vez conectado a un host, `:RemoteStart <nombre>` (p.ej. `:RemoteStart media`)
conecta directo sin pasar por el menú. La primera vez sí hay que usar el menú.

> La **primera vez** contra un host, remote-nvim copia esta config al remoto e instala
> Neovim + los servers/tools de mason allí. Tarda un rato. Las siguientes veces es
> mucho más rápido porque reutiliza lo ya instalado.

## Paso 3 — trabaja

Cuando termina, tienes una TUI conectada al Neovim remoto: abres ficheros, corres LSP,
etc., todo en el host remoto.

- Los ajustes por host van en `~/.nvim-local.lua`, que vive en el `$HOME` del **remoto**
  (fuera de la config copiada), así que cada host mantiene su configuración local propia.

## Comandos y atajos

Todos los atajos están agrupados como **`remote`** en which-key bajo `<leader>R`.

| Atajo         | Comando            | Qué hace                                  |
| ------------- | ------------------ | ----------------------------------------- |
| `<leader>Rs`  | `:RemoteStart`     | Iniciar / conectar a un host              |
| `<leader>Rx`  | `:RemoteStop`      | Detener la sesión remota                  |
| `<leader>Ri`  | `:RemoteInfo`      | Ver info de la sesión activa              |
| `<leader>Rc`  | `:RemoteCleanup`   | Limpiar lo instalado en el host remoto    |
| `<leader>Rd`  | `:RemoteConfigDel` | Borrar la config guardada de un host      |
| `<leader>Rl`  | `:RemoteLog`       | Abrir el log de remote-nvim               |

También aparecen en `:Cheatsheet commands`.

## Diagnóstico y ciclo de vida

- `:checkhealth remote-nvim` — verifica dependencias locales y remotas.
- `:RemoteInfo` / `:RemoteLog` — estado de la sesión y logs si algo falla.
- **Cerrar**: `:RemoteStop` (`<leader>Rx`) termina la sesión sin borrar nada del host.
- **Limpiar host**: `:RemoteCleanup` (`<leader>Rc`) elimina lo que remote-nvim instaló
  en el remoto.
- **Olvidar host**: `:RemoteConfigDel` (`<leader>Rd`) borra la config guardada de un
  host (útil si cambian sus datos de conexión).

## Si no aparecen tus hosts

- **Lo más común:** `:RemoteStart` muestra primero los *métodos* de conexión, no los
  hosts. Entra en **"Remote SSH: Set up configured SSH host"** para ver los de
  `~/.ssh/config` (ver [Paso 2](#paso-2--conecta)).
- Los bloques comodín (`Host *`, `Host *.ejemplo.com`) **no se listan** a propósito;
  necesitas al menos un alias concreto (`Host mi-servidor`).
- Solo se leen los bloques `Host` de `~/.ssh/config` (y de los archivos que incluyas con
  `Include`), **no** de `~/.ssh/known_hosts` ni de conexiones sueltas `ssh usuario@ip`.
- Si tus hosts están en otro archivo, amplía `ssh_config.ssh_config_file_paths` en
  `lua/plugins/remote-nvim.lua`.

## Devcontainers (devpod)

remote-nvim también puede lanzar el Neovim *headless* **dentro de un
devcontainer** (usando [devpod](https://devpod.sh) por debajo) y conectar tu TUI
local a él. Así editas con LSP y herramientas que ven las dependencias del
contenedor, con esta misma config.

### Escenarios

- **Devcontainer local** (Docker/OrbStack en tu máquina) → este flujo (devpod).
- **Host remoto sin contenedor** → el flujo SSH de arriba (`~/.ssh/config`).
- **Devcontainer en un host remoto** (anidado) → avanzado: hay que configurar un
  proveedor Docker remoto en devpod. No cubierto aquí.

### Requisitos

- [`devpod`](https://devpod.sh) >= 0.5.0 en el PATH (`brew install devpod`).
- Un runtime de contenedores local: **Podman**, **OrbStack** o **Docker Desktop**.
- Verifica antes de empezar: `devpod version` y `podman ps` (o `docker ps`)
  responden.

#### Podman

Con podman hay que apuntar **dos** cosas a podman (ambas usan `docker` por
defecto):

1. **remote-nvim** — ya resuelto en `lua/plugins/remote-nvim.lua`: usa `podman`
   como `docker_binary` si está instalado (si no, `docker`).
2. **devpod** — configura una vez su proveedor docker para que use podman. En la
   GUI de DevPod: pestaña *Providers* → proveedor Docker → opción **Docker Path**
   → cámbiala de `docker` a `podman` (o la ruta de `which podman`). Por CLI, el
   equivalente es la opción `DOCKER_PATH` del proveedor docker; confirma el nombre
   exacto con `devpod provider options docker` y ajústala a `podman`.
   - Podman **rootless**: si al montar el workspace hay líos de permisos/UID,
     suele ayudar `--userns=keep-id`, y exponer el socket de podman apuntando
     `DOCKER_HOST` a él. Ver los enlaces de podman+devcontainers si te topas con
     esto.

### Flujo

1. Abre Neovim en la **raíz del repo** (donde está `.devcontainer/`). devpod
   busca el devcontainer en el directorio actual, así que arrancar desde la raíz
   es lo fiable.
2. `:RemoteStart` (`<leader>Rs`) → en el menú **"Filter launch options"** elige la
   opción de **Dev Container** (aparece solo si `devpod` está en el PATH y hay un
   `.devcontainer/devcontainer.json`).
3. La **primera vez** devpod construye el contenedor y remote-nvim instala
   Neovim + los servers/tools de mason **dentro**. Tarda; las siguientes veces es
   rápido.
4. Cuando termina, tu TUI está conectada al Neovim del contenedor.

### Reconectar, cerrar y limpiar

- **Reconectar**: `:RemoteStart <workspace>` va directo sin pasar por el menú. Con
  `container_list = "all"` (configurado en `lua/plugins/remote-nvim.lua`) también
  se reengancha a contenedores **parados**, sin reconstruir.
- **Cerrar**: `:RemoteStop` (`<leader>Rx`).
- **Limpiar**: `:RemoteCleanup` (`<leader>Rc`) elimina lo instalado en el
  contenedor.

### Si al contenedor le falta una herramienta

Añádela al `devcontainer.json` (un *feature* o un paquete) y reconstruye. Así el
entorno sigue siendo reproducible, en vez de depender de binarios de tu host.

### Clipboard

Funciona vía **OSC52** (ya configurado en `init.lua`): como el contenedor se
alcanza por SSH, el yank llega a tu portapapeles local. Requiere un terminal que
soporte OSC52 (iTerm2, kitty, WezTerm, Ghostty, Alacritty). Con tmux:
`set -g set-clipboard on`.

### Shell rápido (alternativa sin remote-nvim)

Para solo abrir un shell dentro del contenedor sin montar toda la sesión remota,
`:DevcontainerShell` sigue disponible (usa `devcontainer exec`; es independiente
de remote-nvim). `:DevcontainerWorkspace` fija/limpia el workspace que usa.

## Notas

- El plugin está protegido con `cond = not vim.g.vscode`: dentro de vscode-neovim no se
  carga (usa el propio Remote-SSH de VSCode en su lugar).
- Al ser *lazy*, remote-nvim solo se carga la primera vez que usas uno de sus comandos o
  atajos.
