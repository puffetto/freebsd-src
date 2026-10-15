#!/bin/sh
# File: tools/test/md_preload/run.sh
# Created by Andrea "Nemesi" Cocito on 15/10/2026
# Build and boot an isolated QEMU guest to exercise the real md preload hooks.
set -eu
[ "$(uname -s)" = FreeBSD ] || { echo 'Requires FreeBSD' >&2; exit 1; }
[ "$#" -eq 2 ] || { echo "usage: $0 patched-kernel new-work-directory" >&2; exit 1; }
kernel=$(realpath "$1")
mkdir "$2"
work=$(realpath "$2")
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
src=$(realpath "$here/../../..")
root="$work/root"
mkdir -p "$work/module" "$root/boot/kernel" "$root/boot/defaults" \
    "$root/dev" "$root/etc" "$root/bin" "$root/sbin" "$root/rescue" "$root/tmp"
env MAKEOBJDIR="$work/module" make -C "$here" SYSDIR="$src/sys"
cp "$kernel" "$root/boot/kernel/kernel"
cp "$work/module/md_preload_test.ko" "$root/boot/kernel/"
cp /boot/loader "$root/boot/loader"
cp /boot/device.hints "$root/boot/device.hints"
cp /boot/defaults/loader.conf "$root/boot/defaults/"
cp -R /boot/lua "$root/boot/"
cp /rescue/rescue "$root/rescue/"
for name in sh init mount sysctl mdconfig dd md5 kldunload reboot sync; do
    ln "$root/rescue/rescue" "$root/rescue/$name"
done
ln "$root/rescue/rescue" "$root/bin/sh"
ln "$root/rescue/rescue" "$root/sbin/init"
cp "$here/test.sh" "$root/test.sh"
touch "$root/md-preload-test-guest"
cat > "$root/boot/loader.conf" <<'EOF'
autoboot_delay="-1"
console="comconsole"
comconsole_speed="115200"
boot_serial="YES"
vfs.root.mountfrom="ufs:/dev/ada0p2"
mdtest0_load="YES"
mdtest0_type="md_image"
mdtest0_name="/boot/mdtest0.img"
mdtest1_load="YES"
mdtest1_type="md_image"
mdtest1_name="/boot/mdtest1.img"
md_preload_test_load="YES"
EOF
cat > "$root/etc/rc" <<'EOF'
#!/rescue/sh
export PATH=/rescue
mount -u -w /
sh /test.sh
status=$?
echo "MD_PRELOAD GUEST_STATUS=$status"
sync
reboot -p
EOF
python3 - "$root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for i in range(2):
    (root / f'boot/mdtest{i}.img').write_bytes(bytes([65 + i]) * (65536 << i))
PY
makefs -t ffs -s 256m -o version=2 "$work/root.ufs" "$root"
mkimg -s gpt -b /boot/pmbr -p freebsd-boot:=/boot/gptboot \
    -p "freebsd-ufs:=$work/root.ufs" -o "$work/guest.img"
python3 - "$work" <<'PY'
from pathlib import Path
import subprocess
import sys
work = Path(sys.argv[1])
cmd = ['qemu-system-x86_64', '-accel', 'tcg', '-m', '1024', '-smp', '2',
       '-display', 'none', '-monitor', 'none', '-serial', 'stdio', '-nic', 'none',
       '-device', 'virtio-rng-pci', '-drive',
       f'file={work}/guest.img,format=raw,if=ide,snapshot=on', '-no-reboot']
with (work / 'console.log').open('w') as log:
    result = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=300)
output = (work / 'console.log').read_text(errors='replace')
assert result.returncode == 0, (result.returncode, work / 'console.log')
assert 'MD_PRELOAD ALL TESTS PASSED' in output, work / 'console.log'
assert 'MD_PRELOAD GUEST_STATUS=0' in output, work / 'console.log'
assert 'panic:' not in output and 'MD_PRELOAD FAIL' not in output
print(f'PASS: real preloaded-image hooks exercised in QEMU; log: {work}/console.log')
PY
# END File: tools/test/md_preload/run.sh
