{ pkgs }:
let
  inherit (pkgs) lib;
in
lib.makeScope pkgs.newScope (self: {
  packages'.default =
    let
      sandboxInputs = with pkgs; [
        bash
        jujutsu
        nix
        opencode
        bash
        coreutils
        curl
        which
        findutils
        diffutils
        gnupatch
        gnugrep
      ];
    in
    pkgs.stdenvNoCC.mkDerivation {
      name = "henchman";
      version = "0.0.0";

      src = ./henchman.nu;

      dontUnpack = true;

      nativeBuildInputs = [ pkgs.makeWrapper ];

      runtimeInputs =
        with pkgs;
        [
          bubblewrap
        ]
        ++ sandboxInputs;

      installPhase = ''
        mkdir -p $out/bin
        cp $src $out/bin/henchman

        wrapProgram $out/bin/henchman \
            --prefix PATH : ${lib.makeBinPath [ pkgs.nushell ]} \
            --set SANDBOX_INPUTS "${lib.concatStringsSep "\n" sandboxInputs}" \
            --set FALLBACK_BASH "${lib.getExe pkgs.bash}"
      '';
    };

  shells.default = pkgs.mkShellNoCC {
    inputsFrom = [ self.packages'.default ];
    packages = [
      self.formatter
    ];
  };

  formatter = pkgs.treefmt.withConfig {
    name = "project-format";

    runtimeInputs = with pkgs; [
      nixfmt
    ];

    settings = {
      formatter.nix = {
        command = "nixfmt";
        includes = [ "*.nix" ];
      };
    };
  };
})
