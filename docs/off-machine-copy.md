# Getting this project off the machine it lives on

There is exactly one copy of nullLinux, on `nvme0n1` in `nox`, and installing
nullLinux onto `nox` erases it. This is the note for making that stop being true.

Two halves, and they are different problems.

## 1. The source -> a private GitHub repository

234 files, 2.2 MB. Everything that is not derived.

The history was rewritten once, before the first push, to remove 87 MB of build
output that had been committed and then gitignored -- `debugdata/` from lorax
and a built RPM. The repository went from 103.23 MiB to 5.48 MiB with every
tracked file byte-for-byte unchanged (the HEAD tree hash is the same either
side: `264c2b78`). Doing that after a push would mean force-pushing over
anybody's clone; doing it before cost nothing.

```
gh repo create nulllinux --private --source=. --remote=origin --push
```

or, without the `gh` CLI: make an empty private repository on github.com, then

```
git remote add origin git@github.com:<you>/nulllinux.git
git push -u origin master
```

`master` is the branch name here, not `main`.

## 2. The HDR master -> a release asset, not the repository

`assets/master.hdrcells` is 423 MB of raytraced frames. It is the one artefact
that cannot be regenerated on a T480 -- 0.39 s a frame on a discrete GPU,
28.27 s on software Vulkan -- and it is DERIVED, so §5.7 keeps it out of git.

It compresses about ninefold:

```
/var/lib/nulllinux-iso/null-master-0.1.0.tar.gz          50.4 MB
/var/lib/nulllinux-iso/null-master-0.1.0.tar.gz.sha256
```

Attach that to a GitHub release. The per-file limit there is 2 GB, it does not
enter the repository, and it does not touch the Git LFS quota -- which at 1 GB
of storage and 1 GB of transfer a month would allow roughly one clone.

```
gh release create v0.1.0 \
   /var/lib/nulllinux-iso/null-master-0.1.0.tar.gz \
   /var/lib/nulllinux-iso/null-master-0.1.0.tar.gz.sha256 \
   --title "nullLinux 0.1.0" --notes "HDR master: 240 frames, 423 MB uncompressed."
```

## Restoring, from nothing

```
git clone git@github.com:<you>/nulllinux.git && cd nulllinux
gh release download v0.1.0
sha256sum -c null-master-0.1.0.tar.gz.sha256
tar -C assets -xzf null-master-0.1.0.tar.gz
( cd assets/master.hdrcells && sha256sum --quiet -c MANIFEST.sha256 )
bin/null-prebake                      # regenerates assets/prebuilt/, CPU only
bin/null-build                        # regenerates system/plymouth-theme/ etc.
```

`null-prebake` runs Python against the master and needs no GPU: the expensive
part is producing the master, and that is the part being restored. Everything
downstream of it re-runs in about a minute.

PROVEN, not assumed. The tarball was extracted to a scratch directory, checked
against `MANIFEST.sha256` -- all 240 frames -- and diffed against the original:
identical. A fresh `git clone` of the rewritten repository was made and run its
own checks, which passed.

## The drive still works

`bin/null-backup /run/media/<drive>` does both halves onto one removable disk:
the master, checksummed at the destination, and a verified `git bundle` of the
whole history. It refuses a destination on this machine's own disk. Use it as
well as GitHub, or instead of it when there is no network.
