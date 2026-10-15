#!/bin/sh
# File: tools/test/md_preload/test.sh
# Created by Andrea "Nemesi" Cocito on 15/10/2026
# Run only in the disposable preload test guest described in README.md.
set -eu
export PATH=/rescue:/bin:/sbin:/usr/bin:/usr/sbin

fail() { echo "MD_PRELOAD FAIL: $*"; exit 1; }
refuse() {
    if "$@"; then fail "unexpected success: $*"; fi
}
same() {
    [ "$(md5 -q "$1")" = "$(md5 -q "$2")" ] || fail "content differs: $1 $2"
}

[ -f /md-preload-test-guest ] || fail 'missing disposable-guest marker'
mdconfig -a -t malloc -s 64k -u 2
mdconfig -a -t malloc -s 64k -u 3
trap 'sysctl debug.md_preload_test=0 >/dev/null 2>&1 || true' EXIT

# Full images are already in RAM: reads before/after holds must preserve them.
dd if=/dev/md0 of=/before0 bs=4096 status=none
dd if=/dev/md1 of=/before1 bs=4096 status=none
sysctl debug.md_preload_test=1
for stage in 1 2; do
    for unit in 0 1; do
        refuse sh -c "printf X > /dev/md$unit"
        refuse mdconfig -d -u "$unit"
        refuse mdconfig -d -o force -u "$unit"
        refuse mdconfig -r -s 128k -u "$unit"
        dd if="/dev/md$unit" of="/after$unit" bs=4096 status=none
        same "/before$unit" "/after$unit"
    done
    refuse kldunload md_preload_test
    if [ "$stage" -eq 1 ]; then sysctl debug.md_preload_test=2; fi
done
# Unborrowed devices keep their existing read/write/detach behavior.
dd if=/before0 of=/ordinary bs=512 count=1 status=none
dd if=/ordinary of=/dev/md3 bs=512 count=1 status=none
dd if=/dev/md3 of=/ordinary-read bs=512 count=1 status=none
same /ordinary /ordinary-read
mdconfig -d -u 3
sysctl debug.md_preload_test=0
# Acquire and release again; the backing allocation survives both cycles.
sysctl debug.md_preload_test=1
sysctl debug.md_preload_test=0
kldunload md_preload_test
# After the final release, the originally writable preload accepts writes again.
dd if=/before0 of=/dev/md0 bs=4096 status=none
dd if=/dev/md0 of=/after0 bs=4096 status=none
same /before0 /after0
mdconfig -d -o force -u 0
mdconfig -d -u 1
mdconfig -d -u 2
trap - EXIT
echo 'MD_PRELOAD ALL TESTS PASSED'
# END File: tools/test/md_preload/test.sh
