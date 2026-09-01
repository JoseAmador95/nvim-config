# project-python.nvim

Boundary: project Python roots, interpreter resolution, immutable snapshots, precedence, and integration callbacks for Pyright, Neotest, DAP, venv selection, and REPLs. Host commands and UI stay outside.

`setup(opts)` rejects unknown top-level, REPL, and terminal keys before changing
state. `effective_config()` is available before setup, returns caller-owned
defaults, and projects only `test_runner`, `repl`, and `root_markers`; setup
events carry that same callback-free projection. `status()` returns a copied
aggregate with `configured` and all process-local selections, snapshots, and
generations, while `status(root)` keeps the contextual view. `teardown()` clears
that operational state. The runner is restricted to `pytest` or `unittest` and
defaults to `pytest`; REPL readiness defaults to a 5000 ms timeout polled every
50 ms.

The first default `snapshot(root)` publishes a process-local snapshot; later
default reads return that copied snapshot without canonicalizing the root or
rerunning discovery. `select(root, path)`, `clear(root)`, and `refresh(root)` are
the only operational invalidation points. A caller-provided `options.explicit`
is resolved ephemerally: it is returned to that caller without replacing the
default snapshot, advancing its generation, or emitting an event.

Discovery only inspects paths and executable bits; it never starts Python.
Explicit `python.defaultInterpreterPath`, `pythonPath`, `venvPath`, and `venv`
settings are authoritative. `diagnostics(root)` returns every inspected
candidate and validity without changing the selected snapshot. DAP, Pyright,
Neotest, and REPL helpers all consume the same root-bound snapshot.
