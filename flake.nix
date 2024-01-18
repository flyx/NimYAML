{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
    nix-filter.url = "github:numtide/nix-filter";
  };
  outputs = { self, nixpkgs, utils, nix-filter }:
    let
      version = "2.1.1";
      systemDependent = with utils.lib;
        eachSystem allSystems (system:
          let pkgs = nixpkgs.legacyPackages.${system};
          in with nix-filter.lib; {
            devShell = pkgs.mkShell { buildInputs = with pkgs; [ nim2 ]; };
            packages.webdocs = let
              nim-jester = pkgs.stdenv.mkDerivation {
                name = "nim-jester-0.6.0";
                src = pkgs.fetchFromGitHub {
                  owner = "dom96";
                  repo = "jester";
                  rev = "v0.6.0";
                  sha256 =
                    "sha256-F/zWWGipJ4lBE3njceXn5HBFTYEXB4l2rk6+FfqqZTQ=";
                };
                dontBuild = true;
                installPhase = ''
                  mkdir -p $out/lib
                  cp -r jester.nim jester $out/lib
                '';
              };
              nim-httpbeast = pkgs.stdenv.mkDerivation {
                name = "nim-httpbeast-0.4.1";
                src = pkgs.fetchFromGitHub {
                  owner = "dom96";
                  repo = "httpbeast";
                  rev = "v0.4.1";
                  sha256 =
                    "sha256-8ncCj94UeirSevgZP717NiNtecDyH5jHky+QId31IvQ=";
                };
                dontBuild = true;
                installPhase = ''
                  mkdir -p $out/lib
                  ls -alh
                  cp -r src/* $out/lib
                '';
              };
            in pkgs.stdenv.mkDerivation {
              pname = "nimyaml-docs-server";
              inherit version;
              src = filter {
                root = ./.;
                exclude =
                  [ ./flake.nix ./flake.lock ./tools ./bench ./.github ];
              };
              configurePhase = ''
                mkdir -p docout/api
                for srcFile in yaml/*.nim; do
                  echo "generate index for $srcFile"
                  ${pkgs.nim2}/bin/nim doc --index:only --outdir:docout/api/yaml $srcFile
                done

                (
                  cd doc
                  for rstFile in *.rst; do
                    ${pkgs.nim2}/bin/nim rst2html -o:../docout/''${rstFile%.rst}.html $rstFile
                  done
                  ${pkgs.nim2}/bin/nim c --nimcache:.cache rstPreproc
                  for txtFile in *.txt; do
                    ./rstPreproc -o:tmp.rst $txtFile
                    fn=$(basename -- "$txtFile")
                    ${pkgs.nim2}/bin/nim rst2html -o:../docout/''${fn%.txt}.html tmp.rst
                    rm tmp.rst
                  done
                  cp docutils.css style.css processing.svg github-mark-white.svg ../docout
                )

                ${pkgs.nim2}/bin/nim doc -o:docout/api/yaml.html --docSeeSrcUrl:https://github.com/flyx/NimYAML/blob/${
                  self.rev or "master"
                } yaml
                for srcFile in yaml/*.nim; do
                  bn=''${srcFile#yaml/}
                  ${pkgs.nim2}/bin/nim doc -o:docout/api/yaml/''${bn%.nim}.html --docSeeSrcUrl:https://github.com/flyx/NimYAML/blob/yaml/${
                    self.rev or "master"
                  } $srcFile
                done
              '';
              buildPhase = ''
                cat <<EOF >server/server_cfg.nim
                proc shareDir*(): string =
                  result = "$out/share"
                EOF
                ${pkgs.nim2}/bin/nim c --stackTrace -p:"${nim-jester}/lib" -p:"${nim-httpbeast}/lib" --gc:refc --nimcache:.cache server/server
              '';
              installPhase = ''
                mkdir -p $out/{bin,share}
                cp server/server $out/bin/nimyaml-docs-server
                cp -rt $out/share docout/*
              '';
            };
          });
    in systemDependent // {
      nixosModule = { config, lib, pkg, ... }:
        with lib;
        let
          cfg = config.services.nimyaml-webdocs;
          webdocs = systemDependent.packages.${config.nixpkgs.system}.webdocs;
        in {
          options.services.nimyaml-webdocs = {
            enable = mkEnableOption "NimYAML webdocs server";
            address = mkOption {
              type = types.str;
              default = "127.0.0.1";
              description = "Listen address";
            };
            port = mkOption {
              type = types.int;
              default = 5000;
              description = "Listen port";
            };
          };
          config = mkIf cfg.enable {
            systemd.services.nimyaml-webdocs = {
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];
              serviceConfig.ExecStart = ''
                ${webdocs}/bin/nimyaml-docs-server --address="${cfg.address}" --port=${
                  toString cfg.port
                }'';
            };
          };
        };
    };
}
