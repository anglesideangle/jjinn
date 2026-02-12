#!/usr/bin/env nu

def --wrapped nix [...args: string] {
  (^nix
    --option warn-dirty "false"
    --extra-experimental-features "nix-command flakes"
    ...$args)
}

def --wrapped jj [...args: string] {
  let result = (^jj ...$args | complete)
  if ($result.stdout | is-not-empty) {
    $result.stdout | lines | each {|line| print $">>> ($line)" }
  }
  if ($result.stderr | is-not-empty) {
    $result.stderr | lines | each {|line| print $">>> ($line)" }
  }
  if $result.exit_code != 0 {
    error make {
      msg: "jj command failed."
      help: $result.stderr
    }
  }
}

# Safely quote bash string
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

# Returns the closure of a list of nix derivations as a list of paths.
def nix_closure [...anchors: string] {
  nix path-info --recursive ...$anchors | lines
}

# Returns a single full revision id from a revset string.
def revset_id [repo: path, revset: string] {
  (^jj log
    --repository $repo
    -r $revset
    --no-graph
    --template "commit_id"
  ) | complete | get stdout
}

# Runs the provided `command` inside a temporary worktree.
#
# Syncs the worktree to the `repo` after `command` terminates, regardless of
# success and then removes the worktree.
def edit_worktree [
  repo: path,
  revset: string, # The jj revset to create the worktree from.
  command: closure, # The closure to call with the constructed worktree's path.
]: nothing -> nothing {
  let worktree = (mktemp --tmpdir --directory jjinn-XXXX)
  let base_id = (revset_id $repo $revset)
  let workspace_id = ($worktree | path basename)

  # Ensure the workspace syncs with the main repo, then delete the workspace.
  let cleanup = {
    let commit_id = do -i { revset_id $worktree @ }

    let has_changes = (
      ^jj diff
        --repository $worktree
        --from $base_id
        --summary
    ) | complete
      | get stdout
      | is-not-empty

    if $has_changes {
      print "Temporary workspace changes are now in:"
      (jj log
        --repository $repo
        --color always
        --limit 1
        -r $commit_id)
    } else {
      jj abandon --repository $repo $commit_id | ignore
    }

    jj workspace forget --repository $repo $workspace_id | ignore
    rm -r $worktree | ignore
  }

  try {
    jj workspace add --repository $repo --name $workspace_id --revision $revset $worktree
    do $command $worktree
  } catch {|err|
    do $cleanup
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


# Spawns a command in a sandbox containing the devshell from this project's
# `flake.nix` and the specified jj revision.
@example "Edit from the current revision" {jjinn}
@example "Edit from the previous commit in `./project` using the `my-package` devshell output" {jjinn @- --repo project --devshell "my-package"}
def main [
  revision: string = @, # The parent revision of the the worktree environment.
  --repo (-R): path, # The repository to operate on. It must contain a top level
  # `flake.nix`. If left unspecified, the closest parent directory containing
  # `.jj/` will be used.
  --devshell (-s) = "default", # The devshell output to target.
  --network = true, # Whether to allow network access from the sandbox.
  --dev = false, # Whether to mount devices into the sandbox.
  --print-bwrap, # Prints the bwrap command instead of executing it.
]: nothing -> nothing {
  let repo_root = if $repo == null {
    ^jj root | str trim
  } else {
    $repo
  } | path expand

  let flake = ($repo_root | path join "flake.nix")
  if not ($flake | path exists) { error make {
    msg: $"No flake.nix found at repo root ($repo_root)."
  } }

  let repo_meta = $repo_root | path join ".jjinn"
  mkdir $repo_meta

  let profile = $repo_meta | path join "profile"
  mut env_result = (nix print-dev-env --json --profile $profile $"($repo_root)#($devshell)") | complete

  if $env_result.exit_code != 0 {
    error make {
      msg: "nix print-dev-env failed."
      label: {
        text: $"devshell=($devshell) profile=($profile)"
        span: (metadata $env_result).span
      }
      help: $env_result.stderr
    }
  }

  mut dev_env = $env_result.stdout | from json

  let anchor = (^readlink --canonicalize $profile) | str trim
  let sandbox_inputs = $env.SANDBOX_INPUTS? | default "" | lines
  let closure = nix_closure $anchor ...$sandbox_inputs

  let shell_path = (
    match $dev_env.variables.SHELL.value? {
      "/noshell" => null
      $shell => $shell
    } | default $env.FALLBACK_BASH
  )

  let extra_bins = $sandbox_inputs | each {|p| $"($p)/bin" }
  $dev_env.variables.PATH.value = $dev_env.variables.PATH.value | prepend_path $extra_bins

  let init_path = $repo_meta | path join "activate.sh"
  $"(render_dev_env $dev_env)\nexec \"$@\"" | save --force $init_path

  let closure_args = $closure
    | each { |path| [ "--ro-bind" $path $path ] }
    | flatten

  let net_args = if $network {
    let ca_certs = $env.CA_DIR | path join "ca-bundle.crt"
    [
      "--share-net"
      "--ro-bind" "/etc/resolv.conf" "/etc/resolv.conf"
      "--ro-bind" "/etc/hosts" "/etc/hosts"
      "--setenv" "SSL_CERT_FILE" $ca_certs
      "--setenv" "NIX_SSL_CERT_FILE" $ca_certs
    ]
  } else { [] }

  let dev_args = if $dev {
    ["--dev-bind", "/dev", "/dev"]
  } else { ["--dev", "/dev"] }

  let sandbox_env = $dev_env.variables
    | transpose name rec
    | where name in [
        "HOME"
        "XDG_CONFIG_HOME"
        "XDG_DATA_HOME"
        "XDG_STATE_HOME"
        "XDG_CACHE_HOME"
      ]
    | reduce -f {} {|row, acc|
      $acc | upsert $row.name $row.rec.value?
    }

  let user_xdg = get_xdg_dirs $env | transpose key user
  let sandbox_xdg = get_xdg_dirs $sandbox_env | transpose key sandbox
  let xdg_dirs = $user_xdg | join $sandbox_xdg key | compact --empty

  let xdg_bind_args = $env.XDG_BINDS
    | default ""
    | lines
    | each { |program|
        $xdg_dirs | each { |dir| [
          "--bind-try"
          ($dir.user | path join $program)
          ($dir.sandbox | path join $program)
        ]} | flatten
      }
    | flatten

  let home_bind_args = $env.HOME_BINDS?
    | default ""
    | lines
    | each { |path| [
        "--bind-try"
        ($env.HOME | path join $path)
        ($sandbox_env.HOME | path join $path)
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
      "--bind-try" ($repo_root | path join ".git") ($repo_root | path join ".git")
      "--overlay-src" "/nix/var/nix" "--tmp-overlay" "/nix/var/nix"
    ]
    | append $closure_args
    | append $net_args
    | append $dev_args
    | append $xdg_bind_args
    | append $home_bind_args
    | append $shell_path
    | append $init_path
    | append [ $env.EXECUTABLE ]
  }

  if $print_bwrap {
    print (do $bwrap_args "<worktree>")
  } else {
    edit_worktree $repo_root $revision {|worktree| ^bwrap ...(do $bwrap_args $worktree) }
  }
}
