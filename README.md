# Python UV Container Utils

A Nix flake providing utilities for building Python containers using the UV
package manager.

## How images are layered

`uv2container.buildImage` splits the runtime environment into several small
venvs, overlaid at runtime via `PYTHONPATH`, and ships each as its own OCI
layer (most stable first):

1. **python + runtime libs** — rebuilt only when nixpkgs inputs change.
2. **per-package envs** (`dependencyLayers = "auto"`, the default) — every
   package whose largest artifact in `uv.lock` reaches
   `autoLayerThresholdMB` (default 32), plus every sdist-only package (a
   source tarball's size says nothing about its installed size), gets its
   own venv/layer. Derived entirely from the lock: nothing to declare or
   keep in sync. Each layer's input is a content-addressed pylock filter,
   so lock changes that don't touch a package do **not** rebuild its layer.
   Explicit masks (`dependencyLayers = { heavy = ["torch"]; }`, closures
   from the lock graph) and `"flat"` exist as escape hatches. Layering only
   places packages that ship anyway via the members' real dependency
   declarations — it never adds anything; uv dependency groups are dev-only
   (PEP 735) and are never consulted or shipped (`--no-default-groups`).
3. **deps env** — the remainder. Rebuilt on lock changes; small because
   everything big has its own layer.
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
| `uv.lock`, big packages untouched | deps env + affected member envs (seconds) |
| a big package's pin | that package's layer only |

Extensions built from sdists get their build-only toolchain references
(DWARF debug paths to gcc/glibc-dev) scrubbed with `remove-references-to`,
so a stray sdist build doesn't pull the compiler closure into a layer.

## Usage

Add this flake to your inputs and call
`x2container.lib.${system}.uv2container.buildImage`; see `examples/flask-app`
and the argument list in `flake.nix`.

Note: builds use `__noChroot` (network access for wheel downloads), so nix
needs `sandbox = relaxed` (or `--option sandbox relaxed` as a trusted user)
and the `ca-derivations` experimental feature.
