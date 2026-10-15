# dell-goodix-538d-linux

Build and install a driver for the **Goodix 27c6:538d** fingerprint sensor on
Ubuntu. The sensor is found in several Dell laptops (Inspiron 5402, 5409,
5502, 7501, 7506; Vostro 5490), and it has no official Linux driver: upstream
libfprint lists it as unsupported, and Dell's proprietary Goodix driver does
not cover it.

This repository contains no driver code of its own. It builds a community
fork of libfprint that adds a `goodixtls53xd` driver
([lbssousa/libfprint](https://github.com/lbssousa/libfprint)), from one
pinned, reviewed commit, and installs it so that no Ubuntu file is overwritten.

> [!WARNING]
> Community driver, no vendor support. Read [Security](#security) before
> using a fingerprint to log in.

## Does it work on my laptop?

Check the sensor ID:

```console
$ lsusb | grep 27c6
Bus 003 Device 002: ID 27c6:538d Shenzhen Goodix Technology Co.,Ltd. FingerPrint
```

If it says `538d`, the probe step below tells you, without installing anything,
whether the driver accepts your unit. The driver only works with firmware
`GF5298_GM168SEC_APP_13016` and the sensor's TLS key set to all zeros.

- Sensors that still have the factory key generally pass.
- Windows' Goodix driver can set its own key. Then the probe fails with
  `Invalid device PSK`. The only known fix is to reflash the sensor with
  [goodix-fp-dump](https://github.com/goodix-fp-linux-dev/goodix-fp-dump).
  That tool can brick the sensor, and its own authors call it unstable.
  **This project does not support or automate reflashing.**

## Install

Needs Ubuntu 26.04 (other recent releases probably work) and about 300 MB for
the build. Clone the repository, read the scripts (they are short), then:

```bash
# Build tools, all from the Ubuntu archive
sudo apt install git meson ninja-build pkgconf gcc g++ binutils \
    libglib2.0-dev libgusb-dev libgudev-1.0-dev libpixman-1-dev libssl-dev \
    libcairo2-dev gobject-introspection libgirepository1.0-dev

scripts/fetch.sh    # clone the fork and check out the pinned commit
scripts/build.sh    # build as your normal user; installs nothing
scripts/probe.sh    # ask the sensor if it is compatible; installs nothing
scripts/install.sh  # only after the probe passed
```

Never pipe a script from the internet into a shell, this one included.

### What each step does

| Script | Runs as | Changes |
| --- | --- | --- |
| `fetch.sh` | you | clones the fork into `work/src` and refuses anything but the commit in [`PIN`](PIN) |
| `build.sh` | you | builds into `work/build` and stamps the build with the commit and the library's checksum; meson may not download anything |
| `probe.sh` | you; `sudo` for `systemctl` and one program | blocks and stops fprintd, opens the sensor once to read its firmware and key, then unblocks fprintd (it starts again on demand). Writes nothing to the sensor |
| `install.sh` | you; `sudo` for copying, `systemctl` and replacing `/opt/dell-goodix-538d` | copies one library to `/opt/dell-goodix-538d`, adds a systemd drop-in so only fprintd loads it, restarts fprintd. If anything fails, even Ctrl-C, it rolls back |
| `verify.sh` | you; `sudo` to start fprintd and read its memory map | checks the installed files against their checksums, the drop-in, fprintd's needed functions, and that fprintd uses the library |
| `uninstall.sh` | you; `sudo` | removes the drop-in, `/opt/dell-goodix-538d` and the sensor calibration file |

The scripts refuse to let root run or copy anything from `work/` if another
user could have changed it. If you see `writable by group or others`, run the
`chmod go-w` command the error suggests. (Folders writable only by your own
private group, which is Ubuntu's default for home folders, are fine. The check
uses `getent`, so on machines with network accounts that are not enumerated,
such as some LDAP setups, run `chmod go-w` on your clone to be safe.)

If the probe is killed hard (for example `kill -9`), fprintd stays blocked
until the next reboot. Unblock it with `sudo systemctl unmask --runtime fprintd`.

After installing:

```bash
fprintd-enroll   # touch the sensor until enrollment completes
fprintd-verify   # check it recognizes you
```

You can delete `work/` afterwards.

## Log in and unlock only (recommended)

Ubuntu turns fingerprint authentication on everywhere by default: login, the
lock screen, `sudo`, polkit prompts and `su`. We recommend fingerprint only for
GNOME login and unlock:

```bash
sudo pam-auth-update --remove fprintd
```

This removes fingerprint from `/etc/pam.d/common-auth` (`sudo`, polkit, `su`,
text consoles). GNOME's login and lock screens keep working, because they use
`/etc/pam.d/gdm-fingerprint`, which calls fprintd directly. Your password
works everywhere as before.

To enable fingerprint everywhere anyway: `sudo pam-auth-update --enable fprintd`.

## Uninstall

```bash
fprintd-delete "$USER"   # prints made with this driver don't work without it
scripts/uninstall.sh
```

fprintd goes back to Ubuntu's libfprint. Running it twice is harmless.

## Updates

- **Ubuntu's `libfprint-2-2` package:** upgrades don't matter. fprintd keeps
  loading the library in `/opt`.
- **`fprintd` package:** a future fprintd could need libfprint functions this
  build lacks. Then fprintd would fail to start, and your password would
  still work. After fprintd updates, run `scripts/verify.sh`, which re-checks
  this. If you'd rather not deal with it, hold the package:
  `sudo apt-mark hold fprintd`.
- **This project:** pull and repeat fetch, build, probe and install. A new pin
  means a new reviewed fork commit (see [SECURITY.md](SECURITY.md)).

## How it works

fprintd is the system service that talks to fingerprint readers. GNOME and
PAM ask it over D-Bus. It loads one library, `libfprint-2.so.2`.
`install.sh` adds:

```ini
# /etc/systemd/system/fprintd.service.d/10-dell-goodix-538d.conf
[Service]
Environment=LD_LIBRARY_PATH=/opt/dell-goodix-538d/lib
```

so fprintd, and only fprintd, loads the fork's build instead of Ubuntu's.
Nothing else on the system links libfprint. `pam_fprintd`, GDM and polkit go
through fprintd, so they get the new driver too.

The build keeps libfprint's usual drivers. Every other reader that Ubuntu's
libfprint supports keeps working, except Ubuntu's proprietary "TOD" driver
plugins, which the fork doesn't load.

## Security

- **Pinned source.** `PIN` names one full commit hash. `fetch.sh` and
  `build.sh` refuse any other checkout or local changes. meson runs with
  `--wrap-mode=nodownload`.
- **What we reviewed at the pinned commit:** the fork adds about 7,400
  lines over upstream libfprint (the `goodixtls` driver and the SIGFM
  matcher).
  - The only networking is an in-process `socketpair()` that carries TLS to
    the USB device.
  - It runs no other programs.
  - It never writes the sensor's key or firmware.
  - Files it writes:
    - a calibration file in fprintd's state directory
    - raw fingerprint images, but only when the `GOODIX53XD_DUMP` environment
      variable is set. Nothing here sets it; don't set it.
- **Root boundaries.** The build runs as you. Before root runs or copies
  anything from `work/`, the scripts check that no other user can write to
  those files or the folders above them. The probe result and the install are
  tied to the exact library `build.sh` produced, by its checksum. Installed
  files are root-owned, and their checksums (taken on the installed copies)
  go in `MANIFEST`.
- **Limits of this sensor on Linux. Know them before using it for anything
  that matters:**
  - The TLS key between the laptop and the sensor is all zeros and public.
    So the link isn't secret, and a USB device pretending to be this sensor
    would be accepted. That is why we recommend fingerprint only for login and
    unlock, not `sudo`.
  - Matching runs on the laptop, not on the sensor. That's weaker than
    match-on-chip readers.
  - The sensor family has had published attacks
    ([CVE-2023-50430](https://nvd.nist.gov/vuln/detail/CVE-2023-50430)).

Report security problems as described in [SECURITY.md](SECURITY.md).

## Tests

| Layer | Runs | Command |
| --- | --- | --- |
| Unit tests (plain bash, fakes only, never touch the system) | CI and locally | `tests/run.sh` |
| shellcheck | CI | see `.github/workflows/ci.yml` |
| The fork's own test suite | CI | `meson test -C work/build --no-suite data` |
| Ubuntu's fprintd on our build, with libfprint's virtual sensor: enroll, verify match / no match, delete | CI (container) | `tests/integration/fprintd-virtual.sh` |
| Real install, verify, rollback and uninstall under systemd, with D-Bus activation | CI (privileged container) | `tests/integration/systemd-install.sh` |
| Real sensor, interactive | your laptop | `DGL_HARDWARE=1 tests/hardware.sh` |

The `data` suite is excluded because it only checks that the fork regenerated
an autosuspend hwdb data file, which it has not, and we don't install that
file.

All CI tools come from the Ubuntu archive, in [`ci/Dockerfile`](ci/Dockerfile).
The base image is pinned by digest. Dependabot proposes updates to it and to
the one GitHub action used (`actions/checkout`, pinned by commit). Nothing
merges automatically.

To run CI locally with Docker:

```bash
docker build -t dgl-ci ci/
docker run --rm -v "$PWD:/repo" -w /repo dgl-ci tests/run.sh
```

## References

- [lbssousa/libfprint](https://github.com/lbssousa/libfprint): the fork this builds (branch `goodix-538d-sigfm-gtls`)
- [ELY3M/fix-goodix-538d-fingerprint](https://github.com/ELY3M/fix-goodix-538d-fingerprint): builds the same fork, but overwrites Ubuntu's library
- [immo2n/goodix-538d-fedora-driver](https://github.com/immo2n/goodix-538d-fedora-driver): the same approach for Fedora
- [goodix-fp-linux-dev/goodix-fp-dump](https://github.com/goodix-fp-linux-dev/goodix-fp-dump): reverse engineering and reflashing tools (not recommended)
- [libfprint issue #344](https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/344) and [Launchpad bug #1879247](https://bugs.launchpad.net/ubuntu/+source/libfprint/+bug/1879247): upstream status

## License

The scripts in this repository are MIT licensed (see [LICENSE](LICENSE)).
libfprint, which they download and build, is LGPL-2.1-or-later. This
repository does not distribute it.
