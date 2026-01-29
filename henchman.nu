#!/usr/bin/env nu

# const OPENCODE_CONFIG = {
#   "$schema": "https://opencode.ai/config.json"
#   instructions: ["/INSTRUCTIONS.md"]
# }

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
  [ $"declare -a ($name)=\(($elems)\)" ]
}

def render_dev_env [dev_env: record]: nothing -> string {
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
            $"($r.fname) \(\)"
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
  let ids =  ^jj log -r $revset --no-graph --template "commit_id.short() ++ \"\\n\"" | lines

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
    ^jj workspace add --name $short_id --revision $revset $worktree | complete
    do $command $worktree
  } catch { |err: error|
    print $err.rendered
    $cleanup
  }

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

def get_xdg_dirs [environment: record] {
  let home = $environment.HOME
  {
    # home: home
    config: ($environment.XDG_CONFIG_HOME? | default ($home | path join ".config"))
    data: ($environment.XDG_DATA_HOME? | default ($home | path join ".local" "share"))
    state: ($environment.XDG_STATE_HOME? | default ($home | path join ".local" "state"))
    cache: ($environment.XDG_CACHE_HOME? | default ($home | path join ".cache"))
    # runtime: $environment.XDG_RUNTIME_DIR?
  }
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
  let sandbox_inputs = $env.SANDBOX_INPUTS? | default "" | lines
  let closure = nix_closure $anchor ...$sandbox_inputs

  let shell_path = $dev_env.variables.SHELL.value

  # prepend the path
  let extra_bins = $sandbox_inputs | each {|p| $"($p)/bin" }
  $dev_env.variables.PATH.value = $dev_env.variables.PATH.value | prepend_path $extra_bins

  let init_path = $repo_meta | path join "activate.sh"
  $"(render_dev_env $dev_env)\nexec \"$@\"" | save --force $init_path

  let user_xdg = get_xdg_dirs $env | transpose key user
  let sandbox_xdg = get_xdg_dirs { HOME: $dev_env.variables.HOME.value } | transpose key sandbox

  let closure_args = $closure | each { |path| [ "--ro-bind" $path $path ] } | flatten
  let net_args = if $share_net {
    [
      "--share-net"
      "--ro-bind" "/etc/resolv.conf" "/etc/resolv.conf"
      "--ro-bind" "/etc/hosts" "/etc/hosts"
      # "--ro-bind" "/etc/ssl/certs" "/etc/ssl/certs"
      "--overlay-src" "/etc/ssl" "--tmp-overlay" "/etc/ssl"
    ]
  } else {[]}
  let dev_args = if $share_dev {["--dev-bind" "/dev" "/dev"]} else {["--dev" "/dev"]}
  let xdg_args = $user_xdg | join $sandbox_xdg key | compact --empty | each {|r| ["--bind" ($r.user | path join "opencode") ($r.sandbox | path join "opencode")]} | flatten

  let bwrap_args = { |worktree| [
    "--unshare-all"
    "--die-with-parent"
    # "--clearenv"
    "--proc" "/proc"
    "--tmpfs" "/tmp"
    "--bind" $worktree "/workspace"
    "--chdir" "/workspace"
    "--ro-bind" $repo_root $repo_root
    "--bind" ($repo_root | path join ".jj") ($repo_root | path join ".jj")
    # "--setenv" "OPENCODE_CONFIG_CONTENT" ($OPENCODE_CONFIG | to json -r)
    # "--ro-bind" $instructions_path "/INSTRUCTIONS.md"
  ] | append $closure_args
    | append $net_args
    | append $dev_args
    | append $xdg_args
    | append [ $shell_path $init_path ]
    | append $args
  }

  edit_worktree $revset { |worktree| ^bwrap ...(do $bwrap_args $worktree) }
}


# Spawns opencode in a sandbox containing the devshell from this project's `flake.nix` and the specified jj revision.
def "main" [
  revset: string = "@", # The revision to edit in the worktree environment.
  --network = true, # Whether to allow network access from the sandbox. This is recommended as opencode currently tries to install bun modules at runtime.
  --dev = false # Whether to mount devices into the sandbox.
] {
  bwrap_run $revset $network $dev opencode
}


# Enters the sandbox environment with an interactive shell.
def "main debug" [revset: string = "@", --network = true, --dev = false] {
  bwrap_run $revset $network $dev "bash" "-i"
}
