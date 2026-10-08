#!/usr/bin/env python3
"""Generate bisect group configs for the cuttlefish fragment campaign.
RECONSTRUCTED 2026-10-08 (identical to pre-deletion version, incl. the
symbol-name normalization fix).

Delta space: every kernel-config line that differs between .config.stock
(the booting 6.6 gki_defconfig control) and .config.anvil (the committed
crashing fragment kernel), including explicit '# CONFIG_X is not set' lines.

Groups:
  base.cfg.cfg   — symbols declared by hardening/kernel/base.cfg (fragment form)
  arch.cfg       — symbols declared by arch-x86_64.cfg (fragment form)
  residue.cfg    — every other delta symbol, in .config.anvil resolved form
  initonfree.cfg — the INIT_ON_FREE axis (kept out of all other groups)

The combined set + the FIXED boot-vehicle preamble must reproduce
.config.anvil under olddefconfig (verify-groups.sh).
"""
import re, pathlib

KC = pathlib.Path("/home/potato/anvil-cf/kernel/common")
GRP = pathlib.Path("/home/potato/anvil-cf/campaign2/groups")
GRP.mkdir(parents=True, exist_ok=True)

LINE_RE = re.compile(r'^CONFIG_([A-Za-z0-9_]+)=(.*)$')
NOTSET_RE = re.compile(r'^# (CONFIG_[A-Za-z0-9_]+) is not set$')

def norm(name):
    return name[7:] if name.startswith("CONFIG_") else name

def parse(p):
    out = {}
    for ln in p.read_text(errors="replace").splitlines():
        m = LINE_RE.match(ln) or NOTSET_RE.match(ln)
        if m:
            out[norm(m.group(1))] = ln
    return out

stock = parse(KC / ".config.stock")
anvil = parse(KC / ".config.anvil")

frag = {}
for f in ("base.cfg", "arch-x86_64.cfg"):
    src = pathlib.Path("/home/potato/grafene/anvil/hardening/kernel") / f
    for ln in src.read_text().splitlines():
        m = LINE_RE.match(ln) or NOTSET_RE.match(ln)
        if m:
            frag[norm(m.group(1))] = (f, ln)

FIXED = {  # boot-vehicle preamble symbols handled by bisect-build.sh
    "VIRTIO_PCI", "VIRTIO_BLK", "VIRTIO_NET", "VIRTIO_CONSOLE",
    "HW_RANDOM_VIRTIO", "VIRTIO_VSOCKETS", "VIRTIO_VSOCKETS_COMMON",
    "VIRTIO_INPUT", "FAILOVER", "NET_FAILOVER",
    "CFG80211", "MAC80211", "MAC80211_HWSIM", "DRM_VIRTIO_GPU",
    "DRM_VIRTIO_GPU_KMS", "DRM", "INIT_ON_FREE_DEFAULT_ON",
}

delta = {}
for sym in set(stock) | set(anvil):
    if stock.get(sym) != anvil.get(sym):
        delta[sym] = (stock.get(sym), anvil.get(sym))

base_syms  = sorted(s for s in delta if s in frag and frag[s][0] == "base.cfg")
arch_syms  = sorted(s for s in delta if s in frag and frag[s][0] == "arch-x86_64.cfg")
res_syms   = sorted(s for s in delta if s not in frag and s not in FIXED)

def write(name, lines):
    (GRP / name).write_text("\n".join(lines) + "\n")
    print(f"{name}: {len(lines)} lines")

write("base.cfg.cfg", [frag[s][1] for s in base_syms])
write("arch.cfg",     [frag[s][1] for s in arch_syms])
write("residue.cfg",  [anvil.get(s) or stock[s] for s in res_syms])
write("initonfree.cfg", ["CONFIG_INIT_ON_FREE_DEFAULT_ON=y"])
write("all.cfg",      [frag[s][1] for s in base_syms] +
                      [frag[s][1] for s in arch_syms] +
                      [anvil.get(s) or stock[s] for s in res_syms])

print(f"delta symbols: {len(delta)}  base: {len(base_syms)}  arch: {len(arch_syms)}  residue: {len(res_syms)}")
