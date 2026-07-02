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
          # Export a pinned pylock.toml (+ a plain package-name list) from
          # uv.lock. pylock pins exact artifact URLs and hashes, so installs
          # never re-resolve against an index (a package published on two
          # indexes with different bytes can't be picked wrongly).
          # Content-addressed: when a uv.lock change leaves the exported set
          # untouched (e.g. only non-heavy packages were bumped), downstream
          # derivations are not rebuilt.
          exportRequirements = {
            python,
            src,
            name ? "requirements",
            exportArgs ? [],
            # Optional derivation (from exportRequirements) whose packages.txt
            # is subtracted from this export.
            excludeFrom ? null,
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
                  if excludeFrom != null
                  then ''
                    while IFS= read -r p; do
                      [ -n "$p" ] && exclude_args+=(--no-emit-package "$p")
                    done < ${excludeFrom}/packages.txt
                  ''
                  else ""
                }

                uv export --frozen --format pylock.toml --no-annotate --no-header \
                  ${pkgs.lib.escapeShellArgs exportArgs} "''${exclude_args[@]}" \
                  -o $out/pylock.toml
                grep -E '^name = ' $out/pylock.toml \
                  | sed 's/^name = "\(.*\)"/\1/' | sort -u > $out/packages.txt
                runHook postBuild
              '';
            };

          # Build a venv containing exactly the packages of a pylock export.
          # No resolution happens at install time; artifacts come from the
          # exact URLs the lock refers to.
          buildVenvFromRequirements = {
            python,
            name,
            requirements,
            indexes ? [],
            extraBuildInputs ? [],
          }:
            pkgs.stdenv.mkDerivation {
              inherit name;
              NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              dontUnpack = true;
              __noChroot = true;
              dontFixup = true;
              nativeBuildInputs = [python pkgs.uv] ++ extraBuildInputs;
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
                runHook postBuild
              '';
            };

          # Build a venv containing a single workspace member (non-editable).
          # Keyed only on that member's sources: a change to one member never
          # rebuilds another (in particular, pure-Python edits don't rebuild
          # members with native build steps).
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
              nativeBuildInputs = [python pkgs.uv] ++ extraBuildInputs;
              buildPhase = ''
                runHook preBuild
                export UV_CACHE_DIR="$TMPDIR/.uv_cache"
                export UV_PYTHON_PREFERENCE="only-system"
                export UV_PYTHON="${python}/bin/python${python.pythonVersion}"
                uv venv "$out"
                uv pip install --python "$out/bin/python" --no-deps ./${memberPath}
                runHook postBuild
              '';
            };

          defaultFilesetFilter = file: file.hasExt "py";

          buildImage = {
            name,
            python,
            src,
            members ? [],
            # Deprecated: member sources no longer feed the dependency layer.
            localDeps ? [],
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
            cacheGroupName ? null,
            cacheGroupIndexes ? [],
          }: let
            inherit (pkgs.lib) fileset;

            sitePackages = env: "${env}/lib/python${python.pythonVersion}/site-packages";

            # uv only needs the project metadata to interpret the lock; member
            # sources stay out so source edits never touch dependency layers.
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

            heavyRequirements =
              if cacheGroupName != null
              then
                exportRequirements {
                  inherit python extraBuildInputs;
                  src = metadataSrc;
                  name = "group-${cacheGroupName}";
                  exportArgs = ["--only-group" cacheGroupName];
                }
              else null;

            heavyEnv =
              if cacheGroupName != null
              then
                buildVenvFromRequirements {
                  inherit python extraBuildInputs;
                  name = "env-${cacheGroupName}";
                  requirements = heavyRequirements;
                  indexes = cacheGroupIndexes;
                }
              else null;

            depsRequirements = exportRequirements {
              inherit python extraBuildInputs;
              src = metadataSrc;
              name = "deps";
              exportArgs = ["--all-packages" "--no-emit-project" "--no-emit-workspace"];
              excludeFrom = heavyRequirements;
            };

            depsEnv = buildVenvFromRequirements {
              inherit python extraBuildInputs;
              name = "env-deps";
              requirements = depsRequirements;
              indexes = cacheGroupIndexes;
            };

            # A member's fileset excludes members nested under it, so e.g.
            # editing a nested native member doesn't rebuild its parent and
            # vice versa.
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
                  # Workspace pyprojects are required for uv to accept
                  # `workspace = true` sources; uv.lock is not (installs are
                  # --no-deps), so lock changes don't rebuild members.
                  src = fileset.toSource {
                    root = src;
                    fileset = fileset.unions (pyprojectFiles ++ [(memberFileset m)]);
                  };
                  memberPath = m;
                })
              members;

            pythonEnvs = memberEnvs ++ [depsEnv] ++ (pkgs.lib.optional (heavyEnv != null) heavyEnv);

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

            # Layers ordered most-stable first and explicitly chained so each
            # store path ships exactly once; a rebuilt layer never re-ships
            # content of the layers before it.
            pythonLayer = n2c.buildLayer {deps = [python] ++ runtimeLibs;};
            heavyLayer =
              if heavyEnv != null
              then
                n2c.buildLayer {
                  deps = [heavyEnv];
                  layers = [pythonLayer];
                }
              else null;
            depsLayer = n2c.buildLayer {
              deps = [depsEnv];
              layers = [pythonLayer] ++ pkgs.lib.optional (heavyLayer != null) heavyLayer;
            };
            memberLayers =
              builtins.map (env:
                n2c.buildLayer {
                  deps = [env];
                  layers = [pythonLayer depsLayer] ++ pkgs.lib.optional (heavyLayer != null) heavyLayer;
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
                  ++ pkgs.lib.optional (heavyLayer != null) heavyLayer
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
