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

El lifecycle sólo puede reemplazar la ventana tmux `editor` cuando contiene un
único pane. Primero persiste estado `starting` y después ejecuta
`devcontainer up`; desde ese instante un editor activo pero roto nunca cae al
editor host. `DevContainerHostEditor` es la salida explícita que marca el
registro `stopped` antes de restaurar Neovim host.

`!` transmite autorización de red al runtime como
`NVIM_CONFIG_OFFLINE=0`. Sin `!`, el editor recibe
`NVIM_CONFIG_OFFLINE=1`: `verified-tools.nvim` puede planificar/probar, pero un
claim que requiera red queda `blocked/offline` sin consumir el intento. La CLI
del Dev Container puede necesitar red por la propia imagen o Features del
proyecto; esta configuración no intenta ocultar ni sustituir esa política del
runtime.

La CLI pública es:

```sh
scripts/devcontainer-editor up [--repo RUTA] [--config RUTA] [--recreate] [--allow-network]
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
`$XDG_STATE_HOME/nvim-devcontainer`. El launcher monta únicamente el spool de
ese workspace y esta configuración read-only. Cada mensaje incluye un token
aleatorio, UUID y schema cerrado; symlinks, traversal, permisos amplios,
payloads truncados/sobredimensionados y ACKs con identidad distinta fallan
cerrado. El proceso host que ejecuta `devcontainer exec` reconcilia el outbox
para LazyGit, log, retorno host y refresh de sesión. La publicación no forma
parte del transporte.

Los locks cross-process sólo se recuperan cuando son archivos privados
regulares y su PID propietario ya no existe. Un record `starting`, `running` o
`error` deshabilita fallback. Sólo la ausencia de record o el estado explícito
`stopped` devuelve el código reservado para fallback host.

Si `SSH_AUTH_SOCK` es un socket vivo propiedad del usuario, se monta como socket
y se verifica con `test -S` dentro del container. Si no existe, no se inventa
ni copia ninguna llave. El runtime monta la configuración read-only y lanza
`nvim -u /tmp/nvim-config/init.lua`; herramientas, PATH, perfiles y sesiones se
siguen componiendo desde los adapters host existentes.
