# theme-link

A small Bash tool that clones trusted theme repositories into a user-owned store and symlinks them into Omarchy. No automatic activation, updates, package installation, or theme-script execution.

## WARNING: unsupported, executable code

**This is not the supported Omarchy theme installer. Only use themes from sources you trust.**

Themes can contain executable code. Applying or using one can execute that code with your user permissions, including access to your files and credentials. A directory under `.config` is **not a sandbox or security boundary**.

Some Omarchy versions treat a symlinked theme as a trusted local working copy, bypassing restrictions applied to normally installed Git themes. This tool does not sanitize themes or reproduce the supported installer's safeguards. Compatibility with future Omarchy changes is not guaranteed.

`add` and `link` always display a prominent warning and ask for explicit confirmation. Noninteractive use requires `--yes`; it does **not** hide the warning. This is a trust decision, not a safety certification.

## Requirements

- Linux, Bash 4.4+, Git, GNU coreutils, and util-linux `flock`.
- Omarchy to use the linked themes. The tool itself does not invoke Omarchy.
- No Python, Node, TUI framework, network service, or package manager required.

## Run or install

Run directly from this directory:

```sh
./theme-link --help
./theme-link config init
```

Optional user-local installation:

```sh
make install
```

This installs only the executable at `~/.local/bin/theme-link`. Ensure that directory is on `PATH`. It does not create configuration, clone a theme, or change your desktop. `PREFIX` and `DESTDIR` are supported; no `sudo` is needed for the default prefix.

## Commands

```text
theme-link add GIT_URL [NAME]
theme-link link NAME
theme-link list
theme-link remove NAME
theme-link remove NAME --delete
theme-link config show
theme-link config path
theme-link config init
```

Replace `GIT_URL` with a trusted repository URL. HTTPS, SSH, scp-style SSH, absolute local paths, and absolute `file` URLs are supported. Insecure HTTP, Git's unauthenticated native transport, arbitrary remote helpers, relative local paths, and option-like URLs are rejected.

- **`add`** clones into a temporary directory inside the store, checks the basic theme layout, moves the checkout into place, and creates the symlink. Existing files, directories, symlinks (including dangling ones), or checkouts are never overwritten. A failed add rolls back its new checkout and record when possible.
- **`link`** re-links a managed checkout kept after removal. It shows the trust warning again. It never adopts an arbitrary existing directory.
- **`list`** prints tab-separated names and states: `linked`, `unlinked`, `conflict`, `missing`, or `unsafe`. It lists managed entries only, without fetching or changing configuration. `conflict` means something else occupies the link path; `missing` or `unsafe` means the checkout needs inspection.
- **`remove`** confirms, unlinks only a symlink resolving to the corresponding managed checkout, and retains the checkout and its local changes. It never removes an unmanaged theme or changes the active Omarchy theme.
- **`remove --delete`** additionally confirms permanent deletion of the checkout and management record, **including local edits, untracked files, and local commits**. No trash or undo. Also works for an already unlinked checkout or a stale record whose checkout is missing. It refuses a symlinked checkout or an existing checkout without an ordinary `.git` directory.
- **`config init`** writes a small private config using the defaults. It never overwrites an existing file. **`config show`** prints the effective settings; **`config path`** prints the resolved config location, even if the config is missing or invalid.

`--yes` / `-y` accepts a command's warning or confirmation explicitly. Normal add/link/remove require a terminal; piped input is not treated as consent. Configuration and list commands never prompt.

Options can appear before or after the command. `--` ends option parsing. Errors return nonzero; `--help` and `--version` work even with invalid configuration. Command feedback goes to stderr; listing/configuration data goes to stdout.

### Theme names and layout

When `NAME` is omitted, it is derived from the repository basename: lowercase it, remove `.git`, a leading `omarchy-`, and a trailing `-theme`. For example, a repository named `omarchy-rose-theme.git` becomes `rose`.

Names must be 1–80 lowercase ASCII letters, digits, hyphens, or underscores, beginning with a letter or digit. Supply a name explicitly if the inferred name does not meet those rules. A name matching an Omarchy stock theme can overlay that theme; choose a unique name if that is not intended.

The repository root must contain a nonempty, non-symlink `colors.toml`, or a legacy `alacritty.toml`. This is only a basic layout check: the tool does not parse TOML, inspect all contents, audit code, or guarantee theme compatibility. Other theme files are retained unchanged. Submodules are not initialized and Git LFS filters are not run.

After reviewing the checkout, apply it yourself through Omarchy. For a theme named `rose`:

```sh
omarchy theme set rose
```

The tool never does this on your behalf. Removing its source does not undo a previously applied theme; Omarchy may retain staged files, while external references to the source may stop working.

## Configuration

Defaults, with `XDG_CONFIG_HOME` unset:

```text
~/.config/theme-link/config
~/.config/theme-link-store/rose/
~/.config/omarchy/themes/rose -> ~/.config/theme-link-store/rose
```

All three default locations use `$XDG_CONFIG_HOME`, falling back to `~/.config`. A default config is optional. Create one only to pin or customize settings:

```sh
theme-link config init
```

The entire configuration can be:

```ini
store_dir = ~/.config/theme-link-store
themes_dir = ~/.config/omarchy/themes
```

`config init` writes resolved absolute paths, so its settings stay fixed if the environment later changes. See `config.example` for a hand-written version.

- Only `store_dir` and `themes_dir` are accepted; unknown or duplicate keys are errors.
- Values must be absolute paths or start with `~/`. Optional matching single or double outer quotes preserve whitespace.
- Blank lines and full-line `#` comments are accepted. No inline comments, sections, escape processing, environment-variable expansion, or command substitution.
- The file is parsed as data, **never sourced or evaluated**. Literal dollar signs and backticks in an absolute path remain literal.
- Directory symlinks are resolved. Store and theme directories must be distinct and cannot contain each other. Keep the config file outside both.
- Changing a setting does not move or migrate existing checkouts or links. Unlink using the old settings before relocating a store, then restore/re-link deliberately.

To select another config:

```sh
theme-link --config ~/my-theme-link.conf config init
theme-link --config ~/my-theme-link.conf list
```

An explicitly selected file must exist for operational commands. A missing default config uses defaults; `config init` and `config path` may target a missing file.

**Omarchy's actual discovery path matters:** some versions hardcode `~/.config/omarchy/themes` rather than honoring `XDG_CONFIG_HOME`. If yours does, set `themes_dir` to that location explicitly. A custom directory is useful for testing but will not teach Omarchy a new theme path.

## Git, updates, and local work

Clones retain their full Git history and ordinary `.git` directory. No shallow clone or hardlink-based local clone is used. There is no automatic update or `update` command: inspect upstream changes and manage a checkout deliberately with Git. Re-linking does not fetch or reset anything.

During cloning, theme-link disables inherited Git global/system configuration, templates, hooks, filters, URL rewrites, config injections, and arbitrary remote-helper transports. Consequently, global Git credential helpers, proxy settings, and Git-configured SSH commands are not used. For private repositories, prefer SSH using your SSH agent and `~/.ssh/config`; those remain active and must be trusted. HTTPS terminal credential prompts are disabled. Avoid embedding tokens in a URL: the supplied source is displayed and Git retains the remote URL.

The Git/SSH executables, your SSH configuration, and your user environment must be trusted. Keep Git updated. No wrapper can make arbitrary remote content safe or defend against other processes running as you.

## State and failure handling

The store contains a private `.theme-link/` directory with one ownership record per checkout. Theme contents cannot create that record during cloning. Do not copy a record to make another directory look managed, or delete records for retained checkouts. Unmanaged entries are never adopted or deleted.

Operations acquire a nonblocking filesystem lock on the store itself, so two theme-link processes cannot mutate the same store concurrently, even through different configs. A busy store reports an error instead of waiting silently. External Git/filesystem operations do not honor this lock automatically; do not edit or move managed paths during a theme-link operation.

Normal errors and catchable interruptions clean up temporary clones and roll back newly created entries where possible. Inode checks prevent rollback from deleting a conflicting checkout or record. Empty parent/state directories can remain after a failed add. A power loss, `SIGKILL`, permission change, or filesystem failure can still leave partial state. Inspect before removing stale `.theme-link-tmp.*` directories or repairing records; the tool deliberately refuses ambiguous paths instead of overwriting them. This is not a transactional filesystem or a sandbox.

For removal, an unlink may succeed before deletion fails. The error says so and retains the management record for inspection and retry. There is no automatic activation, reactivation, or desktop rollback.

## Development

```sh
make check
```

This runs Bash syntax checks, ShellCheck, and the integration suite. Development additionally needs `shellcheck`, `make`, and util-linux `script` for real terminal-confirmation tests. `make test` runs just the integration suite.

Tests use local Git repositories, fake homes/configurations, injected failures, and a staged install, all under this project directory. No network access, global installation, or changes to your live Omarchy configuration are needed.
