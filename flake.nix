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

      lib = {
        uv2container = rec {
          buildDepsLayer = {
            python,
            src,
            extraBuildInputs ? [],
            cache ? null,
          }:
            pkgs.stdenv.mkDerivation {
              name = "deps-layer-venv";
              inherit src;
              __noChroot = true;
              dontFixup = true;
              nativeBuildInputs = [python pkgs.uv] ++ extraBuildInputs;
              buildPhase = ''
                runHook preBuild
                ${
                  if cache != null
                  then ''
                    mkdir -p $TMPDIR/.uv_cache/
                    cp -r ${cache}/* $TMPDIR/.uv_cache/
                    chmod -R u+w $TMPDIR/.uv_cache
                  ''
                  else ""
                }

                export PATH=".venv/bin:$PATH"
                export UV_PYTHON_PREFERENCE="only-system"
                export UV_CACHE_DIR="$TMPDIR/.uv_cache"
                export UV_PYTHON="${python}/bin/python${python.pythonVersion}"
                export VIRTUAL_ENV=$out
                export UV_PROJECT_ENVIRONMENT=$out
                mkdir -p $VIRTUAL_ENV
                uv venv
                uv sync --no-install-project --all-packages --locked --no-editable
                runHook postBuild
              '';
            };

          buildCache = {
            python,
            src,
            extraBuildInputs ? [],
            indexes ? [],
          }:
            pkgs.stdenv.mkDerivation {
              name = "build-cache";
              inherit src;
              __noChroot = true;
              dontFixup = true;
              nativeBuildInputs = [python pkgs.uv] ++ extraBuildInputs;
              buildPhase = ''
                runHook preBuild
                export UV_PYTHON_PREFERENCE="only-system"
                export UV_CACHE_DIR="$PWD/.uv_cache"
                export UV_PYTHON="${python}/bin/python${python.pythonVersion}"
                export VIRTUAL_ENV="$PWD/.venv"
                export PATH="$VIRTUAL_ENV/bin:$PATH"
                mkdir -p $out
                mkdir -p $UV_CACHE_DIR
                uv venv
                uv pip install -r requirements.txt ${pkgs.lib.strings.concatMapStringsSep " " (i: "--extra-index-url ${i}") indexes}
                cp -r $UV_CACHE_DIR/* $out
                runHook postBuild
              '';
            };
          cacheRequirements = {
            python,
            src,
            extraBuildInputs ? [],
            group,
          }:
            pkgs.stdenv.mkDerivation {
              name = "cache-requirements";
              inherit src;
              __noChroot = true;
              __contentAddressed = true;
              dontFixup = true;
              nativeBuildInputs = [python pkgs.uv] ++ extraBuildInputs;
              buildPhase = ''
                runHook preBuild
                export PATH=".venv/bin:$PATH"
                export UV_PYTHON_PREFERENCE="only-system"
                export UV_CACHE_DIR="$TMPDIR/.uv_cache"
                export UV_PYTHON="${python}/bin/python${python.pythonVersion}"
                # export UV_PROJECT_ENVIRONMENT=$out

                mkdir -p $UV_CACHE_DIR
                mkdir -p $out
                echo "path: $PATH"
                # uv venv
                uv export --group ${group} > $out/requirements.txt
                runHook postBuild
              '';
            };

          defaultFilesetFilter = file: file.hasExt "py";

          buildImage = {
            name,
            python,
            src,
            members ? [],
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
            memberMetadataCandidates =
              builtins.concatMap
              (member: [
                (src + "/${member}/pyproject.toml")
                (src + "/${member}/uv.lock")
                (src + "/${member}/__init__.py")
              ])
              members;

            dependencyMetadataFiles = builtins.filter builtins.pathExists (
              [
                (src + "/uv.lock")
                (src + "/pyproject.toml")
              ]
              ++ memberMetadataCandidates
            );

            localDependencyFiles = builtins.filter builtins.pathExists (
              builtins.map (dep: src + "/${dep}") localDeps
            );

            cachedLayer =
              if cacheGroupName != null
              then
                buildCache {
                  inherit python extraBuildInputs;
                  src = cacheRequirements {
                    inherit python extraBuildInputs src;
                    group = cacheGroupName;
                  };
                  indexes = cacheGroupIndexes;
                }
              else null;

            depsLayer = buildDepsLayer {
              inherit python extraBuildInputs;
              cache = cachedLayer;
              src =
                pkgs.lib.fileset.toSource
                {
                  root = src;
                  fileset = pkgs.lib.fileset.unions (dependencyMetadataFiles ++ localDependencyFiles);
                };
            };
            sourcesLayer =
              pkgs.lib.fileset.toSource
              {
                root = src;
                fileset = pkgs.lib.fileset.fileFilter filesetFilter src;
              };
            defaultEnv = [
              "PYTHONPATH=${depsLayer}/lib/python${python.pythonVersion}/site-packages:${python}/lib/python${python.pythonVersion}/site-packages"
              ("PATH=${depsLayer}/bin:${python}/bin:/bin:/usr/bin:" + (pkgs.lib.strings.concatMapStringsSep ":" (dep: "${dep}/bin") runtimeExecutableDeps))
              (
                "LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath ([pkgs.stdenv.cc.cc.lib] ++ runtimeLibs)}"
                + extraLdLibraryPath
              )
              (
                "LIBRARY_PATH=${pkgs.lib.makeLibraryPath ([pkgs.stdenv.cc.cc.lib] ++ libs)}"
                + extraLibraryPath
              )
            ];
          in
            (nix2container.packages.${system}.nix2container.buildImage ({
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
                  [
                    (nix2container.packages.${system}.nix2container.buildLayer {deps = [depsLayer];})
                    (nix2container.packages.${system}.nix2container.buildLayer {deps = [python] ++ runtimeLibs;})
                    (nix2container.packages.${system}.nix2container.buildLayer {
                      copyToRoot = [sourcesLayer];
                    })
                  ]
                  ++ extraLayers;
              }
              // (
                if baseImage ? imageName
                then {fromImage = nix2container.packages.${system}.nix2container.pullImage baseImage;}
                else {}
              ))).overrideAttrs (old: {
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
