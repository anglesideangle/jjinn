# Jjinn

Jjinn is a script for nix projects that runs a program (such as a llm agent) sandboxed inside in an ephemeral [jj](https://jj-vcs.dev/) workspace.
It uses the contents of your project's `devShells` to construct the sandbox environment using `bwrap`.

## Workflow

`jjinn` integrates nicely into a regular `jj` workflow. You simply run `jjinn <revset>` and it will make sure every change made in the ephemeral workspace is synced to a new revset before terminating. You can then `jj describe`, `jj squash`, `jj merge`, `jj edit`, etc to deal with the resulting revision.

```
$ jjinn
>>> Created workspace in "../../../../tmp/jjinn-GEgA"
>>> Working copy  (@) now at: ysoklwzx 35f06f33 (empty) (no description set)
>>> Parent commit (@-)      : twsyxytt 1610239f (no description set)
>>> Added 7 files, modified 0 files, removed 0 files

──────────────────────────────────────────────────────────────────────────────────────────
Jarvis, please create a agentic ai b2b saas company. Do not make mistakes.
──────────────────────────────────────────────────────────────────────────────────────────

 ...

Temporary workspace changes are now in:
>>> ○  ysoklwzx neil@rickastley.co.uk 2026-02-12 19:00:58 jjinn-GEgA@ 47b2de02
>>> │  (no description set)
>>> ~

$ jj squash -i --from yso --to @
Rebased 5 descendant commits
Working copy  (@) now at: twsyxytt e285b076 (no description set)
Parent commit (@-)      : vvzymmuy f94c44fb main | prefix jj output with >>>
Added 0 files, modified 1 files, removed 0 files
```

## Installation

This project can be used as a flake from `github:anglesideangle/jjinn`. For example, `nix profile add github:anglesideangle/jjinn#jjinn-opencode`.

The default jjinn configuration uses [pi-coding-agent](https://github.com/badlogic/pi-mono). However, it is not tightly coupled to a specific tool, and you can create your own package using this flake's `lib.makeJjinn` wrapper. For example:

```nix
jjinn.lib.makeJjinn pkgs {
  executable = lib.getExe pkgs.claude-code;
  sandboxInputs = with pkgs; [
    claude-code
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
  homeBinds = [ ".claude" ];
}
```
