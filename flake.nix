{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    utils.url = "github:numtide/flake-utils";
    nix-filter.url = "github:numtide/nix-filter";
  };
  outputs =
    {
      self,
      nixpkgs,
      utils,
      nix-filter,
    }:
    let
      version = "2.3.0";
      systemDependent =
        with utils.lib;
        eachSystem allSystems (
          system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
          with nix-filter.lib;
          {
            devShell = pkgs.mkShell {
              buildInputs = with pkgs; [
                nim2
                nodejs-slim # runs tests compiled with `nim js -r`
              ];
            };
            packages.webdocs = pkgs.stdenv.mkDerivation {
              pname = "nimyaml-webdocs";
              inherit version;
              src = filter {
                root = ./.;
                exclude = [
                  ./flake.nix
                  ./flake.lock
                  ./tools
                  ./bench
                  ./.github
                ];
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

                ${pkgs.nim2}/bin/nim doc -o:docout/api/yaml.html --docSeeSrcUrl:https://github.com/flyx/NimYAML/blob/${self.rev or "master"} yaml
                for srcFile in yaml/*.nim; do
                  bn=''${srcFile#yaml/}
                  ${pkgs.nim2}/bin/nim doc -o:docout/api/yaml/''${bn%.nim}.html --docSeeSrcUrl:https://github.com/flyx/NimYAML/blob/yaml/${self.rev or "master"} $srcFile
                done
              '';
              buildPhase = ''
                # the testing ground runs NimYAML compiled to JS in the browser
                ${pkgs.nim2}/bin/nim --nimcache:.cache testingGround
              '';
              installPhase = ''
                mkdir -p $out
                cp -rt $out docout/*
              '';
            };
          }
        );
    in
    systemDependent;
}
