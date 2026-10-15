# Preloaded md backing regression

The kernel-only `md_preload_hold`/`md_preload_release` API lets a GEOM consumer
borrow the original MD_PRELOAD allocation. This standalone regression runs in a
disposable guest because real MD_PRELOAD devices are created at boot, not by
`mdconfig -a`. Do not load this test module or run test.sh on a working host.

Build a patched GENERIC kernel into a separate object directory, without
installing it into the host boot tree:

```sh
env MAKEOBJDIRPREFIX=/absolute/work/obj make -j8 buildkernel \
    KERNCONF=GENERIC NO_MODULES=yes
```

Then, as an ordinary user on FreeBSD with QEMU, Python 3 and the base build tools:

```sh
sh tools/test/md_preload/run.sh /absolute/path/to/built/kernel /new/work/guest
```

The runner compiles a test consumer against this source tree, makes a small UFS
boot disk with the host's loader and static rescue tools, and boots the supplied
kernel under QEMU TCG. It never mounts host providers, needs no root privileges,
has no guest network, and runs against a QEMU disk snapshot. The work directory
must not exist and is retained for inspection; console.log contains the results.
The guest must print `MD_PRELOAD ALL TESTS PASSED` and exit with status zero.

Two images, filled with distinct bytes and of different sizes, are loaded as
`md_image`. A kernel consumer compares the returned pointers directly with the
loader's preload records and checks sizes, contents and nested hold identity.
It rejects unattached and malloc-backed consumers, insufficient access and
write access, and attempts to acquire write access on the borrowing consumer.

The userland test then verifies that reads preserve both images while writes,
ordinary/forced detach, resize, and test-module unload fail. It repeats these
checks after dropping only one of two nested holds. An unrelated malloc device
still accepts writes and detaches. After final release, another borrow cycle
succeeds, the test module unloads, writes to the originally writable preload
work again, and both preloads detach. There are no image-sized allocations in
the borrowing API or the test consumer.

These tests establish the md API behavior. They do not establish FemtoFS root
boot, its mmap page identity, or its total memory overhead; those are separate
consumer integration tests. The API is a project extension, identified by
`MD_PRELOAD_API_VERSION`, rather than an upstream FreeBSD KBI guarantee.
