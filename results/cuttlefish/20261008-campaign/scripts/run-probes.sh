#!/bin/bash
# Behavioral probes for Anvil fragment observables. Run: run-probes.sh <serial> <outdir>
SER=$1; OUT=$2; ADB="adb -s $SER"
mkdir -p "$OUT"
probe() { # probe <name> <shell-command>
  local n=$1; shift
  echo "\$ $*" > "$OUT/$n.txt"
  $ADB shell "$*" >> "$OUT/$n.txt" 2>&1
}
probe lockdown 'cat /sys/kernel/security/lockdown'
probe init_on_alloc 'cat /sys/module/page_alloc/parameters/init_on_alloc'
probe init_on_free 'cat /sys/module/page_alloc/parameters/init_on_free'
probe page_shuffle 'cat /sys/module/page_alloc/parameters/page_shuffle'
probe kfence_sample_interval 'cat /sys/module/kfence/parameters/sample_interval'
probe sysrq 'cat /proc/sys/kernel/sysrq'
probe mmap_rnd_bits 'cat /proc/sys/vm/mmap_rnd_bits'
probe mmap_rnd_compat_bits 'cat /proc/sys/vm/mmap_rnd_compat_bits'
probe mmap_min_addr 'cat /proc/sys/vm/mmap_min_addr'
probe randomize_kstack_offset 'cat /proc/sys/kernel/randomize_kstack_offset'
probe module_sig_enforce 'cat /sys/module/module/parameters/sig_enforce'
probe unprivileged_bpf_disabled 'cat /proc/sys/kernel/unprivileged_bpf_disabled'
probe selinux_enforce 'getenforce'
probe securityfs_ls 'ls /sys/kernel/security'
probe safesetid 'ls /sys/kernel/security/safesetid'
probe cpu_meltdown 'cat /sys/devices/system/cpu/vulnerabilities/meltdown'
probe cpu_spectre_v2 'cat /sys/devices/system/cpu/vulnerabilities/spectre_v2'
probe cpu_spectre_v2_user 'cat /sys/devices/system/cpu/vulnerabilities/spectre_v2_user'
probe cpu_spec_store_bypass 'cat /sys/devices/system/cpu/vulnerabilities/spec_store_bypass'
probe cpu_gather_data_sampling 'cat /sys/devices/system/cpu/vulnerabilities/gather_data_sampling'
probe cpu_reg_file_data_sampling 'cat /sys/devices/system/cpu/vulnerabilities/reg_file_data_sampling'
probe cpu_branch_history_injection 'cat /sys/devices/system/cpu/vulnerabilities/branch_history_injection'
probe cpu_retbleed 'cat /sys/devices/system/cpu/vulnerabilities/retbleed'
probe cpu_spectre_v1 'cat /sys/devices/system/cpu/vulnerabilities/spectre_v1'
probe tcp_syncookies 'cat /proc/sys/net/ipv4/tcp_syncookies'
probe devmem 'ls -l /dev/mem'
probe devport 'ls -l /dev/port'
probe binfmt_misc_fs 'cat /proc/filesystems | grep -i binfmt; echo rc=$?'
probe binfmt_misc_sysfs 'ls /proc/sys/fs/binfmt_misc'
probe tipc_protocols 'cat /proc/net/protocols | grep -i tipc; echo rc=$?'
probe memory_hotplug_sysfs 'ls /sys/devices/system/memory/'
probe power_state 'cat /sys/power/state'
probe power_disk 'cat /sys/power/disk'
probe slab_kmalloc_caches 'ls /sys/kernel/slab | grep -i kmalloc | sort | head -40'
probe slab_kmalloc_count 'ls /sys/kernel/slab | grep -ic kmalloc'
probe slab_mergeable 'cat /sys/kernel/slab/km-000/mergeable 2>/dev/null; cat /sys/kernel/slab/kmalloc-8k/mergeable 2>/dev/null; echo "(mergeable attr probe)"'
probe proc_version 'cat /proc/version'
probe uname 'uname -a'
probe cmdline 'cat /proc/cmdline'
probe sysctl_vm_overview 'cat /proc/sys/vm/mmap_rnd_bits /proc/sys/vm/mmap_rnd_compat_bits /proc/sys/vm/mmap_min_addr'
probe dmesg_as_shell 'dmesg | head -2'
probe modules_loaded 'cat /proc/modules | head -30'
echo "probes done: $(ls $OUT | wc -l) files in $OUT"
