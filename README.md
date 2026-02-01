# Jjinn

Jjinn is a minimal tool for nix projects that runs [opencode](https://opencode.ai/) sandboxed inside in an ephemeral [jj](https://jj-vcs.dev/) workspace.
It uses the contents of your project's `devShells` to construct the sandbox environment using `bwrap`.

## Workflow

```nushell
jjinn @
```
