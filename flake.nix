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
      workspace = forAllSystems (system: import ./. { inherit nixpkgs system; });
    in
    {
      packages = forAllSystems (system: workspace.${system}.packages);
      devShells = forAllSystems (system: workspace.${system}.devShells);
      formatter = forAllSystems (system: workspace.${system}.formatter);

    };
}
