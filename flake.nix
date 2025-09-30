{
  description = "Python + UV container build utilities";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix2container.url = "github:nlewo/nix2container";
    nix2container.inputs.nixpkgs.follows = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nix2container, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        lib = {
          uv2container = rec {

            buildDepsLayer =
              { python
              , uv ? pkgs.uv
              , src
              , extraBuildInputs ? [ ]
              }: pkgs.stdenv.mkDerivation {
                name = "python-venv";
                inherit src;
                __noChroot = true;
                dontFixup = true;
                nativeBuildInputs = [ python uv ] ++ extraBuildInputs;
                buildPhase = ''
                  runHook preBuild
                  export UV_LINK_MODE=copy
                  export PATH=".venv/bin:$PATH"
                  export UV_PYTHON_PREFERENCE="only-system"
                  export UV_PYTHON="${python}/bin/python${python.pythonVersion}"
                  export VIRTUAL_ENV=$out
                  export UV_PROJECT_ENVIRONMENT=$out
                  mkdir -p $VIRTUAL_ENV
                  uv venv
                  uv sync --no-cache --no-install-project --locked
                  runHook postBuild
                '';
              };

            defaultFilesetFilter = (file: file.hasExt "py");

            buildImage =
              { name
              , python
              , src
              , extraBuildInputs ? [ ]
              , runtimeLibs ? [ ]
              , filesetFilter ? defaultFilesetFilter
              , config ? { }
              , extraLayers ? [ ]
              }:
              let
                depsLayer = buildDepsLayer {
                  inherit python src extraBuildInputs;
                };
                sourcesLayer = pkgs.lib.fileset.toSource
                {
                  root = src;
                  fileset = pkgs.lib.fileset.fileFilter filesetFilter src;
                };
                defaultEnv = [
                  "PYTHONPATH=${depsLayer}/lib/python${python.pythonVersion}/site-packages:${python}/lib/python${python.pythonVersion}/site-packages"
                  "LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath ([ pkgs.stdenv.cc.cc.lib ] ++ runtimeLibs)}"
                  "PATH=${depsLayer}/bin:${python}/bin:/bin"
                ];
              in
              (nix2container.packages.${system}.nix2container.buildImage {
                inherit name;
                config = config // {
                  Env = defaultEnv ++ (if builtins.hasAttr "Env" config then config.Env else [ ]);
                };
                layers = [
                  (nix2container.packages.${system}.nix2container.buildLayer { deps = [ depsLayer ]; })
                  (nix2container.packages.${system}.nix2container.buildLayer { deps = ([ python ] ++ runtimeLibs); })
                  (nix2container.packages.${system}.nix2container.buildLayer {
                    copyToRoot = [ sourcesLayer ];
                  })
                ] ++ extraLayers;
              }).overrideAttrs (old: {
                buildInputs = [ python ] ++ extraBuildInputs;
                nativeBuildInputs = [ pkgs.uv ];
                propagatedBuildInputs = runtimeLibs;
              });
          };
        };
      in
      {
        lib = lib;

        packages = rec {
          example-flask-app = let
            python = pkgs.python314;
          in lib.uv2container.buildImage {
            name = "example-flask-app";
            inherit python;
            src = ./examples/flask-app;
            config = {
              Cmd = [ "python" "-m" "flask" "run" "--host=0.0.0.0" ];
              WorkingDir = "/src";
              ExposedPorts = {
                "5000/tcp" = { };
              };
            };
          };
          example-as-dir = pkgs.runCommand "docker-as-dir" { }
            "${example-flask-app.copyTo}/bin/copy-to dir:$out";
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ self.packages.${system}.example-flask-app ];
          packages = with pkgs; [
            nil
            nixpkgs-fmt
          ];
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
