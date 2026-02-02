# Jjinn

Jjinn is a script for nix projects that runs an executable sandboxed inside in an ephemeral [jj](https://jj-vcs.dev/) workspace.
It uses the contents of your project's `devShells` to construct the sandbox environment using `bwrap`.

## Workflow

`jjinn` integrates nicely into a regular `jj` workflow. You simply run `jjinn <revset>` and it will make sure every change made in the ephemeral workspace is synced to a new revset before terminating. You can then `jj describe`, `jj squash`, `jj merge`, `jj edit`, etc to deal with the resulting revision.

Edit from the current revision in the current repo:
```nushell
jjinn
```

Edit from the previous commit in `./project` using the `my-package` devshell output:
```nushell
jjinn @- --repo project --devshell "my-package"
```

## Installation

This project can be used as a flake from `github:anglesideangle/jjinn`. For example, `nix profile add github:anglesideangle/jjinn#jjinn-opencode`.

The default jjinn configuration uses [opencode](https://opencode.ai/). However, it is not tightly coupled to opencode, and you can create your own package using this flake's `lib.makeJjinn` wrapper:

```nix
jjinn-mytool = jjinn.lib.makeJjinn pkgs {
  executable = lib.getExe pkgs.mytool;
  xdgName = "mytoolname";
  sandboxInputs = with pkgs; [
    mytool
    nix
    coreutils
    curl
    which
    findutils
    diffutils
    gnupatch
    gnugrep
    ...etc
  ];
};
```

This probably won't work for claude code codex at the moment because they don't use xdg directories...
