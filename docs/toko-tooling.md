# toko-tooling

The source distribution of Toko Studios development tooling: scripts,
Make interfaces, CI actions, catalogs, rules, licenses and guides. Its empty
Rust library is dependency-free and `no_std`, with no build script.

The package's authoritative licence is provided in `LICENSE.md`. See
[the licensing guide](https://github.com/dragginzgame/toko-tooling/blob/main/docs/licenses.md).

Select an exact reviewed release once in repository-root Cargo.toml. The
example below uses published 0.43.2; it is not an automatic latest-version selector:

```toml
[workspace.dependencies]
toko-tooling = "=0.43.2"
```

Every real workspace package inherits the pin. A source-only marker works for
libraries and binaries, including binary tests with strict unused-dependency lints:

```toml
[target.'cfg(any())'.dev-dependencies]
toko-tooling.workspace = true

[package.metadata.cargo-machete]
ignored = ["toko-tooling"]
```

A plain `[dev-dependencies]` entry is also supported. Use one form per package.
Merge existing exemptions. A standalone package declares the exact version
in its own dev-dependencies instead. No helper packages or Rust imports are needed.
`cargo update -v` reports newer available releases; the exact pin keeps adoption
intentional. For an installed consumer, change the pin in each maintained
workspace, update its lock with `cargo update -p toko-tooling`, then run
`make toko-tooling-preview` and `make toko-tooling-update`. The shared
`make deps-update DEPENDENCY_PACKAGE=toko-tooling` target can update both the
root and independent qualification locks in one invocation when installed. Installation authenticates the crates.io
source archive against the version and checksum in Cargo.lock.

For first installation, these Make commands are not available yet. Prepare the
prerequisites and use the installer from a reviewed producer checkout or
authenticated crate extraction, following the
[initial adoption guide](https://github.com/dragginzgame/toko-tooling/blob/38a3b259453c56d9fb66e780e53957641f1e73b2/docs/adoption/consuming-snapshots.md#start-here).
Install selected executables under `vendor/toko-tooling/` and include
`vendor/toko-tooling/make/consumer.mk`. Reference guides stay upstream; the
baseline and canonical licence/contribution files retain their root locations.

`make toko-tooling-install` installs the existing Cargo.lock selection.
Offline `make toko-tooling-check` validates every member's declaration, the root
pin, Cargo.lock and installed files. Common CI/release entrypoints require it;
Cargo builds never install tools. The producer qualifies its source archive
instead of depending on itself.

Follow the [migration guide](https://github.com/dragginzgame/toko-tooling/blob/38a3b259453c56d9fb66e780e53957641f1e73b2/docs/adoption/consuming-snapshots.md#migration-from-cargo-dependencies)
to remove the 0.34–0.35 metadata tables and `toko-tooling.lock`, plus any old
selection-only packages. Real tools and qualification packages remain.
Releases before 0.33 contain only a marker; 0.36 introduces this Cargo-visible
per-package selection contract.
