# Shell de devcontainer

La configuración conserva un único flujo de devcontainer: abrir un shell dentro
de un contenedor ya disponible mediante el CLI oficial `devcontainer`. No instala
otra copia de Neovim ni administra sesiones remotas.

## Requisitos

- `devcontainer` disponible en el `PATH` del host.
- El runtime y el contenedor requeridos por el proyecto ya configurados.
- `toggleterm.nvim`, incluido por esta configuración.

## Uso

Abre Neovim dentro del repositorio y ejecuta:

```vim
:DevcontainerShell
```

La configuración busca `.devcontainer/devcontainer.json` desde el directorio
actual hacia sus padres y ejecuta `devcontainer exec --workspace-folder ...` en
un terminal horizontal. El comando vuelve a mostrar u ocultar el mismo terminal.

Para seleccionar explícitamente otro workspace:

```vim
:DevcontainerWorkspace /ruta/al/repositorio
:DevcontainerShell
```

Ejecutar `:DevcontainerWorkspace` sin argumento elimina el override. También se
puede definir `NVIM_DEVCONTAINER_WORKSPACE` antes de arrancar Neovim.

Si el CLI no está disponible o ToggleTerm no puede cargarse, el comando muestra
un error accionable y no modifica el workspace.
