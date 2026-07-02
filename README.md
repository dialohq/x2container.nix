# Python UV Container Utils

A Nix flake providing utilities for building Python containers using the UV
package manager.

## How images are layered

`uv2container.buildImage` splits the runtime environment into several small
venvs, overlaid at runtime via `PYTHONPATH`, and ships each as its own OCI
layer (most stable first):

1. **python + runtime libs** — rebuilt only when nixpkgs inputs change.
2. **heavy group env** (optional, `cacheGroupName`) — a venv holding only the
   named dependency group's closure (e.g. torch + CUDA wheels). Its input is a
   content-addressed `uv export --frozen --format pylock.toml --only-group
   <name>` derivation, so `uv.lock` changes that don't touch the group's pins
   do **not** rebuild it.
3. **deps env** — everything else from `uv.lock` (`--all-packages
   --no-emit-workspace`, minus the heavy group's package names). Rebuilt on
   any lock change; cheap because the heavy artifacts are excluded.
4. **one env per workspace member** — built with `uv pip install --no-deps
   ./<member>`, keyed only on that member's sources (plus workspace
   pyprojects). Editing one member never rebuilds another, so pure-Python
   edits don't retrigger native (e.g. maturin/cargo) member builds.
5. **sources layer** — files matching `filesetFilter` (default: `*.py`)
   copied to the image root.

Layers are chained with `nix2container.buildLayer { layers = [...] }` so every
store path ships exactly once.

`uv sync` is not used. All installs are `uv pip install --no-deps -r
pylock.toml`: the pylock export pins the exact artifact URL and hash for every
package straight from `uv.lock`, so nothing is ever re-resolved against an
index (this also makes packages that exist on several indexes with different
bytes, like triton on pypi vs the pytorch index, impossible to mix up) and
every artifact hash is verified.

Rebuild behaviour in practice:

| change | rebuilds |
| --- | --- |
| source file of member M | member M env + sources layer (seconds) |
| `uv.lock`, heavy pins untouched | deps env + affected member envs (seconds) |
| heavy group pins | heavy env (downloads the heavy wheels once) |

## Usage

Add this flake to your inputs and call
`x2container.lib.${system}.uv2container.buildImage`; see `examples/flask-app`
and the argument list in `flake.nix`.

Note: builds use `__noChroot` (network access for wheel downloads), so nix
needs `sandbox = relaxed` (or `--option sandbox relaxed` as a trusted user)
and the `ca-derivations` experimental feature.
