#!/usr/bin/env python3
"""Kconfig fragment validator for Anvil kernel hardening configs.

Validates config-fragment files (CONFIG_X=y, "# CONFIG_X is not set", ...) against
the real Kconfig definitions of a pinned upstream tree (by default
GrapheneOS/kernel_common-6.6, branch 17) without cloning anything: the Kconfig
definition index is listed once via the GitHub git-trees API, then Kconfig files
are fetched lazily by walking `source` directives from the root Kconfig through
arch/{arm64,x86}/Kconfig, capped at --max-fetch Kconfig files.

Checks performed per fragment line:
  (a) the symbol exists in the tree's Kconfig definitions
  (b) the symbol has a prompt (is user-settable); promptless pins are compared
      against their computed default
  (c) `depends on` expressions are evaluated against the union of fragments
      (simple &&/||/!/() logic); `select` targets of enabled symbols are
      existence-checked and conflicts with "# CONFIG_... is not set" reported
  (d) "# CONFIG_X is not set" consistency (symbol exists and is bool/tristate)
  (e) duplicate/conflicting assignments across layers (base / arch / soc):
      conflicting values -> error, redundant identical values -> warning

Extra modes:
  --manifest FILE   validate fragments against a MANIFEST.yaml (every fragment
                    line covered; no orphan manifest rows)
  --explain SYM...  print where a symbol is defined, its prompt/deps/selects
  --summary         emit a machine-readable JSON report to stdout
  --offline         use only the on-disk cache (exit nonzero if missing)

Caching: the Kconfig tree index and file contents are cached under
.cache/kconfig/<repo>/<branch>/ (gitignored). Cached file NAMES are pure
functions of the remote path — sha256(remote_path) + ".kconfig" — so remote
data never shapes a filesystem path; the remote-path -> cache-name mapping is
kept in path_map.json. Fetch stats are printed so you can see exactly what was
resolved and what was not.

Requires: Python 3.9+ stdlib; PyYAML optional (for --manifest; a minimal
fallback parser covers the flat subset used by MANIFEST.yaml).
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import time
from collections.abc import Mapping
from dataclasses import dataclass, field

DEFAULT_REPO = "GrapheneOS/kernel_common-6.6"
DEFAULT_BRANCH = "17"
# Subtrees walked before anything else so that the fetch cap never starves the
# core/mm/security definitions that hardening symbols live in.
PRIORITY_PREFIXES = (
    "arch/", "init/", "kernel/", "mm/", "security/", "lib/", "crypto/",
    "block/", "io_uring/", "fs/", "net/", "virt/", "ipc/",
    "drivers/char/", "drivers/firmware/", "drivers/soc/", "drivers/tee/",
)
DEFERRED_PREFIXES = ("drivers/", "sound/", "samples/", "Documentation/", "tools/")

RAW_ACCEPT = "application/vnd.github.raw"

SEV_ERROR = "error"
SEV_WARN = "warn"
SEV_INFO = "info"


# --------------------------------------------------------------------------
# findings
# --------------------------------------------------------------------------

@dataclass
class Finding:
    sev: str            # error | warn | info
    code: str           # machine-readable check id, e.g. "missing-symbol"
    file: str
    line: int
    symbol: str
    message: str

    def to_dict(self) -> dict:
        return {
            "sev": self.sev, "code": self.code, "file": self.file,
            "line": self.line, "symbol": self.symbol, "message": self.message,
        }


def err(code, file, line, symbol, message) -> Finding:
    return Finding(SEV_ERROR, code, file, line, symbol, message)


def warn(code, file, line, symbol, message) -> Finding:
    return Finding(SEV_WARN, code, file, line, symbol, message)


def info(code, file, line, symbol, message) -> Finding:
    return Finding(SEV_INFO, code, file, line, symbol, message)


# --------------------------------------------------------------------------
# fragment parsing
# --------------------------------------------------------------------------

RE_CFG_SET = re.compile(r"^CONFIG_([A-Za-z0-9_]+)=(.*)$")
RE_CFG_NOT_SET = re.compile(r"^# CONFIG_([A-Za-z0-9_]+) is not set\s*$")


@dataclass
class FragmentLine:
    symbol: str
    value: str          # "y", "m", "n", or raw int/string (kept verbatim)
    not_set: bool
    file: str
    lineno: int


def layer_of(path: str) -> str:
    """Layer identity used for conflict detection.

    Layers that are never merged together get distinct keys so that, e.g.,
    arch-arm64.cfg and arch-x86_64.cfg holding different values for the same
    symbol is not a conflict — a build merges base + ONE arch + ONE soc.
    """
    base = os.path.basename(path)
    parent = os.path.basename(os.path.dirname(os.path.abspath(path)))
    m = re.fullmatch(r"arch-([A-Za-z0-9_]+)\.cfg", base)
    if base.startswith("base"):
        return "base"
    if m:
        return f"arch:{m.group(1)}"
    if parent == "soc" or base.startswith("soc-"):
        stem = base[:-4] if base.endswith(".cfg") else base
        return f"soc:{stem}"
    return "unknown:" + base


def parse_fragment(path: str):
    lines = []
    with open(path, "r", encoding="utf-8") as fh:
        for i, raw in enumerate(fh, 1):
            s = raw.strip()
            if not s or s.startswith("#") and not RE_CFG_NOT_SET.match(s):
                continue
            m = RE_CFG_NOT_SET.match(s)
            if m:
                lines.append(FragmentLine(m.group(1), "n", True, path, i))
                continue
            m = RE_CFG_SET.match(s)
            if m:
                val = m.group(2).strip()
                if val == '"n"' or val == "n":
                    lines.append(FragmentLine(m.group(1), "n", True, path, i))
                else:
                    lines.append(FragmentLine(m.group(1), val, False, path, i))
                continue
            lines.append(FragmentLine("", "", False, path, i))  # unparsable
    return lines


# --------------------------------------------------------------------------
# Kconfig expression handling (subset: &&, ||, !, parentheses, symbol names)
# --------------------------------------------------------------------------

TOKEN_RE = re.compile(r"\s*(\(|\)|!|&&|\|\||[A-Za-z0-9_]+)")


def tokenize_expr(expr: str):
    tokens, pos = [], 0
    while pos < len(expr):
        m = TOKEN_RE.match(expr, pos)
        if not m:
            # unsupported fragment (macros like $(cc-option,...), strings, =)
            return None
        tokens.append(m.group(1))
        pos = m.end()
    return tokens


@dataclass
class _Parser:
    tokens: list
    pos: int = 0
    ok: bool = True

    def peek(self):
        return self.tokens[self.pos] if self.pos < len(self.tokens) else None

    def take(self):
        t = self.peek()
        self.pos += 1
        return t


def eval_expr(expr: str, values: dict, arch_implied) -> bool | None:
    """Evaluate a Kconfig boolean expression.

    values maps symbol -> 2 (y) / 1 (m) / 0 (n). Returns None when the
    expression contains tokens this subset parser does not understand.
    """
    tokens = tokenize_expr(expr)
    if tokens is None:
        return None
    p = _Parser(tokens)

    def primary() -> bool | None:
        t = p.take()
        if t is None:
            p.ok = False
            return None
        if t == "(":
            v = lor()
            if p.take() != ")":
                p.ok = False
            return v
        if t == "!":
            v = primary()
            return None if v is None else (not v)
        if re.fullmatch(r"[A-Za-z0-9_]+", t):
            if t in ("y", "m"):
                return True
            if t == "n":
                return False
            if t in values:
                return values[t] != 0
            if arch_implied(t):
                return True
            return False
        p.ok = False
        return None

    def land() -> bool | None:
        v = primary()
        while p.peek() == "&&":
            p.take()
            r = primary()
            if v is None or r is None:
                v = None
            else:
                v = v and r
        return v

    def lor() -> bool | None:
        v = land()
        while p.peek() == "||":
            p.take()
            r = land()
            if v is None or r is None:
                v = None
            else:
                v = v or r
        return v

    res = lor()
    if not p.ok or p.peek() is not None:
        return None
    return res


def unsatisfied_clauses(expr: str, values: dict, arch_implied):
    """Return the top-level clauses of `expr` that evaluate false (or unknown)."""
    out = []
    for clause in split_top_clauses(expr):
        v = eval_expr(clause, values, arch_implied)
        if v is None:
            out.append((clause, "unparsable"))
        elif not v:
            out.append((clause, "unsatisfied"))
    return out


def split_top_clauses(expr: str):
    """Split on top-level || (depth-aware); each piece keeps its own parens."""
    parts, depth, cur, i = [], 0, "", 0
    while i < len(expr):
        if expr.startswith("||", i) and depth == 0:
            parts.append(cur.strip())
            cur = ""
            i += 2
            continue
        if expr[i] == "(":
            depth += 1
        elif expr[i] == ")":
            depth -= 1
        cur += expr[i]
        i += 1
    if cur.strip():
        parts.append(cur.strip())
    return [p for p in parts if p]


# --------------------------------------------------------------------------
# Kconfig definition database (fetched via `gh api`, cached on disk)
# --------------------------------------------------------------------------

@dataclass
class SymDef:
    name: str
    file: str
    prompts: list = field(default_factory=list)        # [(text, cond|None)]
    has_prompt: bool = False
    ptype: str = ""                                    # bool/tristate/int/string/...
    depends: list = field(default_factory=list)        # [expr, ...]
    selects: list = field(default_factory=list)        # [(sym, cond|None)]
    defaults: list = field(default_factory=list)       # [(value, cond|None)]
    defined_in: list = field(default_factory=list)     # files where defined
    choice_member: bool = False                        # defined inside a choice
    modules_opt: bool = False                          # carries `option modules`

    def merge(self, other: "SymDef"):
        self.prompts += other.prompts
        self.has_prompt = self.has_prompt or other.has_prompt
        self.depends += other.depends
        self.selects += other.selects
        self.defaults += other.defaults
        if other.file not in self.defined_in:
            self.defined_in.append(other.file)


class KconfigDB:
    """Lazy, cache-backed Kconfig definition store for a pinned repo/branch."""

    def __init__(self, repo: str, branch: str, cache_dir: str, max_fetch: int = 700,
                 offline: bool = False, verbose: bool = True):
        self.repo = repo
        self.branch = branch
        self.cache = os.path.join(cache_dir, repo.replace("/", "__"), branch)
        self.max_fetch = max_fetch
        self.offline = offline
        self.verbose = verbose
        self.fetch_count = 0
        self.fetch_cap_hit = False
        self.index: dict[str, str] = {}     # kconfig path -> blob sha
        self.index_truncated = False
        self.head_sha = ""
        self.symbols: dict[str, SymDef] = {}
        self.files_parsed: list[str] = []
        self.path_map: dict[str, str] = {}   # remote path -> hashed cache name
        self._file_cache: dict[str, str] = {}
        self._pending: list[str] = []
        self._queued: set[str] = set()

    # ---------------- transport ----------------

    def _log(self, msg: str):
        if self.verbose:
            print(msg, file=sys.stderr)

    class CapExceeded(Exception):
        pass

    def gh_api(self, api_path: str, raw: bool = False, timeout: int = 180) -> bytes | None:
        cmd = ["gh", "api", api_path]
        if raw:
            cmd += ["-H", f"Accept: {RAW_ACCEPT}"]
        last = b""
        for attempt in range(3):
            proc = subprocess.run(cmd, capture_output=True, timeout=timeout)
            if proc.returncode == 0:
                self.fetch_count += 1
                if self.fetch_count > self.max_fetch:
                    raise KconfigDB.CapExceeded(
                        f"fetch cap (--max-fetch={self.max_fetch}) exceeded")
                return proc.stdout
            last = proc.stderr or proc.stdout
            if b"404" in last or b"Not Found" in last:
                self.fetch_count += 1  # a clean miss still consumed a request
                return None
            wait = 2 ** attempt
            self._log(f"gh api retry in {wait}s: {api_path} ({last[:120]!r})")
            time.sleep(wait)
        raise RuntimeError(f"gh api failed: {api_path}: {last[:400]!r}")

    # ---------------- cache ----------------

    @staticmethod
    def sanitize_rel(rel: str) -> str:
        """Make a remote-supplied path safe to join under the cache root.

        Rejects absolute paths, drive letters and any '..' component; drops
        empty and '.' components. Kconfig source paths never legitimately
        contain any of these, but they arrive from fetched content and must
        never be able to escape the cache directory.
        """
        if not rel or not rel.strip():
            raise ValueError("empty path rejected")
        rel = rel.replace("\\", "/")
        if rel.startswith("/") or re.match(r"^[A-Za-z]:", rel):
            raise ValueError(f"absolute path rejected: {rel!r}")
        parts = []
        for part in rel.split("/"):
            if part in ("", "."):
                continue
            if part == "..":
                raise ValueError(f"path traversal rejected: {rel!r}")
            parts.append(part)
        if not parts:
            raise ValueError(f"empty path rejected: {rel!r}")
        return "/".join(parts)

    def meta_path(self) -> str:
        return os.path.join(self.cache, "meta.json")

    def path_map_path(self) -> str:
        return os.path.join(self.cache, "path_map.json")

    def _hash_name(self, rel: str) -> str:
        """Cache filename as a pure function of the remote path.

        The cache name is sha256(remote_path) + fixed extension: no remote
        path component ever forms part of a filesystem path, so a hostile
        `source` directive cannot influence where bytes are written.
        """
        rel = self.sanitize_rel(rel)
        return hashlib.sha256(rel.encode("utf-8")).hexdigest() + ".kconfig"

    def file_path(self, rel: str) -> str:
        return os.path.join(self.cache, "files", self._hash_name(rel))

    def load_cache(self) -> bool:
        meta_f = self.meta_path()
        index_f = os.path.join(self.cache, "tree_index.json")
        if not (os.path.exists(meta_f) and os.path.exists(index_f)):
            return False
        with open(meta_f) as fh:
            meta = json.load(fh)
        if meta.get("repo") != self.repo or meta.get("branch") != self.branch:
            return False
        self.head_sha = meta.get("head_sha", "")
        with open(index_f) as fh:
            self.index = json.load(fh)
        self.index_truncated = meta.get("index_truncated", False)
        pm = self.path_map_path()
        if os.path.exists(pm):
            with open(pm) as fh:
                self.path_map = json.load(fh)
        return True

    def _migrate_legacy_layout(self):
        """One-time: cache files written under nested remote paths are moved
        to hashed names and a path_map is built from them."""
        legacy_root = os.path.join(self.cache, "files")
        if not os.path.isdir(legacy_root):
            return
        hashed_re = re.compile(r"^[0-9a-f]{64}\.kconfig$")
        for dirpath, _dirs, files in os.walk(legacy_root):
            for fn in files:
                if hashed_re.match(fn):
                    continue
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, legacy_root)
                name = self._hash_name(rel)
                target = os.path.join(self.cache, "files", name)
                if not os.path.exists(target):
                    os.replace(full, target)
                self.path_map[rel] = name
        # prune now-empty legacy directories
        for dirpath, dirs, files in os.walk(legacy_root, topdown=False):
            if dirpath == legacy_root:
                continue
            if not dirs and not files:
                os.rmdir(dirpath)
        self.save_path_map()

    def _write_cache_file(self, target: str, text: str) -> None:
        """Write text to a path inside the cache root, or refuse.

        Single choke point for every cache write: the resolved path must
        stay within the real cache root, so neither remote-derived names
        nor symlinked cache members can move bytes outside the cache.
        """
        root = os.path.realpath(self.cache)
        resolved = os.path.realpath(target)
        if resolved != root and not resolved.startswith(root + os.sep):
            raise ValueError(f"cache path escapes cache root: {target!r}")
        pathlib.Path(resolved).write_text(text)

    def save_path_map(self):
        self._write_cache_file(
            self.path_map_path(), json.dumps(self.path_map))

    def save_meta(self):
        os.makedirs(self.cache, exist_ok=True)
        self._write_cache_file(self.meta_path(), json.dumps({
            "repo": self.repo, "branch": self.branch,
            "head_sha": self.head_sha,
            "index_truncated": self.index_truncated,
            "built_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "fetched": self.fetch_count,
        }, indent=1))

    def _bulk_fetch_snapshot(self) -> bool:
        """Fetch the pinned tree as one shallow git snapshot and extract every
        Kconfig file into the hashed cache.

        A kernel tree holds >1000 Kconfig files; fetching them one-by-one
        through the contents API cannot fit inside the Actions installation
        token's 1000 req/hour budget, so a cold CI cache could never complete
        a warm run. A single-sha shallow fetch moves the whole snapshot over
        the git protocol in one pack (no API rate limits), pinned to the
        exact commit. Returns False on any failure so callers fall back to
        the per-file API walk.
        """
        # repo and ref reach the remote URL and fetch target from argv;
        # constrain both to strict allowlists before any subprocess runs.
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", self.repo):
            raise SystemExit(f"invalid repository slug: {self.repo!r}")
        if (".." in self.branch
                or not re.fullmatch(r"[A-Za-z0-9._][A-Za-z0-9._/-]{0,119}", self.branch)):
            raise SystemExit(f"invalid ref: {self.branch!r}")
        remote = f"https://github.com/{self.repo}.git"

        import shutil
        import subprocess
        import tempfile

        def _git(*args: str, timeout: int = 600) -> bool:
            proc = subprocess.run(  # noqa: S603
                ["git", *args], capture_output=True, text=True, timeout=timeout)
            return proc.returncode == 0

        tmp = tempfile.mkdtemp(prefix="kconfig-snapshot-")
        try:
            self._log(f"[fetch] shallow snapshot of {remote}@{self.branch[:12]} ...")
            if not (_git("init", "-q", tmp)
                    and _git("-C", tmp, "remote", "add", "origin", remote)
                    and _git("-C", tmp, "fetch", "-q", "--depth", "1",
                             "origin", self.branch, timeout=900)
                    and _git("-C", tmp, "checkout", "-q", "FETCH_HEAD")):
                self._log("[warn] snapshot fetch failed; falling back to per-file API")
                return False
            fetched = 0
            kc_re = re.compile(r"Kconfig[A-Za-z0-9._-]*$")
            for dirpath, _dirs, files in os.walk(tmp):
                for fn in files:
                    if not kc_re.search(fn):
                        continue
                    full = os.path.join(dirpath, fn)
                    rel = self.sanitize_rel(os.path.relpath(full, tmp))
                    with open(full, encoding="utf-8", errors="replace") as fh:
                        text = fh.read()
                    disk = self.file_path(rel)
                    os.makedirs(os.path.dirname(disk), exist_ok=True)
                    self._write_cache_file(disk, text)
                    self.index[rel] = ""  # blob sha not needed for validation
                    self.path_map[rel] = os.path.basename(disk)
                    fetched += 1
        except (OSError, subprocess.SubprocessError) as exc:
            self._log(f"[warn] snapshot fetch failed ({exc}); falling back")
            return False
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        if fetched == 0:
            self._log("[warn] snapshot held no Kconfig files; falling back")
            return False
        if re.fullmatch(r"[0-9a-f]{40}", self.branch):
            self.head_sha = self.branch
        self.fetch_count += 1  # one transport-level fetch
        self._log(f"[fetch] snapshot extracted {fetched} Kconfig files into cache")
        return True

    def ensure_index(self):
        if self.index:
            return
        if self.load_cache():
            if not self.path_map:
                self._migrate_legacy_layout()
            self._log(f"[cache] index for {self.repo}@{self.branch}: "
                      f"{len(self.index)} Kconfig files, head {self.head_sha or '?'}")
            return
        if self.offline:
            raise SystemExit(f"error: --offline and cache missing under {self.cache}")
        if self._bulk_fetch_snapshot():
            self.save_meta()
            self._write_cache_file(
                os.path.join(self.cache, "tree_index.json"), json.dumps(self.index))
            self._log(f"[fetch] index done (snapshot): {len(self.index)} Kconfig paths, "
                      f"head {self.head_sha[:12] or '?'}")
            return
        self._log(f"[fetch] git tree index for {self.repo}@{self.branch} ...")
        data = self.gh_api(
            f"repos/{self.repo}/git/trees/{self.branch}?recursive=1")
        tree = json.loads(data)
        self.index_truncated = bool(tree.get("truncated"))
        for entry in tree.get("tree", []):
            p = entry.get("path", "")
            if entry.get("type") == "blob" and re.search(
                    r"(^|/)Kconfig[A-Za-z0-9._-]*$", p):
                self.index[p] = entry.get("sha", "")
        if self.index_truncated:
            self._log(f"[warn] tree listing truncated by GitHub; index holds "
                      f"{len(self.index)} Kconfig paths (walk still works via sources)")
        # pin head sha for provenance reporting
        if re.fullmatch(r"[0-9a-f]{40}", self.branch):
            # --branch given as a pinned commit SHA: fetches already target
            # that exact tree, so the pin IS the head; no branch lookup.
            self.head_sha = self.branch
        else:
            try:
                branch = json.loads(self.gh_api(f"repos/{self.repo}/branches/{self.branch}"))
                self.head_sha = branch["commit"]["sha"]
            except Exception as exc:  # head sha is advisory only
                self._log(f"[warn] could not pin head sha: {exc}")
        self.save_meta()
        self._write_cache_file(
            os.path.join(self.cache, "tree_index.json"), json.dumps(self.index))
        self._log(f"[fetch] index done: {len(self.index)} Kconfig paths, "
                  f"head {self.head_sha[:12] or '?'}")

    # ---------------- file access ----------------

    def fetch_file(self, rel: str) -> str | None:
        if rel in self._file_cache:
            return self._file_cache[rel]
        disk = self.file_path(rel)
        if os.path.exists(disk):
            with open(disk, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            self._file_cache[rel] = text
            return text
        if rel not in self.index and (self.offline or not self.index_truncated):
            return None  # not a Kconfig path in the tree (index complete)
        if self.offline:
            return None  # in index but never fetched and offline
        data = self.gh_api(
            f"repos/{self.repo}/contents/{rel}?ref={self.branch}", raw=True)
        if data is None:
            # 404: source directive pointed at a file the index missed listing
            self.index[rel] = ""
            return None
        text = data.decode("utf-8", errors="replace")
        os.makedirs(os.path.dirname(disk), exist_ok=True)
        self._write_cache_file(disk, text)
        self.index[rel] = self.index.get(rel, "")
        self.path_map[rel] = os.path.basename(disk)
        self._file_cache[rel] = text
        return text

    # ---------------- source walking ----------------

    @staticmethod
    def _substitute(path: str, arches) -> list[str]:
        path = path.strip().strip('"')
        path = re.sub(r'^\$\{?srctree\}?/', "", path)
        path = path.replace("$(srctree)/", "")
        if "$(SRCARCH)" in path or "${SRCARCH}" in path:
            out = []
            for a in arches:
                out.append(path.replace("$(SRCARCH)", a).replace("${SRCARCH}", a))
            return out
        return [path]

    def queue(self, rel: str):
        if rel in self._queued:
            return
        try:
            rel = self.sanitize_rel(rel)
        except ValueError as exc:
            self._log(f"[warn] skipping suspicious source path: {exc}")
            return
        # Offline: only files already in the index or already cached. Online:
        # trust `source` directives even for paths the (possibly truncated)
        # index missed; 404s are clean misses.
        if self.offline and rel not in self.index and rel not in self.path_map:
            return
        self._queued.add(rel)
        self._pending.append(rel)

    def _pop_pending(self) -> str | None:
        for i, p in enumerate(self._pending):
            if p.startswith(PRIORITY_PREFIXES) or not p.startswith(DEFERRED_PREFIXES):
                return self._pending.pop(i)
        if self._pending:
            return self._pending.pop(0)
        return None

    def walk(self, arches=("arm64", "x86"), entry_points=None):
        """BFS over `source` directives; priority subtrees first, cap enforced.

        Entry points cover the root Kconfig (subsystem definitions) and the
        per-arch Kconfigs, which this tree's root file does not `source`
        itself (the kbuild entry for GKI is arch/$(SRCARCH)/Kconfig). Only
        the arch Kconfigs for the requested arches enter the walk, so
        same-name symbols (e.g. COMPAT) are not merged across arches unless
        --arch both is used.
        """
        if entry_points is None:
            entry_points = ["Kconfig"]
            if "arm64" in arches:
                entry_points.append("arch/arm64/Kconfig")
            if "x86" in arches:
                entry_points.append("arch/x86/Kconfig")
        self.ensure_index()
        for ep in entry_points:
            self.queue(ep)
        while self._pending:
            if self.fetch_count >= self.max_fetch:
                self.fetch_cap_hit = True
                break
            rel = self._pop_pending()
            try:
                text = self.fetch_file(rel)
            except KconfigDB.CapExceeded:
                self.fetch_cap_hit = True
                break
            if text is None:
                continue
            self.files_parsed.append(rel)
            self.parse_kconfig(rel, text, arches)
        if self.fetch_count:
            self.save_path_map()

    # ---------------- Kconfig subset parsing ----------------

    RE_SOURCE = re.compile(r'^\s*source\s+"?([^"\s]+)"?\s*(?:if\s+(.*))?$')
    RE_CONFIG = re.compile(r"^\s*(?:config|menuconfig)\s+([A-Za-z0-9_]+)\s*$")
    RE_TYPE = re.compile(r'^\s*(bool|tristate|string|int|hex)\s*(?:"([^"]*)")?\s*(?:if\s+(.+))?\s*$')
    RE_DEF_TYPE = re.compile(r"^\s*(def_bool|def_tristate)\s+(.+?)\s*$")
    RE_PROMPT = re.compile(r'^\s*prompt\s+"([^"]*)"\s*(?:if\s+(.+))?\s*$')
    RE_DEPENDS = re.compile(r"^\s*depends\s+on\s+(.+?)\s*$")
    RE_SELECT = re.compile(r"^\s*select\s+([A-Za-z0-9_]+)\s*(?:if\s+(.+))?\s*$")
    RE_DEFAULT = re.compile(r"^\s*default\s+(.+?)\s*$")

    def parse_kconfig(self, rel: str, text: str, arches):
        current: SymDef | None = None
        if_stack: list[str] = []
        help_indent: int | None = None
        # join backslash line-continuations so multi-line expressions arrive
        # as one logical line (Kconfig `depends on A || \n\t B` etc.)
        logical: list[str] = []
        for raw in text.splitlines():
            if raw.endswith("\\"):
                logical.append(raw[:-1] + " ")
                continue
            logical.append(raw)
            line = "".join(logical)
            logical = []
            stripped = line.strip()
            indent = len(line) - len(line.lstrip())
            if help_indent is not None:
                if not stripped:
                    continue
                if indent > help_indent:
                    continue  # still inside the help block
                help_indent = None  # dedented: help block ended
            if not stripped or stripped.startswith("#"):
                # full-line comment (not a trailing one)
                continue
            if stripped == "help" or stripped.startswith("help\t") or \
                    stripped.startswith("help "):
                help_indent = indent
                continue
            if re.match(r"^\s*if\s+\S", line):
                if_stack.append(re.sub(r"^\s*if\s+", "", line).strip())
                continue
            if re.match(r"^\s*endif\b", line):
                if_stack and if_stack.pop()
                continue
            if re.match(r"^\s*end(if|menu|choice)\b", line) or re.match(
                    r"^\s*(menu|choice)\b", line):
                if stripped.startswith("choice"):
                    # treat choice like an if-block: contents gated on its prompt;
                    # also close any open symbol so choice-internal prompts and
                    # defaults do not attach to the previous config
                    current = None
                    if_stack.append("CHOICE")
                elif stripped.startswith("endchoice"):
                    if_stack and if_stack.pop()
                elif stripped.startswith("menu"):
                    current = None
                continue
            m = self.RE_CONFIG.match(line)
            if m:
                name = m.group(1)
                if name in self.symbols:
                    current = self.symbols[name]
                    current.merge(SymDef(name=name, file=rel))
                else:
                    current = SymDef(name=name, file=rel, defined_in=[rel])
                    self.symbols[name] = current
                if "CHOICE" in if_stack:
                    current.choice_member = True
                for cond in if_stack:
                    if cond != "CHOICE":
                        current.depends.append(cond)
                continue
            m2 = self.RE_SOURCE.match(line)
            if m2:
                # `source` directives are file-level and can appear after
                # config blocks; handle them regardless of parse state
                for p in self._substitute(m2.group(1), arches):
                    if "*" in p or "?" in p:
                        for cand in fnmatch.filter(self.index, p):
                            self.queue(cand)
                    else:
                        self.queue(p)
                continue
            if current is None:
                continue
            m = self.RE_TYPE.match(line)
            if m:
                current.ptype = current.ptype or m.group(1)
                if m.group(2):
                    current.prompts.append((m.group(2), m.group(3)))
                    current.has_prompt = True
                continue
            m = self.RE_DEF_TYPE.match(line)
            if m:
                current.ptype = current.ptype or m.group(1).replace("def_", "")
                current.defaults.append((m.group(2).strip(), None))
                continue
            m = self.RE_PROMPT.match(line)
            if m:
                current.prompts.append((m.group(1), m.group(2)))
                current.has_prompt = True
                continue
            m = self.RE_DEPENDS.match(line)
            if m:
                current.depends.append(m.group(1))
                continue
            m = self.RE_SELECT.match(line)
            if m:
                current.selects.append((m.group(1), m.group(2)))
                continue
            if re.fullmatch(r"(option\s+)?modules", stripped):
                # `option modules` / bare `modules`: this is THE modules
                # symbol; kconfig defaults it to y
                current.modules_opt = True
                continue
            m = self.RE_DEFAULT.match(line)
            if m:
                current.defaults.append((m.group(1).strip(), None))
                continue


# --------------------------------------------------------------------------
# checking
# --------------------------------------------------------------------------

ARCH_SYMBOL_HINTS = ("ARM64_", "X86_", "ARCH_", "64BIT", "MMU", "EXPERT",
                     "CPU_", "HAVE_", "MODULES", "CC_", "AS_", "LD_", "GCC_",
                     "CLANG_", "RUSTC_", "TOOLS_SUPPORT", "STRICT_KERNEL_RWX")


class _EffectiveView(Mapping):
    """Lazy Mapping view: fragments first, then select-forced symbols, then
    Checker.effective_value (Kconfig defaults / selection-managed symbols)."""

    def __init__(self, checker: "Checker", vals: dict, forced: dict | None = None):
        self._checker = checker
        self._vals = vals
        self._forced = forced or {}

    def __getitem__(self, key):
        if key in self._vals:
            return self._vals[key]
        if key in self._forced:
            return 2  # select forces y regardless of dependencies
        return self._checker.effective_value(key, self._vals)

    def __contains__(self, key):
        return True  # every symbol resolves (to 0 if unknown/off)

    def __iter__(self):
        return iter(self._vals)

    def __len__(self):
        return len(self._vals)


@dataclass
class Checker:
    db: KconfigDB
    arches: tuple
    findings: list = field(default_factory=list)
    _effective_cache: dict = field(default_factory=dict)
    _forced: dict = field(default_factory=dict)

    def value_map(self, lines):
        vals = {}
        for ln in lines:
            if ln.symbol == "":
                continue
            v = ln.value
            num = 2 if v == "y" else (1 if v == "m" else 0)
            vals[ln.symbol] = max(vals.get(ln.symbol, 0), num)
        return vals

    def effective_value(self, sym: str, vals: dict) -> int:
        """Approximate olddefconfig for dependency evaluation.

        Fragment assignments win. Everything else falls back to, in order:
        a literal unconditional default in the Kconfig (`default y`,
        `def_bool y`, ...), then — for promptless symbols only — an
        assumption of 'on' (promptless symbols are driven by `select` and
        implementation defaults, not by fragment authors). Prompt symbols
        with no resolvable default stay off, which is what a fragment-only
        merge would produce.
        """
        if sym in vals:
            return vals[sym]
        if sym in self._effective_cache:
            return self._effective_cache[sym]
        d = self.db.symbols.get(sym)
        result = 0
        if d is not None:
            if d.modules_opt:
                self._effective_cache[sym] = 2
                return 2
            for value, _cond in d.defaults:
                v = value.strip()
                if re.fullmatch(r"[ynm]", v):
                    result = {"y": 2, "m": 1, "n": 0}[v]
                    break
            else:
                if not d.has_prompt or d.choice_member:
                    # promptless symbols are selection-managed; choice members
                    # are decided by the choice machinery — neither is
                    # something a fragment author controls
                    result = 2
        self._effective_cache[sym] = result
        return result

    def arch_implied(self, sym: str) -> bool:
        return any(sym.startswith(h) for h in ARCH_SYMBOL_HINTS)

    def eval_values(self, vals: dict) -> dict:
        """Context for expression evaluation: fragments + select-forced +
        effective defaults (see _EffectiveView)."""
        return _EffectiveView(self, vals, self._forced)

    def compute_forced(self, vals: dict) -> dict:
        """Symbols force-enabled via `select` from fragment-enabled symbols."""
        forced = {}
        for sym, num in vals.items():
            if num == 0:
                continue
            d = self.db.symbols.get(sym)
            if d is None:
                continue
            for target, cond in d.selects:
                if cond is None:
                    forced.setdefault(target, sym)
                    continue
                cv = eval_expr(cond, _EffectiveView(self, vals, forced),
                               self.arch_implied)
                if cv:
                    forced.setdefault(target, sym)
        return forced

    def combined_depends(self, sym: SymDef) -> str:
        return " && ".join(f"({d})" for d in sym.depends) if sym.depends else ""

    def check_fragments(self, fragments: dict[str, list[FragmentLine]]):
        all_lines = [ln for lns in fragments.values() for ln in lns]
        vals = self.value_map(all_lines)
        self._forced = self.compute_forced(vals)
        where = {}
        for path, lns in fragments.items():
            for ln in lns:
                where.setdefault(ln.symbol, []).append(ln)

        for sym_name, lns in sorted(where.items()):
            for ln in lns:
                self._check_line(sym_name, ln, vals)
        self._check_cross_layer(where)
        return self.findings

    def _check_line(self, sym_name: str, ln: FragmentLine, vals: dict):
        f, no = ln.file, ln.lineno
        if ln.symbol == "":
            self.findings.append(err("unparsable-line", f, no, "",
                                     "line does not look like a config assignment"))
            return
        d = self.db.symbols.get(sym_name)
        if d is None:
            if self.db.fetch_cap_hit:
                self.findings.append(warn(
                    "symbol-unresolved", f, no, sym_name,
                    "symbol not found in the Kconfig files fetched so far and the "
                    "fetch cap was hit; increase --max-fetch or warm the cache "
                    "online to resolve"))
            else:
                self.findings.append(err(
                    "missing-symbol", f, no, sym_name,
                    "symbol does not exist in Kconfig definitions walked from the "
                    "root Kconfig of "
                    f"{self.db.repo}@{self.db.branch} (head {self.db.head_sha[:12] or '?'})"))
            return

        if ln.not_set:
            if d.ptype not in ("bool", "tristate") and d.ptype:
                self.findings.append(err(
                    "not-set-on-non-bool", f, no, sym_name,
                    f"'# ... is not set' used on a {d.ptype} symbol; only "
                    "bool/tristate can be unset"))
            elif d.has_prompt is False and not d.selects and not d.depends:
                self.findings.append(info(
                    "not-set-promptless", f, no, sym_name,
                    "symbol has no prompt; it is already off unless selected"))
            return

        if ln.value == "m" and d.ptype == "bool":
            self.findings.append(err("m-on-bool", f, no, sym_name,
                                     "tristate value m assigned to a bool symbol"))

        # (b) prompt / default sanity
        if not d.has_prompt:
            computed = self._promptless_default(d, vals)
            if computed is not None and computed != ln.value:
                self.findings.append(warn(
                    "promptless-mismatch", f, no, sym_name,
                    f"symbol has no prompt (default resolves to {computed!r}); "
                    f"fragment pins {ln.value!r} which will not stick via "
                    "merge_config scripts"))
            else:
                self.findings.append(info(
                    "promptless-pinned", f, no, sym_name,
                    "symbol has no prompt (value comes from defaults/selection); "
                    "pin matches the computed default" if computed == ln.value
                    else "symbol has no prompt"))

        # (c) depends on
        dep = self.combined_depends(d)
        if dep:
            view = self.eval_values(vals)
            for clause, why in unsatisfied_clauses(dep, view, self.arch_implied):
                if why == "unparsable":
                    self.findings.append(info(
                        "dep-unparsed", f, no, sym_name,
                        f"cannot parse dependency clause '{clause}' with the "
                        "subset expression parser; not verified"))
                else:
                    self.findings.append(warn(
                        "unsatisfied-dep", f, no, sym_name,
                        f"dependency clause not satisfied by union of fragments: "
                        f"'{clause}' (full: depends on {dep})"))

        # (c) selects of enabled symbols
        for target, cond in d.selects:
            td = self.db.symbols.get(target)
            if td is None:
                if not self.db.fetch_cap_hit:
                    self.findings.append(warn(
                        "select-target-missing", f, no, sym_name,
                        f"selects {target}, which was not found in the walked "
                        "Kconfig definitions"))
                continue
            if cond is not None:
                cv = eval_expr(cond, self.eval_values(vals), self.arch_implied)
                if cv is False:
                    continue  # select condition not active
            if vals.get(target, 0) == 0:
                self.findings.append(info(
                    "select-forces-on", f, no, sym_name,
                    f"selects {target}; it will be forced on regardless of "
                    "fragments"))

    def _promptless_default(self, d: SymDef, vals: dict):
        """Compute the default of a promptless symbol when it is literal."""
        for value, _cond in d.defaults:
            v = value.strip()
            if re.fullmatch(r"[ynm]", v):
                return v
            if re.fullmatch(r'"[^"]*"', v):
                return v
        return None

    def _check_cross_layer(self, where: dict):
        for sym, lns in where.items():
            seen = {}
            for ln in lns:
                lay = layer_of(ln.file)
                key = ("n", None) if ln.not_set else ("set", ln.value)
                if lay in seen:
                    if seen[lay][2] != key:
                        self.findings.append(err(
                            "dup-conflict-same-layer", ln.file, ln.lineno, sym,
                            f"symbol assigned twice within layer '{lay}' with "
                            f"different values ({seen[lay][2]} vs {key})"))
                seen[lay] = (ln.file, ln.lineno, key)
            if len(seen) > 1:
                keys = {lay: k for lay, (_, _, k) in seen.items()}
                distinct = {k for k in keys.values()}
                if len(distinct) > 1:
                    kinds = {lay.split(":")[0] for lay in keys}
                    first = list(seen.items())
                    if len(kinds) < len(keys):
                        # e.g. arch:arm64 vs arch:x86_64 or soc:a vs soc:b —
                        # layers of the same kind are mutually exclusive in a
                        # merge, so different values are expected, not a conflict
                        self.findings.append(info(
                            "cross-layer-variant", first[0][1][0], first[0][1][1],
                            sym,
                            "values differ between mutually exclusive layers "
                            "(only one is merged per build): " + ", ".join(
                                f"{lay}={k[1] if k[0] == 'set' else 'n'}"
                                for lay, k in keys.items())))
                    else:
                        self.findings.append(err(
                            "cross-layer-conflict", first[0][1][0],
                            first[0][1][1], sym,
                            "conflicting assignments across layers that merge "
                            "together: " + ", ".join(
                                f"{lay}={k[1] if k[0] == 'set' else 'n'}"
                                for lay, k in keys.items())))
                else:
                    first = list(seen.items())
                    self.findings.append(warn(
                        "cross-layer-duplicate", first[0][1][0], first[0][1][1],
                        sym,
                        f"same value ({first[0][1][2][1] if first[0][1][2][0] == 'set' else 'n'}) "
                        f"redundantly assigned in layers: {', '.join(keys)}"))


# --------------------------------------------------------------------------
# manifest handling
# --------------------------------------------------------------------------

def load_manifest(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    try:
        import yaml  # type: ignore
        data = yaml.safe_load(text)
    except ImportError:
        data = _mini_yaml(text)
        for sym, body in (data or {}).items():
            if isinstance(body, dict) and isinstance(body.get("value"), (dict, list)):
                raise SystemExit(
                    f"manifest: row {sym!r} uses a nested per-arch value mapping "
                    "that the flat fallback parser cannot read; install PyYAML "
                    "(pip install pyyaml) to validate this manifest")
    rows = {}
    for sym, body in (data or {}).items():
        if sym == "meta" and isinstance(body, dict):
            continue
        if not isinstance(body, dict):
            raise SystemExit(f"manifest: row {sym!r} must be a mapping")
        value = body.get("value")
        if isinstance(value, dict):
            value = {str(k): str(v) for k, v in value.items()}
        else:
            value = str(value)
        rows[sym] = {
            "value": value,
            "provenance": str(body.get("provenance", "")),
            "portability_class": str(body.get("portability_class", "")),
        }
    return rows


def _mini_yaml(text: str):
    """Tiny fallback parser for the flat mapping-of-mappings MANIFEST subset."""
    rows, cur, in_rows = {}, None, False
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        m = re.match(r"^([A-Za-z0-9_]+):\s*$", raw.rstrip())
        if m:
            cur, in_rows = m.group(1), True
            rows[cur] = {}
            continue
        m = re.match(r"^  ([a-z_]+):\s*(.*)$", raw.rstrip())
        if m and cur:
            rows[cur][m.group(1)] = m.group(2).strip().strip('"')
    return rows


def manifest_expected_value(row: dict, layer: str) -> str | None:
    """Resolve a manifest row's value for a fragment's layer.

    A scalar value applies to every layer; a mapping selects by variant key
    (e.g. arch:arm64 -> "arm64") for symbols whose value legitimately differs
    between mutually exclusive layers.
    """
    value = row["value"]
    if not isinstance(value, dict):
        return value
    if layer.startswith("arch:") or layer.startswith("soc:"):
        variant = layer.split(":", 1)[1]
        if variant in value:
            return value[variant]
    for key in (layer, layer.split(":")[0]):
        if key in value:
            return value[key]
    return None


def check_manifest(fragments, rows: dict):
    findings = []
    frag_syms = {}
    for path, lns in fragments.items():
        for ln in lns:
            if ln.symbol:
                frag_syms.setdefault(ln.symbol, []).append(ln)
    for sym, lns in sorted(frag_syms.items()):
        if sym not in rows:
            findings.append(err("manifest-missing-row", lns[0].file,
                                lns[0].lineno, sym,
                                "fragment line not covered by MANIFEST.yaml"))
            continue
        row = rows[sym]
        for ln in lns:
            want = "n" if ln.not_set else ln.value
            expected = manifest_expected_value(row, layer_of(ln.file))
            if expected is None:
                findings.append(err("manifest-no-value-for-layer", ln.file,
                                    ln.lineno, sym,
                                    f"manifest row has no value for layer "
                                    f"'{layer_of(ln.file)}'"))
            elif expected != want:
                findings.append(err("manifest-value-mismatch", ln.file,
                                    ln.lineno, sym,
                                    f"manifest says value={expected!r} for this "
                                    f"layer, fragment has {want!r}"))
        if not row["provenance"]:
            findings.append(err("manifest-no-provenance", lns[0].file,
                                lns[0].lineno, sym, "manifest row lacks provenance"))
        if row["portability_class"] not in ("universal", "arch", "soc-gated"):
            findings.append(err("manifest-bad-class", lns[0].file, lns[0].lineno,
                                sym, "portability_class must be universal|arch|soc-gated"))
    claimed = set(frag_syms)
    for sym in sorted(rows):
        if sym not in claimed:
            findings.append(err("manifest-orphan-row", "MANIFEST.yaml", 0, sym,
                                "manifest row not claimed by any fragment line"))
    return findings


# --------------------------------------------------------------------------
# explain / summary
# --------------------------------------------------------------------------

def explain(db: KconfigDB, sym: str) -> str:
    d = db.symbols.get(sym)
    if d is None:
        return f"{sym}: NOT FOUND (walked {len(db.files_parsed)} Kconfig files)"
    out = [f"{sym}  [{d.ptype or '?'}]  defined in {', '.join(d.defined_in[:4])}"]
    for text, cond in d.prompts[:3]:
        out.append(f"  prompt: \"{text}\"" + (f"  if {cond}" if cond else ""))
    if not d.has_prompt:
        out.append("  prompt: (none — not user-settable)")
    for v, _cond in d.defaults[:4]:
        out.append(f"  default: {v}")
    if not d.defaults and not d.has_prompt:
        out.append("  default: (none — n unless selected)")
    if d.depends:
        out.append(f"  depends on: {' && '.join(d.depends)}")
    if d.selects:
        out.append("  selects: " + ", ".join(
            s + (f" if {c}" if c else "") for s, c in d.selects[:6]))
    return "\n".join(out)


def build_summary(db: KconfigDB, fragments, findings, manifest_path, manifest_rows,
                  extra=None) -> dict:
    resolved = set(db.symbols)
    frag_syms = sorted({ln.symbol for lns in fragments.values() for ln in lns if ln.symbol})
    unknown = [s for s in frag_syms if s not in resolved]
    sev = {"error": 0, "warn": 0, "info": 0}
    for f in findings:
        sev[f.sev] += 1
    return {
        "repo": db.repo,
        "branch": db.branch,
        "head_sha": db.head_sha,
        "kconfig_files_fetched": len(db.files_parsed),
        "fetch_cap_hit": db.fetch_cap_hit,
        "index_truncated": db.index_truncated,
        "symbols_defined": len(resolved),
        "fragment_symbols": frag_syms,
        "symbols_unresolved": unknown,
        "findings": {k: v for k, v in sev.items()},
        "finding_errors": [f.to_dict() for f in findings if f.sev == "error"],
        "manifest": manifest_path,
        "manifest_rows": len(manifest_rows) if manifest_rows is not None else None,
        **(extra or {}),
    }


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def default_cache_root() -> str:
    # repo root = two levels above this file (tools/kernelconfig/check.py)
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(os.path.dirname(here))
    return os.path.join(root, ".cache", "kconfig")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Validate Kconfig config fragments against the pinned "
                    "GrapheneOS kernel tree (no clone; GitHub API + cache).")
    ap.add_argument("fragments", nargs="*", help="config fragment files")
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--branch", default=DEFAULT_BRANCH)
    ap.add_argument("--cache-dir", default=default_cache_root(),
                    help="cache root (default: <repo>/.cache/kconfig)")
    ap.add_argument("--offline", action="store_true",
                    help="use cache only; nonzero exit if cache missing")
    ap.add_argument("--max-fetch", type=int, default=700,
                    help="cap on total API fetches per run (default 700)")
    ap.add_argument("--arch", choices=["arm64", "x86", "both"], default="both",
                    help="arch scope; controls $(SRCARCH) expansion and which "
                         "arch-implied dependency symbols are assumed satisfied")
    ap.add_argument("--manifest", metavar="FILE",
                    help="validate fragments against MANIFEST.yaml (default path: "
                         "MANIFEST.yaml next to the first fragment)")
    ap.add_argument("--summary", action="store_true",
                    help="print machine-readable JSON report to stdout")
    ap.add_argument("--explain", nargs="*", metavar="SYM",
                    help="print Kconfig definition info for symbols and exit")
    ap.add_argument("--strict", action="store_true",
                    help="treat warnings as errors for the exit code")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    if not args.fragments and not args.explain:
        ap.error("need at least one fragment file (or --explain)")

    arches = ("arm64",) if args.arch == "arm64" else \
             ("x86",) if args.arch == "x86" else ("arm64", "x86")

    db = KconfigDB(args.repo, args.branch, args.cache_dir,
                   max_fetch=args.max_fetch, offline=args.offline,
                   verbose=not args.quiet)
    try:
        db.walk(arches=arches)
    except SystemExit:
        raise
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if not args.quiet:
        print(f"[walk] parsed {len(db.files_parsed)} Kconfig files, "
              f"{len(db.symbols)} symbols defined "
              f"({db.repo}@{db.branch}, head {db.head_sha[:12] or '?'})"
              + (" [FETCH CAP HIT]" if db.fetch_cap_hit else ""),
              file=sys.stderr)

    if args.explain is not None:
        for s in args.explain:
            print(explain(db, s))
        return 0

    fragments = {}
    for path in args.fragments:
        fragments[path] = parse_fragment(path)

    findings = Checker(db, arches).check_fragments(fragments)

    manifest_path = args.manifest
    manifest_rows = None
    if manifest_path:
        if not os.path.exists(manifest_path):
            print(f"error: manifest {manifest_path} not found", file=sys.stderr)
            return 2
        manifest_rows = load_manifest(manifest_path)
        findings += check_manifest(fragments, manifest_rows)

    if not args.quiet:
        cur = None
        for f in sorted(findings, key=lambda x: (x.file, x.line, x.sev)):
            if f.file != cur:
                cur = f.file
                print(f"\n{cur}:", file=sys.stderr)
            print(f"  {f.sev.upper():5} [{f.code}] line {f.line} "
                  f"{f.symbol or '-'}: {f.message}", file=sys.stderr)
        n_err = sum(1 for f in findings if f.sev == "error")
        n_warn = sum(1 for f in findings if f.sev == "warn")
        print(f"\nresult: {n_err} error(s), {n_warn} warning(s), "
              f"{len(findings) - n_err - n_warn} info", file=sys.stderr)

    if args.summary:
        print(json.dumps(build_summary(db, fragments, findings, manifest_path,
                                       manifest_rows), indent=1, sort_keys=True))

    n_err = sum(1 for f in findings if f.sev == "error")
    n_warn = sum(1 for f in findings if f.sev == "warn")
    if n_err or (args.strict and n_warn):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
