{
  description = "Python + UV container build utilities";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix2container.url = "github:dialohq/nix2container/compressed-layers";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    nix2container,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
      n2c = nix2container.packages.${system}.nix2container;

      lib = {
        uv2container = rec {
          # Export a pinned pylock.toml (+ package-name list) from uv.lock.
          # Content-addressed: lock changes that leave the exported set
          # untouched don't rebuild downstream derivations.
          exportRequirements = {
            python,
            src,
            name ? "requirements",
            exportArgs ? [],
            # Derivations (from exportRequirements) whose packages.txt are
            # subtracted from this export.
            excludeFrom ? [],
            extraBuildInputs ? [],
          }:
            pkgs.stdenv.mkDerivation {
              name = "${name}-requirements";
              inherit src;
              __noChroot = true;
              __contentAddressed = true;
              dontFixup = true;
              nativeBuildInputs = [python pkgs.uv] ++ extraBuildInputs;
              buildPhase = ''
                runHook preBuild
                export UV_CACHE_DIR="$TMPDIR/.uv_cache"
                export UV_PYTHON_PREFERENCE="only-system"
                export UV_PYTHON="${python}/bin/python${python.pythonVersion}"
                mkdir -p $out

                exclude_args=()
                ${
                  pkgs.lib.concatMapStrings (d: ''
                    while IFS= read -r p; do
                      [ -n "$p" ] && exclude_args+=(--no-emit-package "$p")
                    done < ${d}/packages.txt
                  '')
                  excludeFrom
                }
                uv export --locked --format pylock.toml --no-annotate --no-header \
                  ${pkgs.lib.escapeShellArgs exportArgs} "''${exclude_args[@]}" \
                  -o $out/pylock.toml
                python3 -c '
                import sys, tomllib
                with open(sys.argv[1], "rb") as f:
                    data = tomllib.load(f)
                for name in sorted({p["name"] for p in data.get("packages", [])}):
                    print(name)
                ' $out/pylock.toml > $out/packages.txt
                runHook postBuild
              '';
            };

          # Extensions built from sdists embed build-only toolchain store
          # paths (debug info / comments); null them so venv layers don't
          # drag the compiler closure into the image.
          scrubToolchainReferences = ''
            find "$out" -type f -name '*.so*' -print0 \
              | xargs -0 --no-run-if-empty remove-references-to \
                -t ${pkgs.stdenv.cc} \
                -t ${pkgs.stdenv.cc.cc} \
                -t ${pkgs.lib.getDev pkgs.stdenv.cc.libc}
          '';

          # Venv with exactly the packages of a pylock export; no resolution
          # at install time.
          buildVenvFromRequirements = {
            python,
            name,
            requirements,
            extraBuildInputs ? [],
            # { packageName = [ file globs ]; }: files deleted from the venv
            # shipping that package.
            prunePackageFiles ? {},
          }:
            pkgs.stdenv.mkDerivation {
              inherit name;
              NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              dontUnpack = true;
              __noChroot = true;
              dontFixup = true;
              nativeBuildInputs = [python pkgs.uv pkgs.removeReferencesTo] ++ extraBuildInputs;
              buildPhase = ''
                runHook preBuild
                export UV_CACHE_DIR="$TMPDIR/.uv_cache"
                export UV_PYTHON_PREFERENCE="only-system"
                export UV_PYTHON="${python}/bin/python${python.pythonVersion}"
                uv venv "$out"
                if [ -s ${requirements}/packages.txt ]; then
                  uv pip install --python "$out/bin/python" --no-deps \
                    -r ${requirements}/pylock.toml
                fi
                ${pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList (pkg: patterns: ''
                    if grep -qxF ${pkgs.lib.escapeShellArg pkg} ${requirements}/packages.txt; then
                      echo "pruning files of ${pkg}"
                      find "$out" \( ${pkgs.lib.concatMapStringsSep " -o " (p: "-name ${pkgs.lib.escapeShellArg p}") patterns} \) -print -delete
                    fi
                  '')
                  prunePackageFiles)}
                ${scrubToolchainReferences}
                runHook postBuild
              '';
            };

          # Venv with a single workspace member, keyed only on that member's
          # sources.
          buildMemberEnv = {
            python,
            name,
            src,
            memberPath,
            extraBuildInputs ? [],
            # Optional derivation holding a prebuilt wheel (dir with *.whl).
            # When set, the member is installed from that wheel instead of
            # being built from source, and the env is keyed only on the wheel
            # (member sources don't invalidate it). Use for members whose
            # from-source build is expensive to cache — e.g. a maturin/Rust
            # extension whose compiled dependencies live in their own layer.
            wheel ? null,
          }:
            pkgs.stdenv.mkDerivation ({
              inherit name;
              NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              __noChroot = true;
              dontFixup = true;
              nativeBuildInputs = [python pkgs.uv pkgs.removeReferencesTo] ++ extraBuildInputs;
              buildPhase = ''
                runHook preBuild
                export UV_CACHE_DIR="$TMPDIR/.uv_cache"
                export UV_PYTHON_PREFERENCE="only-system"
                export UV_PYTHON="${python}/bin/python${python.pythonVersion}"
                uv venv "$out"
                ${
                  if wheel != null
                  then ''
                    shopt -s nullglob
                    wheels=(${wheel}/*.whl)
                    if [ ''${#wheels[@]} -ne 1 ]; then
                      echo "expected exactly one wheel in ${wheel}, found ''${#wheels[@]}: ''${wheels[*]}" >&2
                      exit 1
                    fi
                    uv pip install --python "$out/bin/python" --no-deps "''${wheels[0]}"
                  ''
                  else ''uv pip install --python "$out/bin/python" --no-deps ./${memberPath}''
                }
                ${scrubToolchainReferences}
                runHook postBuild
              '';
            }
            // (
              if wheel != null
              then {dontUnpack = true;}
              else {inherit src;}
            ));

          defaultFilesetFilter = file: file.hasExt "py";

          buildImage = {
            name,
            python,
            src,
            members ? [],
            extraBuildInputs ? [],
            baseImage ? {},
            runtimeLibs ? [],
            libs ? [],
            extraLdLibraryPath ? "",
            extraLibraryPath ? "",
            filesetFilter ? defaultFilesetFilter,
            config ? {},
            extraLayers ? [],
            runtimeExecutableDeps ? [],
            # Map of member path -> derivation holding a prebuilt wheel. Listed
            # members install from their wheel instead of building from source
            # (see buildMemberEnv's `wheel`), so an expensive compile lives in
            # its own cached derivation/layer keyed on the wheel.
            memberWheels ? {},
            # How third-party dependencies are split into image layers:
            #   "auto" (default) — every package whose largest artifact in
            #     uv.lock is at least autoLayerThresholdMB gets its own layer;
            #     the remainder forms one layer. Derived entirely from the
            #     lock: nothing to declare, nothing to keep in sync.
            #   "flat" — one layer with the entire dependency set;
            #   { name = [ "pkg" .. ]; .. } — one layer per mask (alphabetical
            #     by name) holding the uv.lock dependency closure of the
            #     listed packages ∩ the shipped set, minus packages claimed by
            #     earlier layers; the remainder forms its own layer.
            # Layering only places packages that ship anyway (via the members'
            # real dependency declarations) — it never adds anything.
            dependencyLayers ? "auto",
            autoLayerThresholdMB ? 32,
            # Optional build-time self-test command (argv list), run with the
            # image's runtime environment; the image build fails if it fails.
            imageCheck ? null,
            # { packageName = [ file globs ]; } deleted from the venv shipping
            # that package (e.g. build-only payloads of runtime-consumed
            # packages).
            prunePackageFiles ? {},
            imageCheckEnv ? {},
          }: let
            inherit (pkgs.lib) fileset;

            sitePackages = env: "${env}/lib/python${python.pythonVersion}/site-packages";

            # Only metadata: member sources must not invalidate dependency
            # layers. uv validates the lock against the WHOLE workspace, so
            # every workspace member's pyproject must be present — not only
            # the members shipped in this image. (Literal member paths only;
            # glob members in [tool.uv.workspace] are not expanded.)
            pyprojectFiles = let
              rootPyproject = src + "/pyproject.toml";
              workspaceMembers =
                if builtins.pathExists rootPyproject
                then ((((builtins.fromTOML (builtins.readFile rootPyproject)).tool or {}).uv or {}).workspace or {}).members or []
                else [];
            in
              builtins.filter builtins.pathExists (
                [rootPyproject]
                ++ builtins.map (m: src + "/${m}/pyproject.toml")
                (pkgs.lib.unique (workspaceMembers ++ members))
              );
            metadataFiles =
              builtins.filter builtins.pathExists [(src + "/uv.lock")]
              ++ pyprojectFiles;
            metadataSrc = fileset.toSource {
              root = src;
              fileset = fileset.unions metadataFiles;
            };

            # Exact-package masks derived from uv.lock. A package gets its own
            # layer if any artifact reaches the threshold, or if it is
            # sdist-only: a source tarball's size says nothing about the
            # installed size and its build is the most expensive to redo.
            autoMasks = let
              lock = builtins.fromTOML (builtins.readFile (src + "/uv.lock"));
              maxWheel = p:
                builtins.foldl' (a: b:
                  if b > a
                  then b
                  else a)
                0 (builtins.map (w: w.size or 0) (p.wheels or []));
              sdistOnly = p: (p.wheels or []) == [] && p ? sdist;
              big =
                builtins.filter
                (p: maxWheel p >= autoLayerThresholdMB * 1024 * 1024 || sdistOnly p)
                (lock.package or []);
            in
              builtins.listToAttrs (builtins.map (p: {
                  inherit (p) name;
                  value = [p.name];
                })
                big);

            # true = mask entries are closure seeds; false = exact packages.
            masksAreClosures = builtins.isAttrs dependencyLayers;
            layerMasks =
              if dependencyLayers == "flat"
              then {}
              else if dependencyLayers == "auto"
              then autoMasks
              else if builtins.isAttrs dependencyLayers
              then dependencyLayers
              else throw "dependencyLayers must be \"auto\", \"flat\", or an attrset of { layerName = [ package names ]; }";

            allShippedRequirements = exportRequirements {
              inherit python extraBuildInputs;
              src = metadataSrc;
              name = "all-shipped";
              exportArgs = ["--all-packages" "--no-emit-project" "--no-emit-workspace" "--no-default-groups"];
            };

            # Filter the shipped set down to the uv.lock dependency closure of
            # the mask's package names, minus packages claimed by earlier
            # layers. Pure lock-graph computation: masks never add packages.
            closureRequirements = {
              name,
              seeds,
              expandClosure,
              excludeFrom ? [],
            }:
              pkgs.stdenv.mkDerivation {
                name = "${name}-requirements";
                src = metadataSrc;
                __contentAddressed = true;
                dontFixup = true;
                nativeBuildInputs = [python];
                EXPAND_CLOSURE =
                  if expandClosure
                  then "1"
                  else "";
                buildPhase = ''
                  runHook preBuild
                  mkdir -p $out
                  cat ${pkgs.lib.escapeShellArgs (builtins.map (d: "${d}/packages.txt") excludeFrom)} /dev/null > claimed.txt
                  python3 - uv.lock ${allShippedRequirements}/pylock.toml claimed.txt \
                    ${pkgs.lib.escapeShellArgs seeds} <<'PYEOF'
                  import os, re, sys, tomllib

                  norm = lambda n: re.sub(r"[-_.]+", "-", n).lower()
                  lock_path, pylock_path, claimed_path, *seeds = sys.argv[1:]

                  closure = {norm(s) for s in seeds}
                  if os.environ.get("EXPAND_CLOSURE"):
                      lock = tomllib.load(open(lock_path, "rb"))
                      edges = {}
                      for p in lock.get("package", []):
                          deps = [d["name"] for d in p.get("dependencies", [])]
                          for extra in p.get("optional-dependencies", {}).values():
                              deps += [d["name"] for d in extra]
                          edges[norm(p["name"])] = {norm(d) for d in deps}
                      todo = list(closure)
                      closure = set()
                      while todo:
                          n = todo.pop()
                          if n in closure:
                              continue
                          closure.add(n)
                          todo += edges.get(n, ())

                  claimed = {norm(l.strip()) for l in open(claimed_path) if l.strip()}

                  text = open(pylock_path).read()
                  blocks = text.split("[[packages]]")
                  header, entries = blocks[0], blocks[1:]
                  kept, names = [], []
                  for b in entries:
                      name = norm(tomllib.loads("[[packages]]" + b)["packages"][0]["name"])
                      if name in closure and name not in claimed:
                          kept.append(b)
                          names.append(name)

                  with open("out-pylock.toml", "w") as f:
                      f.write(header + "".join("[[packages]]" + b for b in kept))
                  with open("out-packages.txt", "w") as f:
                      f.write("".join(n + "\n" for n in sorted(set(names))))
                  PYEOF
                  mv out-pylock.toml $out/pylock.toml
                  mv out-packages.txt $out/packages.txt
                  runHook postBuild
                '';
              };

            groupExports = builtins.foldl' (acc: lname:
              acc
              ++ [
                {
                  group = lname;
                  export = closureRequirements {
                    name = "layer-${lname}";
                    seeds = layerMasks.${lname};
                    expandClosure = masksAreClosures;
                    excludeFrom = builtins.map (ge: ge.export) acc;
                  };
                }
              ]) []
            (builtins.attrNames layerMasks);

            groupEnvs =
              builtins.map (ge:
                buildVenvFromRequirements {
                  inherit python extraBuildInputs prunePackageFiles;
                  name = "env-${ge.group}";
                  requirements = ge.export;
                })
              groupExports;

            depsRequirements = exportRequirements {
              inherit python extraBuildInputs;
              src = metadataSrc;
              name = "deps";
              exportArgs = ["--all-packages" "--no-emit-project" "--no-emit-workspace" "--no-default-groups"];
              excludeFrom = builtins.map (ge: ge.export) groupExports;
            };

            depsEnv = buildVenvFromRequirements {
              inherit python extraBuildInputs prunePackageFiles;
              name = "env-deps";
              requirements = depsRequirements;
            };

            # Excludes members nested under m so they don't invalidate it.
            memberFileset = m: let
              nested =
                builtins.filter
                (o: o != m && pkgs.lib.hasPrefix "${m}/" o)
                members;
            in
              if nested == []
              then src + "/${m}"
              else
                fileset.difference
                (src + "/${m}")
                (fileset.unions (builtins.map (o: src + "/${o}") nested));

            memberEnvs =
              builtins.map (m:
                buildMemberEnv {
                  inherit python extraBuildInputs;
                  name = "member-${builtins.replaceStrings ["/"] ["-"] m}";
                  # Pyprojects needed for `workspace = true` sources; uv.lock
                  # deliberately excluded (installs are --no-deps).
                  src = fileset.toSource {
                    root = src;
                    fileset = fileset.unions (pyprojectFiles ++ [(memberFileset m)]);
                  };
                  memberPath = m;
                  wheel = memberWheels.${m} or null;
                })
              members;

            pythonEnvs = memberEnvs ++ [depsEnv] ++ groupEnvs;

            sourcesLayer =
              fileset.toSource
              {
                root = src;
                fileset = fileset.fileFilter filesetFilter src;
              };

            defaultEnv = [
              ("PYTHONPATH="
                + pkgs.lib.concatMapStringsSep ":" sitePackages pythonEnvs
                + ":${sitePackages python}")
              ("PATH="
                + pkgs.lib.concatMapStringsSep ":" (env: "${env}/bin") pythonEnvs
                + ":${python}/bin:/bin:/usr/bin:"
                + (pkgs.lib.strings.concatMapStringsSep ":" (dep: "${dep}/bin") runtimeExecutableDeps))
              (
                "LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath ([pkgs.stdenv.cc.cc.lib] ++ runtimeLibs)}"
                + extraLdLibraryPath
              )
              (
                "LIBRARY_PATH=${pkgs.lib.makeLibraryPath ([pkgs.stdenv.cc.cc.lib] ++ libs)}"
                + extraLibraryPath
              )
            ];

            # Build-time self-test: runs imageCheck with the image's runtime
            # environment (PYTHONPATH overlay, PATH, libraries, sources as
            # cwd). Catches "declared but not shipped" dependencies before
            # anything reaches a registry.
            imageCheckDrv =
              if imageCheck == null
              then null
              else
                pkgs.runCommand "${name}-image-check" {} ''
                  ${pkgs.lib.concatMapStrings (e: ''
                    export ${pkgs.lib.escapeShellArg e}
                  '')
                  defaultEnv}
                  export PATH="$PATH:${pkgs.coreutils}/bin"
                  export HOME="$TMPDIR"
                  ${pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList (k: v: ''
                      export ${k}=${pkgs.lib.escapeShellArg v}
                    '')
                    imageCheckEnv)}
                  cd ${sourcesLayer}
                  ${pkgs.lib.escapeShellArgs imageCheck}
                  touch $out
                '';

            # Each env layer holds exactly its own venv: venvs are disjoint by
            # construction (contents partitioned by name), so deduplication
            # only needs to exclude the shared python/runtimeLibs closure.
            pythonLayer = n2c.buildLayer {
              deps = [python] ++ runtimeLibs;
              compress = "gzip";
            };
            envLayer = env:
              n2c.buildLayer {
                deps = [env];
                layers = [pythonLayer];
                compress = "gzip";
              };
            groupImageLayers = builtins.map envLayer groupEnvs;
            depsLayer = envLayer depsEnv;
            memberLayers = builtins.map envLayer memberEnvs;
          in
            (n2c.buildImage ({
                inherit name;
                config =
                  config
                  // {
                    Env =
                      defaultEnv
                      ++ (
                        if builtins.hasAttr "Env" config
                        then config.Env
                        else []
                      );
                  };
                layers =
                  [pythonLayer]
                  ++ groupImageLayers
                  ++ [depsLayer]
                  ++ memberLayers
                  ++ [
                    (n2c.buildLayer {
                      copyToRoot = [sourcesLayer];
                      compress = "gzip";
                    })
                  ]
                  ++ extraLayers;
              }
              // (
                if baseImage ? imageName
                then {fromImage = n2c.pullImage baseImage;}
                else {}
              )))
            .overrideAttrs (old: {
              buildInputs = [python] ++ extraBuildInputs;
              nativeBuildInputs = [pkgs.uv];
              propagatedBuildInputs = runtimeLibs;
              imageCheck = imageCheckDrv;
            });
        };
      };
    in {
      lib = lib;

      packages = rec {
        example-flask-app = let
          python = pkgs.python314;
        in
          lib.uv2container.buildImage {
            name = "example-flask-app";
            inherit python;
            src = ./examples/flask-app;
            dependencyLayers.web = ["flask"];
            config = {
              Cmd = ["python" "-m" "flask" "run" "--host=0.0.0.0"];
              WorkingDir = "/src";
              ExposedPorts = {
                "5000/tcp" = {};
              };
            };
          };
        example-as-dir =
          pkgs.runCommand "docker-as-dir" {}
          "${example-flask-app.copyTo}/bin/copy-to dir:$out";
      };

      devShells.default = pkgs.mkShell {
        inputsFrom = [self.packages.${system}.example-flask-app];
        packages = with pkgs; [
          nil
          nixpkgs-fmt
        ];
      };

      formatter = pkgs.nixpkgs-fmt;
    });
}
