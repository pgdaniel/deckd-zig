# Packaging

Both packages build **from this git checkout directly** — there's no source
tarball step. To deploy to another server: get a clone of deckd-zig onto it
(git clone/pull, rsync, whatever), install `zig` (pinned version in
`../.tool-versions`), then build in place.

Both put the binary at `/usr/bin/deckd` and ship
`packaging/udev/71-streamdeck.rules` (hidraw access for the `input` group,
for boxes with no logind desktop session) plus `README.md` as docs. Neither
package writes `~/.config/deckd/config.json` — that stays yours to copy or
manage separately (e.g. with your dotfiles / config-management tool).

## Arch (`pacman/`)

```
cd packaging/pacman
makepkg -si
```

`pkgver` is derived from `git rev-list --count HEAD` + short hash (no tags
in this repo yet), so it bumps automatically as commits land. Installs
`systemd/deckd.service` as a **user** unit
(`/usr/lib/systemd/user/deckd.service`):

```
systemctl --user daemon-reload
systemctl --user enable --now deckd
```

## Slackware (`slackware/`)

```
cd packaging/slackware
./deckd.SlackBuild
installpkg /tmp/deckd-*.txz
```

Slackware has no systemd by default, so this ships a sysvinit script
instead (`rc.deckd.new` → `/etc/rc.d/rc.deckd.new`) that runs deckd as an
unprivileged user via `su`. `/usr/doc/deckd-*/README.SLACKWARE` (also
printed in the SlackBuild's header comment) has the enable steps. If the
target box does run systemd, use the bundled
`deckd.service.example` (same file as the Arch package's unit) instead of
the rc script.

## Both packages

- Build with `-Dcpu=baseline` instead of build.zig's default `-Dcpu=native`,
  so the binary isn't tied to the exact CPU it was built on — relevant if
  you build once and ship the resulting package to other servers rather
  than rebuilding on each.
- Neither enables/starts the service automatically on install; that's a
  manual step so you can set config and hidraw access up first.
