# Security policy

## Reporting

Please report vulnerabilities privately through GitHub's
[security advisories](https://github.com/jvsena42/dell-goodix-538d-linux/security/advisories/new),
not in public issues. Problems in the driver itself belong upstream at
[lbssousa/libfprint](https://github.com/lbssousa/libfprint); we will help
route them.

## What this project trusts

- The Ubuntu archive, for build tools and the CI image's packages.
- One commit of [lbssousa/libfprint](https://github.com/lbssousa/libfprint),
  named by its full hash in [`PIN`](PIN). We reviewed that commit before
  pinning it. The scripts refuse any other source tree.
- `actions/checkout`, pinned by commit, in CI only.

Nothing else is downloaded: meson runs with `--wrap-mode=nodownload`, and the
fork has no subprojects or submodules.

## Changing the pin

Dependabot cannot follow the fork, so every pin update is a manual pull
request that:

1. changes only `PIN`;
2. includes `git diff --stat OLD..NEW` for the fork;
3. includes the output of these checks on the new commit, with an
   explanation for every hit:

   ```bash
   # networking, running programs, loading code. At 037912c the only hit is
   # the reviewed socketpair() in goodixtls.c that carries TLS in-process.
   grep -rnE 'socket\(|socketpair|g_socket|connect\(|getaddrinfo|system\(|popen|exec[lv]p?e?\(|posix_spawn|fork\(|g_spawn|g_subprocess|dlopen|g_module_' libfprint/drivers/goodixtls libfprint/sigfm
   # writing to the sensor's key or firmware
   grep -rnE 'psk_write|write_firmware|update_firmware|flash' libfprint/drivers/goodixtls
   # files written and environment variables read
   grep -rnE 'fopen|g_file_set_contents|getenv' libfprint/drivers/goodixtls libfprint/sigfm
   # build changes
   git diff OLD..NEW -- meson.build meson_options.txt libfprint/meson.build subprojects .gitmodules
   ```
4. passes CI, including the integration tests.

## Hardening in the scripts

- The build runs unprivileged. Root is used only for:
  - running the probe program;
  - `systemctl` calls on fprintd;
  - copying to and removing `/opt/dell-goodix-538d` and the drop-in;
  - removing the calibration file on uninstall.
- Before root runs or copies anything from the build directory, the scripts
  check that no other user can write to those files or the folders above them.
- The installed files and the systemd drop-in are root-owned and not
  group/world-writable. The library's checksum, taken on the installed copy,
  is in `/opt/dell-goodix-538d/MANIFEST`. `scripts/verify.sh` checks it, along
  with every installed file's owner, mode and ACLs, and that nothing else is in
  the install folder.
- Variables that let the tests replace commands (`SUDO`, `SYSTEMCTL`, `GIT`,
  ...) are ignored unless `DGL_TEST=1`.
- The build directory's path is compiled into the library, for libfprint's
  test-only emulation mode. Only root can enable that mode for fprintd. Delete
  `work/` after installing anyway.
