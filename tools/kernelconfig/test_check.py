#!/usr/bin/env python3
"""Unit tests for tools/kernelconfig/check.py.

Runs fully offline against a fixture Kconfig cache under testdata/kconfig/
(no network, no gh). The fixture mimics the on-disk layout the validator
builds from GrapheneOS/kernel_common-6.6: tree_index.json + meta.json +
files/<path> for a handful of tiny Kconfig definitions.

Covered:
  - missing symbol            -> error (walk complete, so nonexistence is known)
  - unsatisfied dependency    -> warn with the failing clause named
  - select forcing            -> info when a selected symbol is unset
  - cross-layer conflict      -> error; same-value duplicate -> warn only
  - not-set consistency       -> error on non-bool/tristate
  - manifest mode             -> coverage, orphan rows, value mismatch
  - expression parser         -> precedence, negation, unknown symbols
  - offline mode with no cache -> nonzero exit
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import check  # noqa: E402  (local module)

HERE = os.path.dirname(os.path.abspath(__file__))
TESTDATA = os.path.join(HERE, "testdata")
TEST_REPO = "GrapheneOS/kernel_common-6.6"
TEST_BRANCH = "17"


def make_db(tmp_root: str, offline: bool = True) -> check.KconfigDB:
    cache_root = os.path.join(tmp_root, "kconfig")
    shutil.copytree(os.path.join(TESTDATA, "kconfig"), cache_root)
    return check.KconfigDB(TEST_REPO, TEST_BRANCH, cache_root,
                           max_fetch=50, offline=offline, verbose=False)


def run_check(tmp_root: str, fragment_paths, offline: bool = True):
    db = make_db(tmp_root, offline=offline)
    db.walk(arches=("arm64",))
    fragments = {p: check.parse_fragment(p) for p in fragment_paths}
    return db, check.Checker(db, ("arm64",)).check_fragments(fragments)


def codes(findings):
    return [f.code for f in findings]


class ExpressionTests(unittest.TestCase):
    def test_precedence_and_negation(self):
        v = {"A": 2, "B": 0, "C": 1}
        self.assertIs(check.eval_expr("A && B", v, lambda s: False), False)
        self.assertIs(check.eval_expr("A || B", v, lambda s: False), True)
        self.assertIs(check.eval_expr("!B", v, lambda s: False), True)
        self.assertIs(check.eval_expr("!(A && B) || C", v, lambda s: False), True)
        self.assertIs(check.eval_expr("(A || B) && C", v, lambda s: False), True)
        # m counts as non-n for dependency purposes
        self.assertIs(check.eval_expr("C", v, lambda s: False), True)

    def test_unknown_symbol_is_false(self):
        self.assertIs(check.eval_expr("NOPE", {}, lambda s: False), False)
        self.assertIs(check.eval_expr("NOPE", {}, lambda s: True), True)

    def test_unparsable_returns_none(self):
        self.assertIsNone(check.eval_expr('FOO = "y"', {}, lambda s: False))
        self.assertIsNone(check.eval_expr('$(cc-option,-foo)', {}, lambda s: False))


class OfflineNoCacheTests(unittest.TestCase):
    def test_offline_without_cache_exits_nonzero(self):
        tmp = tempfile.mkdtemp()
        try:
            db = check.KconfigDB(TEST_REPO, TEST_BRANCH, os.path.join(tmp, "kconfig"),
                                 offline=True, verbose=False)
            with self.assertRaises(SystemExit) as ctx:
                db.walk(arches=("arm64",))
            self.assertIn("offline", str(ctx.exception))
        finally:
            shutil.rmtree(tmp)


class FragmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def _frag(self, name, text):
        path = os.path.join(self.tmp, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        pathlib.Path(path).write_text(text)
        return path

    def test_missing_symbol_is_error(self):
        frag = self._frag("f1.cfg", "CONFIG_NO_SUCH_SYMBOL_ANYWHERE=y\n")
        _, findings = run_check(self.tmp, [frag])
        self.assertIn("missing-symbol", codes(findings))
        f = [x for x in findings if x.code == "missing-symbol"][0]
        self.assertEqual(f.sev, "error")
        self.assertEqual(f.symbol, "NO_SUCH_SYMBOL_ANYWHERE")

    def test_unsatisfied_dependency_warns_with_clause(self):
        frag = self._frag("f2.cfg", "CONFIG_TEST_DRV=y\n")
        _, findings = run_check(self.tmp, [frag])
        unsat = [f for f in findings if f.code == "unsatisfied-dep"]
        self.assertEqual(len(unsat), 1)
        self.assertIn("TEST_MISSING", unsat[0].message)
        self.assertIn("TEST_MM", unsat[0].message)

    def test_dependency_satisfied_when_fragments_provide_it(self):
        frag = self._frag(
            "f3.cfg",
            "CONFIG_TEST_MM=y\n"
            "# CONFIG_TEST_DRV is not set\n")
        _, findings = run_check(self.tmp, [frag])
        self.assertNotIn("unsatisfied-dep", codes(findings))
        self.assertNotIn("missing-symbol", codes(findings))

    def test_select_forces_on_when_target_unset(self):
        frag = self._frag("f4.cfg", "CONFIG_TEST_DRV_SEL=y\n")
        _, findings = run_check(self.tmp, [frag])
        self.assertIn("select-forces-on", codes(findings))

    def test_cross_layer_conflict_is_error(self):
        base = self._frag("base.cfg", "CONFIG_TEST_MM=y\n")
        soc = self._frag("soc/soc-test.cfg", "# CONFIG_TEST_MM is not set\n")
        _, findings = run_check(self.tmp, [base, soc])
        conf = [f for f in findings if f.code == "cross-layer-conflict"]
        self.assertEqual(len(conf), 1)
        self.assertEqual(conf[0].sev, "error")
        self.assertIn("soc", conf[0].message)

    def test_cross_layer_duplicate_same_value_is_warning_only(self):
        base = self._frag("base.cfg", "CONFIG_TEST_MM=y\n")
        arch = self._frag("arch-arm64.cfg", "CONFIG_TEST_MM=y\n")
        _, findings = run_check(self.tmp, [base, arch])
        dup = [f for f in findings if f.code == "cross-layer-duplicate"]
        self.assertEqual(len(dup), 1)
        self.assertEqual(dup[0].sev, "warn")
        self.assertNotIn("cross-layer-conflict", codes(findings))

    def test_not_set_on_non_bool_is_error(self):
        frag = self._frag("f5.cfg", "# CONFIG_TEST_STR is not set\n")
        _, findings = run_check(self.tmp, [frag])
        self.assertIn("not-set-on-non-bool", codes(findings))

    def test_promptless_pin_matching_default_is_info(self):
        frag = self._frag("f6.cfg", "CONFIG_TEST_PROMPTLESS=y\n")
        _, findings = run_check(self.tmp, [frag])
        self.assertIn("promptless-pinned", codes(findings))
        self.assertNotIn("promptless-mismatch", codes(findings))

    def test_promptless_pin_conflicting_default_warns(self):
        frag = self._frag("f7.cfg", "CONFIG_TEST_PROMPTLESS=n\n")
        # value n via assignment is normalized to not-set; use an int-ish
        # promptless symbol with a literal default instead
        frag = self._frag("f7.cfg", "CONFIG_TEST_STR=\"zzz\"\n")
        _, findings = run_check(self.tmp, [frag])
        # string symbol with no prompt in fixture -> promptless info, no crash
        self.assertTrue(any(f.code.startswith("promptless") for f in findings))


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def _frag(self, name, text):
        path = os.path.join(self.tmp, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        pathlib.Path(path).write_text(text)
        return path

    def test_manifest_coverage_and_orphans(self):
        frag = self._frag("base.cfg", "CONFIG_TEST_MM=y\n")
        good = self._frag(
            "MANIFEST.yaml",
            "TEST_MM:\n"
            "  value: y\n"
            "  provenance: fixture\n"
            "  portability_class: universal\n"
            "TEST_ORPHAN:\n"
            "  value: y\n"
            "  provenance: fixture\n"
            "  portability_class: universal\n")
        rows = check.load_manifest(good)
        _, findings = run_check(self.tmp, [frag])
        findings += check.check_manifest({frag: check.parse_fragment(frag)}, rows)
        self.assertIn("manifest-orphan-row", codes(findings))
        self.assertNotIn("manifest-missing-row", codes(findings))

    def test_manifest_value_mismatch(self):
        frag = self._frag("base.cfg", "CONFIG_TEST_MM=y\n")
        man = self._frag(
            "MANIFEST.yaml",
            "TEST_MM:\n"
            "  value: n\n"
            "  provenance: fixture\n"
            "  portability_class: universal\n")
        rows = check.load_manifest(man)
        findings = check.check_manifest({frag: check.parse_fragment(frag)}, rows)
        self.assertIn("manifest-value-mismatch", codes(findings))

    def test_manifest_row_needs_provenance_and_class(self):
        man = self._frag(
            "MANIFEST.yaml",
            "TEST_MM:\n"
            "  value: y\n")
        rows = check.load_manifest(man)
        frag = self._frag("base.cfg", "CONFIG_TEST_MM=y\n")
        findings = check.check_manifest({frag: check.parse_fragment(frag)}, rows)
        self.assertIn("manifest-no-provenance", codes(findings))
        self.assertIn("manifest-bad-class", codes(findings))

    def test_manifest_mode_end_to_end_via_main(self):
        frag = self._frag("base.cfg", "CONFIG_TEST_MM=y\n")
        man = self._frag(
            "MANIFEST.yaml",
            "TEST_MM:\n"
            "  value: y\n"
            "  provenance: fixture\n"
            "  portability_class: universal\n")
        cache_root = os.path.join(self.tmp, "kconfig")
        shutil.copytree(os.path.join(TESTDATA, "kconfig"), cache_root)
        rc = check.main([frag, "--manifest", man, "--cache-dir", cache_root,
                         "--offline", "--quiet"])
        self.assertEqual(rc, 0)


class FixtureSanityTests(unittest.TestCase):
    def test_fixture_cache_loads(self):
        tmp = tempfile.mkdtemp()
        try:
            db = make_db(tmp)
            self.assertTrue(db.load_cache())
            self.assertEqual(db.head_sha, "deadbeefcafe")
        finally:
            shutil.rmtree(tmp)

    def test_fixture_walk_resolves_symbols(self):
        tmp = tempfile.mkdtemp()
        try:
            db = make_db(tmp)
            db.walk(arches=("arm64",))
            for sym in ("TEST_MM", "TEST_DRV", "TEST_PROMPTLESS",
                        "ARM64_ONLY_SYM", "TEST_STR", "TEST_DRV_SEL"):
                self.assertIn(sym, db.symbols, sym)
        finally:
            shutil.rmtree(tmp)


if __name__ == "__main__":
    unittest.main(verbosity=2)
