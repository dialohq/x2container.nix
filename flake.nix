{
  description = "Python + UV container build utilities";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix2container.url = "github:nlewo/nix2container";
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
            # Optional derivation whose packages.txt limits this export:
            # packages outside it are dropped (never added to the image).
            restrictTo ? null,
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
                pylock_names() {
                  python3 -c '
                import sys, tomllib
                with open(sys.argv[1], "rb") as f:
                    data = tomllib.load(f)
                for name in sorted({p["name"] for p in data.get("packages", [])}):
                    print(name)
                ' "$1"
                }

                ${
                  if restrictTo != null
                  then ''
                    uv export --locked --format pylock.toml --no-annotate --no-header \
                      ${pkgs.lib.escapeShellArgs exportArgs} -o "$TMPDIR/pylock.probe.toml"
                    pylock_names "$TMPDIR/pylock.probe.toml" > "$TMPDIR/mine.txt"
                    comm -23 "$TMPDIR/mine.txt" ${restrictTo}/packages.txt > "$TMPDIR/drop.txt"
                    while IFS= read -r p; do
                      [ -n "$p" ] && exclude_args+=(--no-emit-package "$p")
                    done < "$TMPDIR/drop.txt"
                  ''
                  else ""
                }

                uv export --locked --format pylock.toml --no-annotate --no-header \
                  ${pkgs.lib.escapeShellArgs exportArgs} "''${exclude_args[@]}" \
                  -o $out/pylock.toml
                pylock_names $out/pylock.toml > $out/packages.txt
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
          }:
            pkgs.stdenv.mkDerivation {
              inherit name;
              NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              inherit src;
              __noChroot = true;
              dontFixup = true;
              nativeBuildInputs = [python pkgs.uv pkgs.removeReferencesTo] ++ extraBuildInputs;
              buildPhase = ''
                runHook preBuild
                export UV_CACHE_DIR="$TMPDIR/.uv_cache"
                export UV_PYTHON_PREFERENCE="only-system"
                export UV_PYTHON="${python}/bin/python${python.pythonVersion}"
                uv venv "$out"
                uv pip install --python "$out/bin/python" --no-deps ./${memberPath}
                ${scrubToolchainReferences}
                runHook postBuild
              '';
            };

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
            # How third-party dependencies are split into image layers:
            #   "flat"      — one layer with the entire dependency set;
            #   "autosplit" — one layer per [dependency-groups] entry of the
            #                 root pyproject.toml (alphabetical) + a layer
            #                 with the remainder;
            #   [ "g1" .. ] — one layer per listed group, in order, + a layer
            #                 with the remainder.
            # A group layer holds (group closure ∩ shipped packages) minus
            # packages claimed by earlier group layers. Group membership only
            # controls layer placement — it never adds packages to the image.
            dependencyLayers ? "flat",
            # Optional build-time self-test command (argv list), run with the
            # image's runtime environment; the image build fails if it fails.
            imageCheck ? null,
            imageCheckEnv ? {},
          }: let
            inherit (pkgs.lib) fileset;

            sitePackages = env: "${env}/lib/python${python.pythonVersion}/site-packages";

            # Only metadata: member sources must not invalidate dependency
            # layers.
            pyprojectFiles = builtins.filter builtins.pathExists (
              [(src + "/pyproject.toml")]
              ++ builtins.map (m: src + "/${m}/pyproject.toml") members
            );
            metadataFiles =
              builtins.filter builtins.pathExists [(src + "/uv.lock")]
              ++ pyprojectFiles;
            metadataSrc = fileset.toSource {
              root = src;
              fileset = fileset.unions metadataFiles;
            };

            effectiveGroups =
              if dependencyLayers == "flat"
              then []
              else if dependencyLayers == "autosplit"
              then
                builtins.attrNames
                ((builtins.fromTOML (builtins.readFile (src + "/pyproject.toml"))).dependency-groups or {})
              else if builtins.isList dependencyLayers
              then pkgs.lib.unique dependencyLayers
              else throw "dependencyLayers must be \"flat\", \"autosplit\", or a list of dependency-group names";

            allShippedRequirements = exportRequirements {
              inherit python extraBuildInputs;
              src = metadataSrc;
              name = "all-shipped";
              exportArgs = ["--all-packages" "--no-emit-project" "--no-emit-workspace" "--no-default-groups"];
            };

            groupExports = builtins.foldl' (acc: g:
              acc
              ++ [
                {
                  group = g;
                  export = exportRequirements {
                    inherit python extraBuildInputs;
                    src = metadataSrc;
                    name = "group-${g}";
                    exportArgs = ["--only-group" g];
                    restrictTo = allShippedRequirements;
                    excludeFrom = builtins.map (ge: ge.export) acc;
                  };
                }
              ]) []
            effectiveGroups;

            groupEnvs =
              builtins.map (ge:
                buildVenvFromRequirements {
                  inherit python extraBuildInputs;
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
              inherit python extraBuildInputs;
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

            # Most-stable first, chained so each store path ships once.
            pythonLayer = n2c.buildLayer {deps = [python] ++ runtimeLibs;};
            groupImageLayers = builtins.foldl' (acc: env:
              acc
              ++ [
                (n2c.buildLayer {
                  deps = [env];
                  layers = [pythonLayer] ++ acc;
                })
              ]) []
            groupEnvs;
            depsLayer = n2c.buildLayer {
              deps = [depsEnv];
              layers = [pythonLayer] ++ groupImageLayers;
            };
            memberLayers =
              builtins.map (env:
                n2c.buildLayer {
                  deps = [env];
                  layers = [pythonLayer depsLayer] ++ groupImageLayers;
                })
              memberEnvs;
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
            dependencyLayers = "autosplit";
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
