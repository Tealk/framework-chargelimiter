# dms-framework-charge-limit

Bar widget and Control Center tile for the battery charge limit of a Framework
laptop, built for [Dux Shell](https://github.com/duxlabs-dev/dux-shell).

The plugin reads and writes the limit through `framework_tool` from
[framework-system](https://github.com/FrameworkComputer/framework-system). The
bar shows the limit, the popout has a slider and `100 / 80 / 60 %` presets, and
the Control Center tile toggles between "no limit" (100 %) and the preset you
pick in the settings.

## Requirements

- A Framework laptop whose EC supports the charge limit (Laptop 12, Laptop 13,
  Laptop 16 and the Desktop).
- `framework_tool` on `PATH`. It is called `framework_tool` everywhere except in
  the Snap package, where it is `framework-tool`; both are detected.
  - Arch: `pacman -S framework-system`
  - Fedora: `dnf install framework-system` (Terra repo)
  - Debian/Ubuntu: `apt install framework-tool`
  - others: `cargo install --locked framework_tool`
- Dux Shell 2.0 or newer.

The EC rejects limits below 25 %, so the slider spans 25–100 %.

## Installation

```sh
git clone https://github.com/tealk/framework-chargelimiter \
    ~/.config/dms/plugins/FrameworkChargeLimit
dms ipc call plugins list
```

Enable it under Settings → Plugins, then add the widget to a bar or to the
Control Center.

## Privileges

`framework_tool` talks to the embedded controller through `/dev/cros_ec` or raw
port I/O, and both need root. Reading and writing go through the same command, so
the mode you pick applies to both. Set it in the plugin settings under
**Privilege mode**.

### pkexec (default, no setup)

Every change opens the polkit dialog. Dux Shell provides the polkit agent
(`PolkitService`), so no separate agent like `polkit-gnome` is needed.

`pkexec` runs detached from the widget, because the dialog belongs to the shell
and outlives the popout. The detached shell writes stdout and the exit code to
`$XDG_RUNTIME_DIR/dms-framework-charge-limit.result`. The limit is applied
immediately and rolled back when the authorization fails. A result file left by
an earlier session is applied once at startup.

Reads are not run through pkexec unless you press **Reload**.

### sudoers (no password prompt)

Install the shipped wrapper and allow only that wrapper. The wrapper accepts
nothing but `--charge-limit` with an optional percentage, which keeps the rule
from matching other `framework_tool` options such as `--flash-ec`.

```sh
sudo install -o root -g root -m 0755 contrib/framework-charge-limit /usr/local/bin/framework-charge-limit
```

```sudoers
# /etc/sudoers.d/framework-charge-limit
tealk ALL=(root) NOPASSWD: /usr/local/bin/framework-charge-limit
```

Validate with `sudo visudo -c`, then set **Privilege mode** to `sudo -n`. Nothing
else is needed: in that mode the plugin looks for `framework-charge-limit` on
`PATH` and at `/usr/local/bin` and uses it in preference to `framework_tool`. The
path setting is only for a different location.

#### Why the wrapper has to be a copy

`NOPASSWD` applies to whatever sits at the configured path, independent of its
owner. A rule on a script inside `~/.config/dms/plugins/` would let every change
to that checkout — by `git pull` or the registry updater — run as root, and a
symlink in `/usr/local/bin` resolves to the same writable target.

sudo closes that gap with `fdexec` (default `digest_only`), but only when the
rule carries a digest:

```sudoers
tealk ALL=(root) NOPASSWD: sha256:… /usr/local/bin/framework-charge-limit
```

Without a digest the file has to be root-owned. The copy is a snapshot: re-run
the `install` command after changing `contrib/framework-charge-limit`.

There is no direct-access mode. `/dev/cros_ec` is a `misc` character device owned
by `root:root` with mode `0600`, so it is unreadable without elevation.

## Status reads

The firmware fixes the charge limit, so it does not change on its own. The widget
reads it at startup, after every change and on **Reload**.

A status read needs root as well, so the last confirmed value is kept in a plugin
global variable and mirrored into the plugin state file. The global variable is
shared by the bar widget, the Control Center tile and the Control Center detail
page, which are separate instances of the plugin.

After a shell restart the state file seeds the value, so the widget shows the last
known limit instead of `–`. In `pkexec` mode that cached value stays until you
press **Reload** or change the limit. With `sudo -n`, startup reads and the
refresh interval run silently.

The plugin does not read sysfs. The built-in charge limit in Settings → Battery
uses `/sys/class/power_supply/BAT*/charge_control_limit_max`,
`charge_stop_threshold` and `charge_control_end_threshold`; those attributes are
created by `cros-charge-control`, which needs an EC device node that Framework's
EC firmware does not provide. This plugin talks to the EC through `framework_tool`
instead.

The battery percentage comes from `BatteryService`.

## Settings

| Setting                         | Meaning                                                                            |
| ------------------------------- | ---------------------------------------------------------------------------------- |
| Privilege mode                  | `pkexec` or `sudo -n`, see above                                                   |
| framework_tool path             | Override the detected binary; in `sudo -n` mode the wrapper is found automatically |
| Preset for the on/off toggle    | Limit the Control Center tile switches to (default 80 %)                           |
| Refresh interval                | Seconds between status reads, 0 disables polling                                   |
| Show percentage in the bar      | Draw the limit next to the icon                                                    |
| Notify after changing the limit | Toast on success                                                                   |

## Troubleshooting

**"framework_tool was not found"** — the binary is not on the `PATH` of the shell
that Dux Shell runs in. Set the full path in the settings.

**"The sudoers wrapper is missing"** — `framework-charge-limit` is neither on
`PATH` nor at `/usr/local/bin`. Run the `install` command above.

**Exit code 126** — pkexec could not get authorization: the dialog was dismissed,
or the shell's polkit agent is disabled (`DMS_DISABLE_POLKIT=1`).

**The password field appears and closes immediately** — the authorization request
was aborted before a password was read. `pkexec /usr/bin/framework_tool
--charge-limit` in a terminal shows whether this also happens outside the plugin;
a PAM module in `/etc/pam.d/polkit-1`, such as `pam_fprintd`, can end the request.

**"sudo asked for a password"** — the sudoers rule is missing or names another
user.

**The limit does not stick** — `framework_tool --charge-limit` in a terminal
reports the error that the plugin receives.

## Development

```sh
ln -sfn "$PWD" ~/.config/dms/plugins/FrameworkChargeLimit
dms ipc call plugins reload frameworkChargeLimit
```

The tool parses the line `Minimum 25%, Maximum 80%` printed by
`framework_tool --charge-limit`; the maximum is the charge limit. The command
line of `framework_tool` is not a stable interface, so a future change to that
line breaks the parser first.

## Registry entry

`contrib/tealk-framework-charge-limit.json` is the entry for
[dux-plugin-registry](https://github.com/duxlabs-dev/dux-plugin-registry), to be
copied to `plugins/`. Its `screenshot` field points at `Screenshot2.png` in this
repository.

## License

MIT
