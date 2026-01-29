# Henchman

Henchman is a simple manager for agentic coding tools that runs opencode in a bwrap sandbox backed by a temporary jj workspace.
It is designed to work with nix projects, and uses the contents of your project's `#devShells.${system}.default` to build the sandbox environment.

I developed this tool for my personal workflow.
Feel free to use it, contribute fixes, copy the code, etc.

## Usage

```nushell
henchman edit [revset] --network true --dev false
```

```nushell
henchman shell [revset] --network true --dev false
```

## Future stuff?

- [ ] config.toml
- [ ] support `project.nix` in addition to `flake.nix`
  - actually finish `project.nix` cli
