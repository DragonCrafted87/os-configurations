# Source RPMs

Each directory is one package. `packages.txt` is the build order.
`versions.map` names the `setup/versions.conf` key for that package.
`build.sh` reads the pin from `versions.conf` and passes it to
`rpmbuild --define`. The specs do not copy the pin.

```bash
rpms/build.sh --dry-run
rpms/build.sh
```

A build produces `rpms/out/<arch>/<name>-<version>-1.<arch>.rpm` for
`x86_64` (`-march=x86-64`, GCC, except BOINC which stays on Clang) and
`znver1` (`-march=znver1`). A second run leaves an RPM that is already
there. The install prefix is `/usr/local`.

`publish.sh` creates one Pulp RPM repository named `homelab`, uploads
`rpms/out`, and publishes it at
`https://pulp.stealthdragonland.net/pulp/content/homelab/`. dnf on either
architecture uses that one distribution. The script is not part of a
role run. Pulp has to be up first. `enable-pulp-repo` already writes the
matching dnf repo file.

Building a later package needs the earlier RPMs installed, because the
specs `Require` and `BuildRequire` the libraries they link. This
directory does not install those RPMs onto the machine.
