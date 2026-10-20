#!/usr/bin/env bash
# All fixtures, fake homes, checkouts and install destinations stay in this repo.
# shellcheck disable=SC2016 # Fixture scripts must contain literal shell variables.
set -euo pipefail
export LC_ALL=C
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_COUNT=0 GIT_CONFIG_PARAMETERS=''
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TOOL="$ROOT/theme-link"
GIT=$(command -v git)
TEST_ROOT=$(mktemp -d "$ROOT/.test-tmp.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT
passed=0
failed=0

fail() { printf '  FAIL: %s\n' "$*" >&2; exit 1; }
assert_exists() { [[ -e $1 || -L $1 ]] || fail "Missing: $1"; }
assert_absent() { [[ ! -e $1 && ! -L $1 ]] || fail "Unexpected: $1"; }
assert_contains() { [[ $output == *"$1"* ]] || fail "Output missing '$1': $output"; }
assert_ok() { (( status == 0 )) || fail "Exit $status: $output"; }
assert_error() { (( status != 0 )) || fail "Unexpected success: $output"; }
assert_clean_temp() {
  local path
  for path in "$STORE"/.theme-link-tmp.*; do assert_absent "$path"; done
}
run() {
  if output=$(env -i PATH="$CASE/bin:$PATH" HOME="$CASE/home" XDG_CONFIG_HOME="$CASE/config" \
    "$TOOL" "$@" </dev/null 2>&1); then status=0; else status=$?; fi
}
init_repo() {
  "$GIT" -c init.defaultBranch=main init -q "$1"
}
commit_repo() {
  "$GIT" -C "$1" add --all
  "$GIT" -C "$1" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
}
add_theme() { run add "$REPO" "${1:-rose}" --yes; assert_ok; }
fixture() {
  CASE="$TEST_ROOT/$1"
  mkdir -p "$CASE/bin" "$CASE/home" "$CASE/source"
  STORE="$CASE/config/theme-link-store"
  THEMES="$CASE/config/omarchy/themes"
  CONFIG="$CASE/config/theme-link/config"
  REPO="$CASE/source"
  printf '[colors]\nbackground = "#112233"\n' >"$REPO/colors.toml"
  init_repo "$REPO"
  commit_repo "$REPO"
}
write_config() {
  mkdir -p "${CONFIG%/*}"
  printf '%s\n' "$@" >"$CONFIG"
}
interactive() {
  local answer=$1 invocation
  shift
  printf -v invocation '%q ' env -i PATH="$CASE/bin:$PATH" HOME="$CASE/home" \
    XDG_CONFIG_HOME="$CASE/config" "$TOOL" "$@"
  if output=$(printf '%s\n' "$answer" | script -qec "$invocation" /dev/null 2>&1); then status=0; else status=$?; fi
}

help_and_version() {
  write_config 'invalid config'
  run --help; assert_ok; assert_contains 'UNSUPPORTED'; assert_contains 'executable code'
  run --version; assert_ok; assert_contains 'theme-link 0.1.0'
  run; assert_ok; assert_contains 'Usage:'
  assert_absent "$STORE"
}

xdg_defaults_are_read_only() {
  run config show; assert_ok; assert_contains "store_dir = \"$STORE\""; assert_contains "themes_dir = \"$THEMES\""
  run config path; assert_ok; [[ $output == "$CONFIG" ]] || fail 'Wrong config path'
  run list; assert_ok; assert_contains 'No managed themes.'
  assert_absent "$CASE/config"
}

home_fallback() {
  output=$(env -i PATH="$PATH" HOME="$CASE/home" "$TOOL" config show)
  assert_contains "$CASE/home/.config/theme-link-store"
  assert_contains "$CASE/home/.config/omarchy/themes"
  assert_absent "$CASE/home/.config"
}

config_init_no_overwrite() {
  run config init; assert_ok; assert_exists "$CONFIG"
  [[ $(stat -c %a "$CONFIG") == 600 ]] || fail 'Config should be private'
  cp -- "$CONFIG" "$CASE/original"
  run config init; assert_error; assert_contains 'Refusing to overwrite'
  cmp -- "$CONFIG" "$CASE/original"
  run config show; assert_ok; assert_contains "$STORE"
  assert_absent "$STORE"
}

explicit_config_lifecycle() {
  local custom="$CASE/custom settings/config"
  run --config "$custom" list; assert_error; assert_contains 'Config does not exist'
  run --config "$custom" config path; assert_ok; [[ $output == "$custom" ]] || fail 'Wrong explicit path'
  run --config "$custom" config init; assert_ok
  run --config "$custom" add "$REPO" rose --yes; assert_ok
  assert_exists "$STORE/rose/.git"
  assert_absent "$CONFIG"
}

quoted_paths_crlf_no_newline() {
  local custom_store="$CASE/store #1 = colors" custom_themes="$CASE/themes with spaces"
  mkdir -p "${CONFIG%/*}"
  printf '# comment\r\n\tstore_dir = "%s"\r\nthemes_dir = '\''%s'\''' "$custom_store" "$custom_themes" >"$CONFIG"
  add_theme
  [[ $(readlink -- "$custom_themes/rose") == "$custom_store/rose" ]] || fail 'Wrong custom link'
  run list; assert_ok; assert_contains $'rose\tlinked'
}

tilde_paths() {
  write_config 'store_dir = ~/my themes' 'themes_dir = ~/my links'
  add_theme
  assert_exists "$CASE/home/my themes/rose/colors.toml"
  [[ $(readlink -- "$CASE/home/my links/rose") == "$CASE/home/my themes/rose" ]] || fail 'Tilde not expanded'
}

invalid_config_rejected() {
  local text
  for text in 'bad_key = /tmp/x' 'store_dir = relative/path' 'store_dir =' 'not a setting' \
    $'store_dir = /a\nstore_dir = /b' $'themes_dir = /a\nthemes_dir = /b' $'store_dir = /a\033bad'; do
    write_config "$text"
    run list; assert_error
    assert_absent "$STORE"
  done
}

config_is_not_shell_code() {
  local literal="$CASE/\$(touch $CASE/EXECUTED)"
  write_config "store_dir = $literal" "themes_dir = $THEMES"
  run config show; assert_ok; assert_contains "$literal"
  assert_absent "$CASE/EXECUTED"
  write_config "store_dir = $CASE/backtick-\`touch $CASE/EXECUTED\`"
  run config show; assert_ok
  assert_absent "$CASE/EXECUTED"
}

overlapping_paths_rejected() {
  local store themes
  while read -r store themes; do
    write_config "store_dir = $store" "themes_dir = $themes"
    run list; assert_error
  done <<EOF
$CASE/shared $CASE/shared
$CASE/shared $CASE/shared/nested
$CASE/shared/nested $CASE/shared
/ $CASE/links
$CASE/store /
EOF
  mkdir -p "$CASE/real"
  ln -s -- "$CASE/real" "$CASE/alias"
  write_config "store_dir = $CASE/real" "themes_dir = $CASE/alias/nested"
  run list; assert_error; assert_contains 'non-nested'
}

config_must_stay_outside_managed_paths() {
  write_config "store_dir = ${CONFIG%/*}" "themes_dir = $THEMES"
  run list; assert_error; assert_contains 'Keep the config file outside'
}

bad_xdg_and_home() {
  if output=$(env -i PATH="$PATH" HOME="$CASE/home" XDG_CONFIG_HOME=relative "$TOOL" list 2>&1); then fail 'Relative XDG path accepted'; fi
  if output=$(env -i PATH="$PATH" HOME=relative "$TOOL" list 2>&1); then fail 'Relative HOME accepted'; fi
}

roundtrip_keeps_edits() {
  add_theme
  assert_contains 'WARNING'; assert_contains 'bypass'; assert_contains 'Not activated'
  assert_exists "$STORE/rose/.git"
  [[ $(readlink -- "$THEMES/rose") == "$STORE/rose" ]] || fail 'Wrong symlink'
  printf 'local edit\n' >>"$STORE/rose/colors.toml"
  run list; assert_ok; assert_contains $'rose\tlinked'
  run remove rose --yes; assert_ok; assert_contains 'Checkout kept'
  assert_absent "$THEMES/rose"
  assert_exists "$STORE/rose/.git"
  grep -q 'local edit' "$STORE/rose/colors.toml"
  run list; assert_ok; assert_contains $'rose\tunlinked'
  run link rose --yes; assert_ok; assert_contains 'WARNING'; assert_contains 'Not activated'
  assert_exists "$THEMES/rose/colors.toml"
  run remove rose --delete --yes; assert_ok; assert_contains 'ALL local files, edits and Git history'
  assert_absent "$STORE/rose"
  assert_absent "$STORE/.theme-link/rose"
  assert_absent "$THEMES/rose"
}

name_derivation() {
  local named="$CASE/omarchy-ROSE-theme.git"
  mv -- "$REPO" "$named"
  run add "$named" --yes; assert_ok
  assert_exists "$STORE/rose/colors.toml"
}

invalid_names_rejected() {
  local name
  for name in .. .hidden ../escape -option 'with spaces' 'x;touch BAD' 'éclair' "$(printf '%081d' 0)"; do
    run add "$REPO" "$name" --yes; assert_error
    assert_absent "$STORE"
  done
  run add "$REPO" -- .. --yes; assert_error
  run add "$REPO" '' --yes; assert_error
}

unsafe_urls_rejected_before_clone() {
  local url
  for url in '--upload-pack=sh' 'ext::sh -c touch-BAD' 'https::helper' 'ftp://example.invalid/theme.git' \
    'http://example.invalid/theme.git' 'git://example.invalid/theme.git' 'relative/path' $'https://host/a\nb' \
    $'https://host/a\033b'; do
    run add "$url" rose --yes; assert_error
    assert_absent "$STORE"
  done
}

remote_url_names_without_network() {
  local url name
  # A fake git routes accepted remote forms to a real local fixture. No network.
  printf '#!/bin/bash\nexec %q clone -q --no-local -- %q "${@: -1}"\n' "$GIT" "$REPO" >"$CASE/bin/git"
  chmod +x "$CASE/bin/git"
  while read -r url name; do
    run add "$url" --yes; assert_ok
    assert_exists "$STORE/$name/colors.toml"
  done <<'EOF'
https://example.invalid/me/omarchy-blue-theme.git blue
ssh://git@example.invalid/me/omarchy-green-theme.git green
git@example.invalid:omarchy-red-theme.git red
example.invalid:me/omarchy-purple-theme.git purple
EOF
}

no_theme_script_or_activation() {
  printf '#!/bin/bash\ntouch %q\n' "$CASE/EXECUTED" >"$REPO/install.sh"
  printf 'os.execute("touch %s")\n' "$CASE/EXECUTED" >"$REPO/neovim.lua"
  printf '[submodule "untrusted"]\npath = untrusted\nurl = ext::sh -c touch-BAD\n' >"$REPO/.gitmodules"
  chmod +x "$REPO/install.sh"
  commit_repo "$REPO"
  printf '#!/bin/bash\ntouch %q\nexit 99\n' "$CASE/ACTIVATED" >"$CASE/bin/omarchy"
  chmod +x "$CASE/bin/omarchy"
  add_theme
  assert_exists "$STORE/rose/install.sh"
  assert_exists "$STORE/rose/neovim.lua"
  assert_absent "$STORE/rose/untrusted"
  assert_absent "$CASE/EXECUTED"
  assert_absent "$CASE/ACTIVATED"
  run list; assert_ok
}

git_configuration_cannot_run_code() {
  mkdir -p "$CASE/template/hooks"
  printf '#!/bin/bash\ntouch %q\n' "$CASE/EXECUTED" >"$CASE/template/hooks/post-checkout"
  cp -- "$CASE/template/hooks/post-checkout" "$CASE/malicious-filter"
  chmod +x "$CASE/template/hooks/post-checkout" "$CASE/malicious-filter"
  printf '*.toml filter=evil\n' >"$REPO/.gitattributes"
  commit_repo "$REPO"
  "$GIT" config --file "$CASE/home/.gitconfig" init.templateDir "$CASE/template"
  "$GIT" config --file "$CASE/home/.gitconfig" core.hooksPath "$CASE/template/hooks"
  "$GIT" config --file "$CASE/home/.gitconfig" core.fsmonitor "$CASE/malicious-filter"
  "$GIT" config --file "$CASE/home/.gitconfig" filter.evil.smudge "$CASE/malicious-filter"
  "$GIT" config --file "$CASE/home/.gitconfig" url.ext::bad.insteadOf "$REPO"
  if output=$(env -i PATH="$PATH" HOME="$CASE/home" XDG_CONFIG_HOME="$CASE/config" \
    GIT_DIR="$CASE/not-a-repo" GIT_WORK_TREE="$CASE/foreign" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$CASE/template/hooks" \
    GIT_CONFIG_PARAMETERS="'core.hooksPath=$CASE/template/hooks'" \
    "$TOOL" add "$REPO" rose --yes 2>&1); then status=0; else status=$?; fi
  assert_ok
  assert_absent "$CASE/EXECUTED"
  assert_absent "$STORE/rose/.git/hooks/post-checkout"
  assert_exists "$STORE/rose/colors.toml"
}

file_url_supported() {
  run add "file://$REPO" rose --yes; assert_ok
  assert_exists "$STORE/rose/colors.toml"
}

legacy_theme_supported() {
  mv -- "$REPO/colors.toml" "$REPO/alacritty.toml"
  commit_repo "$REPO"
  add_theme
  assert_exists "$STORE/rose/alacritty.toml"
}

invalid_theme_cleanup() {
  rm -- "$REPO/colors.toml"
  commit_repo "$REPO"
  run add "$REPO" rose --yes; assert_error; assert_contains 'expected a nonempty'
  assert_absent "$STORE/rose"
  assert_absent "$STORE/.theme-link/rose"
  assert_absent "$THEMES/rose"
  assert_clean_temp
}

symlink_palette_rejected() {
  rm -- "$REPO/colors.toml"
  ln -s -- "$CASE/outside" "$REPO/colors.toml"
  printf 'outside\n' >"$CASE/outside"
  commit_repo "$REPO"
  run add "$REPO" rose --yes; assert_error
  assert_absent "$STORE/rose"
  assert_clean_temp
}

empty_palette_rejected() {
  : >"$REPO/colors.toml"
  commit_repo "$REPO"
  run add "$REPO" rose --yes; assert_error
  assert_absent "$STORE/rose"
  assert_clean_temp
}

clone_failure_cleanup() {
  run add "$CASE/absent-repository" rose --yes; assert_error; assert_contains 'Clone failed'
  assert_absent "$STORE/rose"
  assert_absent "$STORE/.theme-link/rose"
  assert_absent "$THEMES/rose"
  assert_clean_temp
}

existing_theme_directory_preserved() {
  mkdir -p "$THEMES/rose"
  printf 'precious\n' >"$THEMES/rose/keep"
  run add "$REPO" rose --yes; assert_error; assert_contains 'Refusing to overwrite'
  assert_exists "$THEMES/rose/keep"
  assert_absent "$STORE"
}

existing_and_dangling_links_preserved() {
  mkdir -p "$THEMES"
  ln -s -- "$CASE/missing" "$THEMES/rose"
  run add "$REPO" rose --yes; assert_error
  [[ $(readlink -- "$THEMES/rose") == "$CASE/missing" ]] || fail 'Overwrote dangling link'
  assert_absent "$STORE"
}

existing_checkout_preserved() {
  mkdir -p "$STORE/rose"
  printf 'precious\n' >"$STORE/rose/keep"
  run add "$REPO" rose --yes; assert_error
  assert_exists "$STORE/rose/keep"
  run remove rose --delete --yes; assert_error; assert_contains 'Not a managed checkout'
  assert_exists "$STORE/rose/keep"
}

readd_requires_explicit_relink() {
  add_theme
  run remove rose --yes; assert_ok
  run add "$REPO" rose --yes; assert_error; assert_contains 'theme-link link rose'
  assert_absent "$THEMES/rose"
  assert_exists "$STORE/rose/.git"
}

list_status_and_unmanaged_entries() {
  add_theme
  mkdir -p "$STORE/unmanaged"
  run list; assert_ok; assert_contains $'rose\tlinked'
  [[ $output != *unmanaged* ]] || fail 'Listed an unmanaged directory'
  rm -- "$THEMES/rose"
  mkdir -p "$THEMES/rose"
  run list; assert_ok; assert_contains $'rose\tconflict'
  rmdir -- "$THEMES/rose"
  run list; assert_ok; assert_contains $'rose\tunlinked'
  rm -rf -- "$STORE/rose"
  run list; assert_ok; assert_contains $'rose\tmissing'
}

remove_foreign_path_refused() {
  add_theme
  rm -- "$THEMES/rose"
  mkdir -p "$THEMES/rose"
  printf 'precious\n' >"$THEMES/rose/keep"
  run remove rose --delete --yes; assert_error; assert_contains 'unmanaged path'
  assert_exists "$THEMES/rose/keep"
  assert_exists "$STORE/rose/.git"
}

remove_foreign_symlink_refused() {
  add_theme
  rm -- "$THEMES/rose"
  ln -s -- "$CASE/source" "$THEMES/rose"
  run remove rose --delete --yes; assert_error
  assert_exists "$REPO/colors.toml"
  assert_exists "$STORE/rose/.git"
}

symlinked_checkout_refused() {
  add_theme
  rm -rf -- "$STORE/rose"
  ln -s -- "$REPO" "$STORE/rose"
  run list; assert_ok; assert_contains $'rose\tunsafe'
  run remove rose --delete --yes; assert_error; assert_contains 'symlinked checkout'
  assert_exists "$REPO/colors.toml"
  assert_exists "$THEMES/rose"
}

broken_link_can_be_unlinked_and_record_removed() {
  add_theme
  rm -rf -- "$STORE/rose"
  run remove rose --yes; assert_ok
  assert_absent "$THEMES/rose"
  assert_exists "$STORE/.theme-link/rose"
  run remove rose --delete --yes; assert_ok
  assert_absent "$STORE/.theme-link/rose"
}

noninteractive_confirmation_is_explicit() {
  run add "$REPO" rose; assert_error; assert_contains 'WARNING'; assert_contains 'explicitly pass --yes'
  assert_absent "$STORE"
  add_theme
  run remove rose --delete; assert_error; assert_contains 'PERMANENT DELETE'
  assert_exists "$STORE/rose/.git"
  assert_exists "$THEMES/rose/colors.toml"
  run remove rose --yes; assert_ok
  run link rose; assert_error; assert_contains 'WARNING'
  assert_absent "$THEMES/rose"
}

interactive_decline_and_accept() {
  interactive n add "$REPO" rose; assert_error; assert_contains 'Cancelled'
  assert_absent "$STORE"
  interactive y add "$REPO" rose; assert_ok; assert_contains 'Linked rose'
  assert_exists "$STORE/rose/.git"
  interactive n remove rose --delete; assert_error
  assert_exists "$THEMES/rose/colors.toml"
}

missing_ownership_and_git_refused() {
  run link rose --yes; assert_error
  add_theme
  run remove rose --yes; assert_ok
  rm -rf -- "$STORE/rose/.git"
  run link rose --yes; assert_error; assert_contains 'Missing or unsafe Git checkout'
  run remove rose --delete --yes; assert_error
  assert_exists "$STORE/rose/colors.toml"
}

unsafe_registry_refused() {
  mkdir -p "$STORE" "$CASE/foreign-registry"
  ln -s -- "$CASE/foreign-registry" "$STORE/.theme-link"
  run add "$REPO" rose --yes; assert_error; assert_contains 'Unsafe managed-state directory'
  assert_absent "$STORE/rose"
  assert_absent "$CASE/foreign-registry/rose"
}

symlinked_ownership_record_refused() {
  add_theme
  rm -- "$STORE/.theme-link/rose"
  printf 'theme-link-v1\n' >"$CASE/foreign-record"
  ln -s -- "$CASE/foreign-record" "$STORE/.theme-link/rose"
  run remove rose --delete --yes; assert_error; assert_contains 'Not a managed checkout'
  assert_exists "$STORE/rose/colors.toml"
}

concurrent_operations_refused() {
  mkdir -p "$STORE"
  exec {held_lock}<"$STORE"
  flock --exclusive "$held_lock"
  run add "$REPO" rose --yes; assert_error; assert_contains 'Store is busy'
  assert_absent "$STORE/rose"
  exec {held_lock}<&-
  add_theme
}

configured_symlink_roots_resolved() {
  mkdir -p "$CASE/real-store" "$CASE/real-themes" "${STORE%/*}" "${THEMES%/*}"
  ln -s -- "$CASE/real-store" "$STORE"
  ln -s -- "$CASE/real-themes" "$THEMES"
  add_theme
  [[ $(readlink -- "$THEMES/rose") == "$CASE/real-store/rose" ]] || fail 'Store alias was not resolved'
  run list; assert_ok; assert_contains $'rose\tlinked'
  run remove rose --delete --yes; assert_ok
  assert_absent "$CASE/real-store/rose"
}

link_failure_rolls_back_new_checkout() {
  printf '#!/bin/bash\nexit 42\n' >"$CASE/bin/ln"
  chmod +x "$CASE/bin/ln"
  run add "$REPO" rose --yes; assert_error; assert_contains 'Could not create theme symlink'
  assert_absent "$STORE/rose"
  assert_absent "$STORE/.theme-link/rose"
  assert_absent "$THEMES/rose"
  assert_clean_temp
}

link_race_preserves_foreign_directory() {
  local real_ln
  real_ln=$(command -v ln)
  printf '#!/bin/bash\nmkdir -p -- %q\nprintf precious >%q\nexec %q "$@"\n' \
    "$THEMES/rose" "$THEMES/rose/keep" "$real_ln" >"$CASE/bin/ln"
  chmod +x "$CASE/bin/ln"
  run add "$REPO" rose --yes; assert_error
  assert_exists "$THEMES/rose/keep"
  assert_absent "$STORE/rose"
  assert_absent "$STORE/.theme-link/rose"
  assert_clean_temp
}

checkout_move_race_preserves_foreign_directory() {
  local real_mv
  real_mv=$(command -v mv)
  printf '#!/bin/bash\nmkdir -p -- %q\nprintf precious >%q\nexec %q "$@"\n' \
    "$STORE/rose" "$STORE/rose/keep" "$real_mv" >"$CASE/bin/mv"
  chmod +x "$CASE/bin/mv"
  run add "$REPO" rose --yes; assert_error; assert_contains 'Refusing to overwrite'
  assert_exists "$STORE/rose/keep"
  assert_absent "$STORE/.theme-link/rose"
  assert_absent "$THEMES/rose"
  assert_clean_temp
}

interrupted_clone_cleanup() {
  printf '#!/bin/bash\nmkdir -p -- "${@: -1}"\nkill -TERM "$PPID"\nexit 143\n' >"$CASE/bin/git"
  chmod +x "$CASE/bin/git"
  run add "$REPO" rose --yes; assert_error
  assert_absent "$STORE/rose"
  assert_absent "$STORE/.theme-link/rose"
  assert_absent "$THEMES/rose"
  assert_clean_temp
}

interrupted_checkout_move_cleanup() {
  local real_mv
  real_mv=$(command -v mv)
  printf '#!/bin/bash\n%q "$@" || exit\nkill -TERM "$PPID"\nexit 143\n' "$real_mv" >"$CASE/bin/mv"
  chmod +x "$CASE/bin/mv"
  run add "$REPO" rose --yes; assert_error
  assert_absent "$STORE/rose"
  assert_absent "$STORE/.theme-link/rose"
  assert_absent "$THEMES/rose"
  assert_clean_temp
}

interrupted_record_move_cleanup() {
  local real_mv
  real_mv=$(command -v mv)
  printf '#!/bin/bash\n%q "$@" || exit\nif [[ ${@: -1} == */.theme-link/rose ]]; then kill -TERM "$PPID"; exit 143; fi\n' \
    "$real_mv" >"$CASE/bin/mv"
  chmod +x "$CASE/bin/mv"
  run add "$REPO" rose --yes; assert_error
  assert_absent "$STORE/rose"
  assert_absent "$STORE/.theme-link/rose"
  assert_absent "$THEMES/rose"
  assert_clean_temp
}

interrupted_symlink_creation_cleanup() {
  local real_ln
  real_ln=$(command -v ln)
  printf '#!/bin/bash\n%q "$@" || exit\nkill -TERM "$PPID"\nexit 143\n' "$real_ln" >"$CASE/bin/ln"
  chmod +x "$CASE/bin/ln"
  run add "$REPO" rose --yes; assert_error
  assert_absent "$STORE/rose"
  assert_absent "$STORE/.theme-link/rose"
  assert_absent "$THEMES/rose"
  assert_clean_temp
}

invalid_options_rejected() {
  local args
  for args in '--unknown' '--config' 'no-command' 'list extra' 'add' 'link' 'remove' \
    'config extra' 'config show extra' 'list --delete' 'list --yes' 'add /path --config /a --config /b'; do
    # These intentional space-separated test cases contain no quoted paths.
    read -r -a parts <<<"$args"
    run "${parts[@]}"; assert_error
  done
  run --config '' list; assert_error
  assert_absent "$STORE"
}

install_is_one_file_and_staged() {
  make -s -C "$ROOT" install DESTDIR="$CASE/staged root" PREFIX=/usr
  cmp -- "$TOOL" "$CASE/staged root/usr/bin/theme-link"
  [[ -x $CASE/staged\ root/usr/bin/theme-link ]] || fail 'Installed CLI is not executable'
  assert_absent "$CASE/config"
}

# Do not run a test function inside an if/||: that would disable Bash errexit
# inside the entire function and silently weaken the assertions.
tests=(
  help_and_version xdg_defaults_are_read_only home_fallback config_init_no_overwrite
  explicit_config_lifecycle quoted_paths_crlf_no_newline tilde_paths invalid_config_rejected
  config_is_not_shell_code overlapping_paths_rejected config_must_stay_outside_managed_paths
  bad_xdg_and_home roundtrip_keeps_edits name_derivation invalid_names_rejected
  unsafe_urls_rejected_before_clone remote_url_names_without_network no_theme_script_or_activation
  git_configuration_cannot_run_code file_url_supported legacy_theme_supported invalid_theme_cleanup symlink_palette_rejected
  empty_palette_rejected clone_failure_cleanup existing_theme_directory_preserved
  existing_and_dangling_links_preserved existing_checkout_preserved readd_requires_explicit_relink
  list_status_and_unmanaged_entries remove_foreign_path_refused remove_foreign_symlink_refused
  symlinked_checkout_refused broken_link_can_be_unlinked_and_record_removed
  noninteractive_confirmation_is_explicit interactive_decline_and_accept missing_ownership_and_git_refused
  unsafe_registry_refused symlinked_ownership_record_refused concurrent_operations_refused
  configured_symlink_roots_resolved
  link_failure_rolls_back_new_checkout link_race_preserves_foreign_directory
  checkout_move_race_preserves_foreign_directory interrupted_clone_cleanup
  interrupted_checkout_move_cleanup interrupted_record_move_cleanup interrupted_symlink_creation_cleanup
  invalid_options_rejected
  install_is_one_file_and_staged
)
for test_name in "${tests[@]}"; do
  set +e
  (
    set -e
    fixture "$test_name"
    "$test_name"
  ) >"$TEST_ROOT/result" 2>&1
  result=$?
  set -e
  if (( result == 0 )); then
    printf 'ok  %s\n' "$test_name"
    passed=$((passed + 1))
  else
    printf 'FAIL  %s\n' "$test_name"
    while IFS= read -r line; do printf '  %s\n' "$line"; done <"$TEST_ROOT/result"
    failed=$((failed + 1))
  fi
done
printf '\n%s passed; %s failed. No live configuration was changed.\n' "$passed" "$failed"
(( failed == 0 ))
