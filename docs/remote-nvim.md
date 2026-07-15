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

## Notas

- El plugin está protegido con `cond = not vim.g.vscode`: dentro de vscode-neovim no se
  carga (usa el propio Remote-SSH de VSCode en su lugar).
- Al ser *lazy*, remote-nvim solo se carga la primera vez que usas uno de sus comandos o
  atajos.
