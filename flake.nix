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
          sandboxInputs ? [ ],
          homeBinds ? [ ],
          xdgBinds ? [ ],
        }:
        let
          inherit (nixpkgs) lib;
          sandboxInputsFinal = sandboxInputs ++ [
            pkgs.bash
            pkgs.cacert
          ];
        in
        pkgs.stdenvNoCC.mkDerivation {
          name = "jjinn";
          version = "1.0.0";

          meta = {
            description = "Run a program sandboxed in an ephemeral jj workspace using a Nix devshell.";
            homepage = "https://github.com/anglesideangle/jjinn";
            license = lib.licenses.mit;
            mainProgram = "jjinn";
          };

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
                --set CA_DIR "${pkgs.cacert}/etc/ssl/certs" \
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
          pi-coding-agent = pkgsFor.${system}.callPackage ./pi-agent { };
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
          jjinn-pi = self.lib.makeJjinn pkgsFor.${system} {
            executable = lib.getExe self.packages.${system}.pi-coding-agent;
            sandboxInputs = with pkgsFor.${system}; [
              self.packages.${system}.pi-coding-agent
              nix
              coreutils
              curl
              which
              fd
              ripgrep
            ];
            homeBinds = [ ".pi" ];
          };
        in
        {
          inherit pi-coding-agent;
          inherit jjinn-opencode;
          default = jjinn-pi;
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
