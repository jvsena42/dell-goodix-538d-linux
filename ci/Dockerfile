# The one image every CI job runs in. The base image is pinned by digest
# (packages come from the archive at build time). Dependabot proposes digest
# updates as pull requests.
FROM ubuntu:26.04@sha256:f144425ff09be612d6d9ad965196e9cdc23dae1f42110a8a11a3e9a8198759f7

# Everything comes from the Ubuntu archive.
#   build:        meson ... libgirepository1.0-dev (libfprint's build needs
#                 introspection; its test setup breaks without it)
#   fork tests:   umockdev, gir1.2-umockdev-1.0, python3-gi, python3-cairo
#   checks:       shellcheck, binutils (objdump), acl (setfacl, for tests)
#   integration:  fprintd, dbus, python3-dbusmock, systemd
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates git acl \
        meson ninja-build pkgconf gcc g++ \
        libglib2.0-dev libgusb-dev libgudev-1.0-dev libpixman-1-dev libssl-dev libcairo2-dev \
        gobject-introspection libgirepository1.0-dev \
        umockdev gir1.2-umockdev-1.0 python3-gi python3-cairo \
        shellcheck binutils \
        fprintd dbus python3 python3-dbusmock systemd systemd-sysv \
    && rm -rf /var/lib/apt/lists/*
