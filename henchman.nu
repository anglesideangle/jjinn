#!/usr/bin/env nu
# const OPENCODE_CONFIG = {
#   "$schema": "https://opencode.ai/config.json"
#   instructions: ["/INSTRUCTIONS.md"]
# }

# Safetly quote bash string
def sh_quote [s: string] {
  if ($s | str contains "'") {
    let parts = ($s | split row "'")
    $"'" + ($parts | str join "'\"'\"'") + "'"
  } else { $"'" + $s + "'" }
}

# Render scalar nix dev env value to bash declaration
def render_scalar [name: string, type: string, val: string] {
  [
    $"($name)=((sh_quote $val))"
  ] | append (if $type == "exported" { [
    $"export ($name)"
  ] } else { [] })
}

# Render array nix dev env value to bash declaration
def render_array [name: string, items: list<any>] {
  let elems = ($items | each {|x| sh_quote ($x | into string) } | str join " ")
  [ $"declare -a ($name)=\(($elems)\)" ]
}

# Render full nix dev env record to bash initialization script
def render_dev_env [dev_env: record] {
  let var_lines = (
    $dev_env.variables | transpose name rec | each {|row|
        match $row.rec.type {
          "array" => (render_array $row.name ($row.rec.value | default []))
          "exported" => (render_scalar $row.name "exported" ($row.rec.value | into string))
          "var" => (render_scalar $row.name "var" ($row.rec.value | into string))
          _ => (render_scalar $row.name $row.rec.type ($row.rec.value | into string))
        }
      } | flatten
  )
  let fn_lines = $dev_env.bashFunctions | default {} | transpose fname body | each {|r|
          [
            $"($r.fname) \(\)"
            "{"
            ($r.body | into string)
            "}"
          ]
        } | flatten

  # Function definitions depend on vars so the vars must come first.
  ($var_lines | append $fn_lines | str join "\n") + "\n"
}

# Returns the root of the current jj repository.
#
# Errors if the top level repo either does not exist or does not contain a `flake.nix`.
def repo_root [] {
  let root = ^jj root | str trim
  let flake = ($root | path join "flake.nix")
  if not ($flake | path exists) { error make {
    msg: $"No flake.nix found at repo root ($root)."
  } }
  $root
}

# Returns the closure of a list of nix derivations as a list of paths.
def nix_closure [...anchors: string] {
  ^nix path-info --recursive ...$anchors | lines
}

# def render_instructions [store_paths] {
#   const INSTRUCTIONS_TEMPLATE = "
# # Environment Details
# You are running inside a sandbox created by `henchman edit`.
# ## Workflow
# - Use `jj describe` to record changes as you make progress.
# - Use `jj new` or `jj edit` if you need to restructure commits.
# - Run `nix build` and `nix flake check` for the relevant changed code before you finish, ensure all tests pass.
# ## Environment
# - The repository metadata (`.jj`) is mounted so changes persist.
# - `/workspace` is writable and is the only checkout you should modify.
# ## Available Nix Store Paths
# {{PATHS}}
#   "
#   let tools = ($store_paths | each { |path| $"- ($path)" } | str join "\n")
#   $INSTRUCTIONS_TEMPLATE | str replace "{{TOOLS}}" $tools
# }

# Returns a single revision id from a revset string.
def revset_id [revset: string] {
  let ids = ^jj log -r $revset --no-graph --template "commit_id.short() ++ \"\\n\"" | lines
  if ($ids | length) != 1 { error make {
    msg: $"Revset ($revset) must resolve to exactly one commit."
  } }
  $ids | first
}

# Runs the provided `command` inside the worktree.
def edit_worktree [
  revset: string, # The jj revset to create the worktree from.
  command: closure, # The closure to call with the constructed worktree's path.
]: nothing -> nothing {
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
  } catch {|err|
    $cleanup
    error make {
      msg: "An error occurred while inside the worktree."
      inner: [$err]
    }
  }

  do $cleanup
}

# Prepends the provided list of binaries to a path string delimiteed by `:`
def prepend_path [bins: list<string>] {
  let base_path = $in | split row ":"
  $bins | append $base_path | compact --empty | uniq | str join ":"
}

# Returns the relevant xdg directories for storing application data from an
# environment record.
def get_xdg_dirs [environment: record] {
  let home = $environment.HOME
  {
    config: (
    $environment.XDG_CONFIG_HOME? | default ($home | path join ".config"))
    data: ($environment.XDG_DATA_HOME? | default ($home | path join ".local" "share"))
    state: ($environment.XDG_STATE_HOME? | default ($home | path join ".local" "state"))
    cache: ($environment.XDG_CACHE_HOME? | default ($home | path join ".cache"))
  }
}

# Runs the provided `cmd` inside a bwrap sandbox with a worktree and closure.
def bwrap_run [
  revset: string
  share_net: bool
  share_dev: bool
  ...cmd: string
] {
  let repo_root = (repo_root)
  let repo_meta = $repo_root | path join ".henchman"
  mkdir $repo_meta

  let profile = $repo_meta | path join "profile"
  mut dev_env = (^nix print-dev-env --json --profile $profile $"($repo_root)#") | from json

  let anchor = (^readlink --canonicalize $profile) | str trim
  let sandbox_inputs = $env.SANDBOX_INPUTS? | default "" | lines
  let closure = nix_closure $anchor ...$sandbox_inputs
  let shell_path = $dev_env.variables.SHELL.value? | default $env.FALLBACK_BASH

  let extra_bins = $sandbox_inputs | each {|p| $"($p)/bin" }
  $dev_env.variables.PATH.value = $dev_env.variables.PATH.value | prepend_path $extra_bins

  let init_path = $repo_meta | path join "activate.sh"
  $"(render_dev_env $dev_env)\nexec \"$@\"" | save --force $init_path

  let user_xdg = get_xdg_dirs $env | transpose key user
  let sandbox_xdg = get_xdg_dirs {
    HOME: $dev_env.variables.HOME.value
  } | transpose key sandbox

  let closure_args = $closure
    | each { |path| [ "--ro-bind" $path $path ] }
    | flatten

  let net_args = if $share_net { [
    "--share-net"
    "--ro-bind" "/etc/resolv.conf" "/etc/resolv.conf"
    "--ro-bind" "/etc/hosts" "/etc/hosts"
    "--overlay-src" "/etc/ssl" "--tmp-overlay" "/etc/ssl"
  ] } else { [] }

  let dev_args = if $share_dev {
    ["--dev-bind", "/dev", "/dev"]
  } else { ["--dev", "/dev"] }

  let xdg_args = $user_xdg
    | join $sandbox_xdg key
    | compact --empty
    | each {|r| [
        "--bind"
        ($r.user | path join "opencode")
        ($r.sandbox | path join "opencode")
      ]}
    | flatten

  let bwrap_args = {|worktree|
    [
      "--unshare-all"
      "--die-with-parent"
      "--proc" "/proc"
      "--tmpfs" "/tmp"
      "--bind" $worktree "/workspace"
      "--chdir" "/workspace"
      "--ro-bind" $repo_root $repo_root
      "--bind" ($repo_root | path join ".jj") ($repo_root | path join ".jj")
      "--bind" ($repo_root | path join ".git") ($repo_root | path join ".git")
    ]
    | append $closure_args
    | append $net_args
    | append $dev_args
    | append $xdg_args
    | append $shell_path
    | append $init_path
    | append $cmd
  }
  edit_worktree $revset {|worktree| ^bwrap ...(do $bwrap_args $worktree) }
}

# Spawns opencode in a sandbox containing the devshell from this project's `flake.nix` and the specified jj revision.
def "main" [
  revset: string = @, # The revision to edit in the worktree environment.
  --network = true, # Whether to allow network access from the sandbox. This is recommended as opencode currently tries to install bun modules at runtime.
  --dev = false, # Whether to mount devices into the sandbox.
] {
  bwrap_run $revset $network $dev opencode
}

# Enters the sandbox environment with an interactive shell.
def "main debug" [
  revset: string = @, # The revision to edit in the worktree environment.
  --network = true, # Whether to allow network access from the sandbox. This is recommended as opencode currently tries to install bun modules at runtime.
  --dev = false, # Whether to mount devices into the sandbox.
] {
  bwrap_run $revset $network $dev "bash" "-i"
}
