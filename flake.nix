{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = forAllSystems (system: nixpkgs.legacyPackages.${system});
    in
    {
      lib.makeJjinn =
        pkgs:
        {
          executable,
          sandboxInputs ? [],
          homeBinds ? [],
          xdgBinds ? [],
        }:
        let
          inherit (nixpkgs) lib;
          sandboxInputsFinal = sandboxInputs ++ [ pkgs.bash ];
        in
        pkgs.stdenvNoCC.mkDerivation {
          name = "jjinn";
          version = "0.0.0";

          src = ./jjinn.nu;

          dontUnpack = true;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          runtimeInputs =
            with pkgs;
            [
              pkgs.bubblewrap
              pkgs.jujutsu
              pkgs.nix
            ]
            ++ sandboxInputs;

          installPhase = ''
            mkdir -p $out/bin
            cp $src $out/bin/jjinn

            wrapProgram $out/bin/jjinn \
                --prefix PATH : ${lib.makeBinPath [ pkgs.nushell ]} \
                --set SANDBOX_INPUTS "${lib.concatStringsSep "\n" sandboxInputsFinal}" \
                --set FALLBACK_BASH "${lib.getExe pkgs.bash}" \
                --set HOME_BINDS "${lib.concatStringsSep "\n" homeBinds}" \
                --set XDG_BINDS "${lib.concatStringsSep "\n" xdgBinds}" \
                --set EXECUTABLE "${executable}"
          '';
        };

      packages = forAllSystems (
        system:
        let
          inherit (nixpkgs) lib;
          jjinn-opencode = self.lib.makeJjinn pkgsFor.${system} {
            executable = lib.getExe pkgsFor.${system}.opencode;
            sandboxInputs = with pkgsFor.${system}; [
              opencode
              nix
              coreutils
              curl
              which
              findutils
              diffutils
              gnupatch
              gnugrep
            ];
            xdgBinds = [ "opencode" ];
            homeBinds = [ ".bun" ];
          };
        in
        {
          inherit jjinn-opencode;
          default = jjinn-opencode;
        }
      );

      devShells.default = forAllSystems (
        system:
        pkgsFor.${system}.mkShellNoCC {
          inputsFrom = [ self.packages.default ];
          packages = [
            self.formatter
          ];
        }
      );

      formatter = forAllSystems (
        system:
        pkgsFor.${system}.treefmt.withConfig {
          name = "project-format";

          runtimeInputs = with pkgsFor.${system}; [
            nixfmt
          ];

          settings = {
            formatter.nix = {
              command = "nixfmt";
              includes = [ "*.nix" ];
            };
          };
        }
      );

    };
}
