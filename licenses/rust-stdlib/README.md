# Rust standard-library vendor notices

This bundle preserves exact notice files from the fourteen crate versions in
Fedora `rust-std-static-1.98.0-1.fc44`'s `cargo-vendor.txt`. Each source archive
was checked against its crates.io version metadata checksum before extracting
these files. `MANIFEST.json` records the archive hashes, metadata URLs,
declared license alternatives, and individual notice hashes. The MIT
alternative is selected for these crates; the upstream alternatives are also
retained verbatim.

`packaging/cargo_licenses.py` verifies this bundle and requires the installed
Fedora standard-library vendor list to match it. It adds these notices and the
build host's Rust project, library copyright, and Unicode notices to the RPM's
generated license directory, recording the compiler version and every file's
hash. A toolchain vendor change requires refreshing this reviewed bundle.
