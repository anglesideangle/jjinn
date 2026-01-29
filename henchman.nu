#!/usr/bin/env nu

const OPENCODE_CONFIG = {
  "$schema": "https://opencode.ai/config.json"
  instructions: ["/INSTRUCTIONS.md"]
}

def render_dev_env [dev_env: record]: nothing -> string {
  def sh_quote [s: string]: nothing -> string {
    if ($s | str contains "'") {
      let parts = ($s | split row "'")
      $"'" + ($parts | str join "'\"'\"'") + "'"
    } else {
      $"'" + $s + "'"
    }
  }

  def render_scalar [name: string, type: string, val: string]: nothing -> list<string> {
    [ $"($name)=((sh_quote $val))" ] | append (if $type == "exported" {[$"export ($name)"]} else {[]})
  }

  def render_array [name: string, items: list<any>]: nothing -> list<string> {
    let elems = ($items | each {|x| sh_quote ($x | into string) } | str join " ")
    [ $"declare -a ($name)=(($elems))" ]
  }

  let var_lines = (
    $dev_env.variables
    | transpose name rec
    | each {|row|
        match $row.rec.type {
          "array" => (render_array $row.name ($row.rec.value | default []))
          "exported" => (render_scalar $row.name "exported" ($row.rec.value | into string))
          "var" => (render_scalar $row.name "var" ($row.rec.value | into string))
          _ => (render_scalar $row.name $row.rec.type ($row.rec.value | into string))
        }
      }
    | flatten
  )

  let fn_lines = (
    if ($dev_env.bashFunctions? == null) { [] } else {
      $dev_env.bashFunctions
      | transpose fname body
      | each {|r|
          [
            $"($r.fname) ()"
            "{"
            ($r.body | into string)
            "}"
          ]
        }
      | flatten
    }
  )

  # Function definitions depend on vars so the vars must come first.
  ($var_lines | append $fn_lines | str join "\n") + "\n"
}


# Returns the root of the current jj repository.
#
# Errors if the top level repo either does not exist or does not contain a `flake.nix`.
def repo_root [] {
  let root = (do { ^jj root } | str trim)
  if ($root | is-empty) {
    error make { msg: $"No jj repository found in ($env.PWD)." }
  }

  let flake = ($root | path join "flake.nix")
  if not ($flake | path exists) {
    error make { msg: $"No flake.nix found at repo root ($root)." }
  }

  $root
}

# Returns the closure of a list of nix derivations as a list of paths.
def nix_closure [...anchors: string]: nothing -> list<string> {
  ^nix path-info --recursive ...$anchors | lines
}


def render_instructions [store_paths] {
  const INSTRUCTIONS_TEMPLATE = "
# Environment Details

You are running inside a sandbox created by `henchman edit`.

## Workflow

- Use `jj describe` to record changes as you make progress.
- Use `jj new` or `jj edit` if you need to restructure commits.
- Run `nix build` and `nix flake check` for the relevant changed code before you finish, ensure all tests pass.

## Environment

- The repository metadata (`.jj`) is mounted so changes persist.
- `/workspace` is writable and is the only checkout you should modify.

## Available Nix Store Paths

{{PATHS}}
  "

  let tools = ($store_paths | each { |path| $"- ($path)" } | str join "\n")
  $INSTRUCTIONS_TEMPLATE | str replace "{{TOOLS}}" $tools
}


# Returns a single revision id from a revset string.
def revset_id [revset: string] {
  let ids = (do {
      ^jj log -r $revset --no-graph --template "commit_id.short() ++ \"\\n\""
    }
    | lines
  )

  if ($ids | length) != 1 {
    error make { msg: $"Revset ($revset) must resolve to exactly one commit." }
  }

  $ids | get 0
}


# Runs the provided `command` inside the worktree.
def edit_worktree [
  revset: string # The jj revset to create the worktree from
  command: closure # The closure to call with the constructed worktree's path
] {
  let root = (repo_root)
  let short_id = (revset_id $revset)
  let worktree = (mktemp --tmpdir --directory)

  let cleanup = {
    ^jj workspace forget $short_id
    rm -r $worktree
  }

  try {
    ^jj workspace add --name $short_id --revision $revset $worktree
    do $command $worktree
  } catch { $cleanup }

  do $cleanup
}


def prepend_path [bins: list<string>]: string -> string {
  let base_path = $in | split row ":"
  ($bins
    | append $base_path
    | compact --empty
    | uniq
    | str join ":"
  )
}

def bwrap_run [revset: string, share_net: bool, share_dev: bool, ...args: string] {
  let repo_root = (repo_root)
  let repo_meta = $repo_root | path join ".henchman"
  mkdir $repo_meta
  let profile = $repo_meta | path join "profile"

  let dev_json = (^nix print-dev-env --json --profile $profile $"($repo_root)#" | complete)
  if $dev_json.exit_code != 0 {
    error make { msg: $"nix print-dev-env failed: ($dev_json.stderr | str trim)" }
  }
  mut dev_env = $dev_json.stdout | from json

  let anchor = (^readlink --canonicalize $profile) | str trim
  let sandbox_inputs = $env.SANDBOX_INPUTS | lines
  let closure = nix_closure $anchor ...$sandbox_inputs

  let shell_path = $dev_env.variables.SHELL.value

  # prepend the path
  let extra_bins = $sandbox_inputs | each {|p| $"($p)/bin" }
  $dev_env.variables.PATH.value = $dev_env.variables.PATH.value | prepend_path $extra_bins

  let dev_script = render_dev_env $dev_env

  let bwrap_args = ([
    "--unshare-all"
    "--die-with-parent"
    # "--new-session"
    "--clearenv"
    "--proc" "/proc"
    "--tmpfs" "/tmp"
    # "--bind" $worktree "/workspace"
    "--chdir" "/workspace"
    "--setenv" "HOME" "/workspace"
    # "--setenv" "OPENCODE_CONFIG_CONTENT" ($OPENCODE_CONFIG | to json -r)
    "--ro-bind" $repo_root $repo_root
    "--bind" ($repo_root | path join ".jj") ($repo_root | path join ".jj")
    # "--ro-bind" $instructions_path "/INSTRUCTIONS.md"
  ] | append ($closure | each { |path| [ "--ro-bind" $path $path ] } | flatten)
    # | append ($exported_vars | where k != "PATH" | each {|kv| [ "--setenv" $kv.k $kv.v] } | flatten)
    | append (if $share_net {["--share-net"]} else {[]})
    | append (if $share_dev {["--dev-bind" "/dev" "/dev"]} else {["--dev"]})
    # | append [ "--" $shell_path $"($dev_script)\n(...$args)"]
    )

  let ws_arg = { |worktree| ["--bind" $worktree "/workspace"] }
  let shell_cmd = [$shell_path "-c" $dev_script ...$args]

  edit_worktree $revset { |worktree| ^bwrap ...$bwrap_args (...$ws_arg worktree) $shell_cmd}
}


# edits with opencode
def "main edit" [revset: string = "@", --network = true, --dev = false] {
  bwrap_run $revset $network $dev opencode
}


# testing with shell
def "main shell" [revset: string = "@", --network = true, --dev = false] {
  bwrap_run $revset $network $dev
}


# cool command
def main [] {
  print "Usage: henchman edit [revset] [--network true|false] [--dev true|false]\n  henchman shell [revset] [--network true|false] [--dev true|false]"
}
