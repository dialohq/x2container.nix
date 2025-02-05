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
                '';
                installPhase = ''
                  runHook preInstall
                  runHook postInstall
                '';
              };

            defaultFilesetFilter = (file: file.hasExt "py");

            buildImage =
              { name
              , python
              , src
              , cmd
              , extraBuildInputs ? [ ]
              , runtimeLibs ? [ ]
              , env ? [ ]
              , filesetFilter ? defaultFilesetFilter
              , extraConfig ? { }
              }:
              let
                depsLayer = buildDepsLayer {
                  inherit python src extraBuildInputs;
                };
                defaultEnv = [
                  "PYTHONPATH=${depsLayer}/lib/python${python.pythonVersion}/site-packages:${python}/lib/python${python.pythonVersion}/site-packages"
                  "LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath ([ pkgs.stdenv.cc.cc.lib ] ++ runtimeLibs)}"
                  "PATH=${depsLayer}/bin:${python}/bin:/bin"
                ];
              in
              nix2container.packages.${system}.nix2container.buildImage {
                inherit name;
                config = {
                  WorkingDir = "/src";
                  Cmd = cmd;
                  Env = defaultEnv ++ env;
                } // extraConfig;
                layers = [
                  (nix2container.packages.${system}.nix2container.buildLayer { deps = [ depsLayer ]; })
                  (nix2container.packages.${system}.nix2container.buildLayer { deps = ([ python ] ++ runtimeLibs); })
                  (nix2container.packages.${system}.nix2container.buildLayer {
                    copyToRoot = [
                      pkgs.lib.fileset.toSource
                      {
                        root = src;
                        fileset = pkgs.lib.fileset.fileFilter filesetFilter src;
                      }
                    ];
                  })
                ];
              };
          };
        };
      in
      {
        lib = lib;

        packages = rec {
          example-flask-app = lib.uv2container.buildImage {
            name = "example-flask-app";
            python = pkgs.python314;
            src = ./examples/flask-app;
            cmd = [ "python" "-m" "flask" "run" "--host=0.0.0.0" ];
            extraConfig = {
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
            python314
            uv
            nil
            nixpkgs-fmt
          ];
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
