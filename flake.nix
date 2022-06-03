{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/22.05;
    utils.url = github:numtide/flake-utils;
    nix-filter.url = github:numtide/nix-filter;
  };
  outputs = {
    self, nixpkgs, utils, nix-filter
  }: let
    version = "0.16.0";
    systemDependent = with utils.lib; eachSystem allSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in with nix-filter.lib; {
      devShell = pkgs.mkShell {
        buildInputs = with pkgs; [ nim ];
      };
      packages.webdocs = let
        nim-jester = pkgs.stdenv.mkDerivation {
          name = "nim-jester-0.5.0";
          src = pkgs.fetchFromGitHub {
            owner = "dom96";
            repo = "jester";
            rev = "v0.5.0";
            sha256 = "0m8a4ss4460jd2lcbqcbdd68jhcy35xg7qdyr95mh8rflwvmcvhk";
          };
          dontBuild = true;
          installPhase = ''
            mkdir -p $out/lib
            cp -r jester.nim jester $out/lib
          '';
        };
        nim-httpbeast = pkgs.stdenv.mkDerivation {
          name = "nim-httpbeast-0.2.2";
          src = pkgs.fetchFromGitHub {
            owner = "dom96";
            repo = "httpbeast";
            rev = "v0.2.2";
            sha256 = "1f8ch7sd5kcyaw1b1lpqywvhx2h6aa5an37zm7x0j22giqlml5c6";
          };
          dontBuild = true;
          installPhase = ''
            mkdir -p $out/lib
            cp -r src/* $out/lib
          '';
        };
        nim-cligen = pkgs.stdenv.mkDerivation {
          name = "nim-cligen-0.15.3";
          src = pkgs.fetchFromGitHub {
            owner = "c-blake";
            repo = "cligen";
            rev = "v1.5.23";
            sha256 = "rcledZbmcAXs0l5uQRmOennyMiw4G+zye6frGqksjyA=";
          };
          dontBuild = true;
          installPhase = ''
            mkdir -p $out/lib
            cp -rt $out/lib cligen.nim cligen
          '';
        };
      in pkgs.stdenv.mkDerivation {
        pname = "nimyaml-server-deamon";
        inherit version;
        src = filter {
          root = ./.;
          exclude = [ ./flake.nix ./flake.lock ./tools ./bench ./.github ];
        };
        configurePhase = ''
          mkdir -p docout/api
          (
            cd doc
            for rstFile in *.rst; do
              ${pkgs.nim}/bin/nim rst2html -o:../docout/''${rstFile%.rst}.html $rstFile
            done
            ${pkgs.nim}/bin/nim c --nimcache:.cache rstPreproc
            for txtFile in *.txt; do
              ./rstPreproc -o:tmp.rst $txtFile
              ${pkgs.nim}/bin/nim rst2html -o:../docout/''${txtFile%.txt}.html tmp.rst
            done
            cp docutils.css style.css processing.svg ../docout
          )
          ${pkgs.nim}/bin/nim doc2 -o:docout/api/yaml.html --docSeeSrcUrl:https://github.com/flyx/NimYAML/blob/${self.rev or "master"} yaml
          for srcFile in yaml/*.nim; do
            bn=''${srcFile#yaml/}
            ${pkgs.nim}/bin/nim doc2 -o:docout/api/''${bn%.nim}.html --docSeeSrcUrl:https://github.com/flyx/NimYAML/blob/yaml/${self.rev or "master"} $srcFile
          done
        '';
        buildPhase = ''
          cat <<EOF >server/server_cfg.nim
          proc shareDir*(): string =
            result = "$out/share"
          EOF
          ${pkgs.nim}/bin/nim c --d:release --d:yamlScalarRepInd -p:"${nim-jester}/lib" -p:"${nim-httpbeast}/lib" -p:"${nim-cligen}/lib" --nimcache:.cache server/server
        '';
        installPhase = ''
          mkdir -p $out/{bin,share}
          cp server/server $out/bin
          cp -rt $out/share docout/*
        '';
      };
    });
  in systemDependent // {
    nixosModule = {config, lib, pkg, ...}: with lib; let
      cfg = config.services.nimyaml-webdocs;
      webdocs = systemDependents.packages.${config.nixpkgs.system}.webdocs;
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
        systemd.services.dsa41generator = {
          wantedBy = ["multi-user.target"];
          after = ["network.target"];
          serviceConfig.ExecStart = ''${webdocs}/bin/server --address "${cfg.address}" --port ${cfg.port}'';
        };
      };
    };
  };
}