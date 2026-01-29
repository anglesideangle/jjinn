{
  nixpkgs,
  system,
}:
with nixpkgs.lib;
let

  makeScope =
    newScope: f:
    let
      self = f self // {
        newScope = scope: newScope (self // scope);
        callPackage = self.newScope { };
        overrideScope = g: makeScope newScope (extends g f);
        definition = f;
      };
    in
    self;

  callPackageWith =
    autoArgs: fn: args:
    let
      f = if isFunction fn then fn else import fn;
      fargs = builtins.functionArgs f;

      allArgs = builtins.intersectAttrs fargs autoArgs // args;

      missingArgs = builtins.filter (name: !(builtins.hasAttr name allArgs) && !(fargs.${name})) (
        builtins.attrNames fargs
      );

      errorMsg =
        let
          missingStr = builtins.concatStringsSep ", " missingArgs;
          loc = if builtins.isPath fn || builtins.isString fn then " imported from '${toString fn}'" else "";
        in
        "Function${loc} called without required argument(s): ${missingStr}";

    in
    if missingArgs == [ ] then
      makeOverridable f allArgs
    else
      abort "workspace.callPackageWith: ${errorMsg}";
  newScope = scope: callPackageWith scope;
in
makeScope newScope (
  self:

  let
    pkgs = nixpkgs.legacyPackages.${system};
    lib = pkgs.lib;
  in
  {

    packages.default =
      let
        sandboxInputs = with pkgs; [
          bash
          jujutsu
          opencode
          coreutils
          curl
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
            nix
          ]
          ++ sandboxInputs;

        installPhase = ''
          mkdir -p $out/bin
          cp $src $out/bin/henchman

          wrapProgram $out/bin/henchman \
              --prefix PATH : ${lib.makeBinPath [ pkgs.nushell ]} \
              --set SANDBOX_INPUTS "${lib.concatStringsSep "\n" sandboxInputs}"
        '';
      };

    devShells.default = pkgs.mkShellNoCC {
      inputsFrom = [ self.packages.default ];
      packages = [
        self.formatter
        pkgs.nufmt
      ];
    };

    formatter = pkgs.treefmt.withConfig {
      name = "project-format";

      runtimeInputs = with pkgs; [
        nixfmt
        nufmt
      ];

      settings = {
        formatter.nix = {
          command = "nixfmt";
          includes = [ "*.nix" ];
        };

        formatter.nu = {
          command = "nufmt";
          includes = [ "*.nu" ];
        };
      };
    };
  }
)
