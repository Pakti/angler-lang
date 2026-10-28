"""Filesystem and CLI contract tests for mirroring, with isolated trees."""
import os
import pathlib
import stat
import subprocess
import tempfile
import unittest

CLI = pathlib.Path(__file__).resolve().parents[1] / "bin" / "angler"
SOURCE = b"-module(sample). _export f(X :: integer()) :: integer()->X+1.\n"


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="angler build ")
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.input = self.root / "src_ex"
        self.output = self.root / "src"
        self.input.mkdir()

    def write(self, relative, data=b"data", tree=None):
        path = (tree or self.input) / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def run_build(self, *args, code=0):
        result = subprocess.run([str(CLI), "build", *args], cwd=self.root,
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, code, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout, b"")
        return result

    def test_default_mapping_and_compilation(self):
        self.write("sample.erlx", SOURCE)
        files = {"plain.erl": b"% untouched\r\n", "include/types.hrl": b"-define(V,42).\n",
                 ".hidden": b"hidden", "nested/no_extension": bytes(range(256)),
                 "assets/settings.json": b'{"yes":true}\n'}
        for name, data in files.items():
            self.write(name, data)
        self.write("tool", b"#!/bin/sh\nexit 0\n").chmod(0o755)
        (self.input / "empty").mkdir()
        result = self.run_build()
        self.assertEqual(result.stderr, b"")
        for name, data in files.items():
            self.assertEqual((self.output / name).read_bytes(), data)
        self.assertTrue((self.output / "empty").is_dir())
        self.assertEqual(stat.S_IMODE((self.output / "tool").stat().st_mode), 0o755)
        generated = self.output / "sample.erl"
        self.assertIn(b"-export([f/1]).", generated.read_bytes())
        self.assertNotIn(b"::", generated.read_bytes())
        subprocess.run(["erlc", "-Werror", "-o", str(self.root), str(generated)],
                       check=True, capture_output=True, timeout=20)
        result = subprocess.run(["erl", "-noshell", "-pa", str(self.root), "-eval",
                                 "42 = sample:f(41), halt()."], capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_incremental_and_changed_source(self):
        source = self.write("sample.erlx", SOURCE)
        copied = self.write("bytes", b"one")
        os.utime(source, (1_000_000_000, 1_000_000_000))
        os.utime(copied, (1_000_000_000, 1_000_000_000))
        self.run_build()
        outputs = [self.output / "sample.erl", self.output / "bytes"]
        times = [p.stat().st_mtime_ns for p in outputs]
        self.run_build()
        self.assertEqual([p.stat().st_mtime_ns for p in outputs], times)
        copied.write_bytes(b"two")
        later = outputs[1].stat().st_mtime + 10
        os.utime(copied, (later, later))
        self.run_build()
        self.assertEqual(outputs[1].read_bytes(), b"two")
        # Future input timestamps should not cause writes forever.
        times = [p.stat().st_mtime_ns for p in outputs]
        self.run_build()
        self.assertEqual([p.stat().st_mtime_ns for p in outputs], times)
        outputs[0].unlink()
        self.run_build()
        self.assertIn(b"-export", outputs[0].read_bytes())

    def test_clean_preserves_extras_delete_removes_them(self):
        self.write("sample.erlx", SOURCE)
        self.run_build()
        extra = self.write("old/nested/extra", b"valuable", self.output)
        (self.output / "empty-extra").mkdir()
        generated = self.output / "sample.erl"
        generated.write_bytes(b"edited")
        result = self.run_build("--clean")
        self.assertIn(b"warning:", result.stderr)
        self.assertIn(b"-export", generated.read_bytes())
        self.assertEqual(extra.read_bytes(), b"valuable")
        self.run_build("--clean", "--delete")
        self.assertFalse((self.output / "old").exists())
        self.assertFalse((self.output / "empty-extra").exists())
        self.assertTrue(generated.exists())

    def test_deleted_inputs_are_warned_then_deleted(self):
        source = self.write("nested/data", b"keep")
        self.run_build()
        source.unlink()
        (self.input / "nested").rmdir()
        result = self.run_build()
        self.assertIn(b"nested/data", result.stderr)
        self.assertTrue((self.output / "nested/data").exists())
        self.run_build("-d")
        self.assertFalse((self.output / "nested").exists())

    def test_warning_promotion_does_not_imply_deletion(self):
        self.write("a", b"mapped")
        extra = self.write("extra", b"keep", self.output)
        result = self.run_build("--warnings-as-errors", code=1)
        self.assertIn(b"warning:", result.stderr)
        self.assertEqual(extra.read_bytes(), b"keep")
        self.assertEqual((self.output / "a").read_bytes(), b"mapped")

    def test_type_warnings_repeat_even_when_skipping_writes(self):
        self.write("sample.erlx", b"-module(sample). _export f(X :: integer())->X; f(X)->X.")
        for _ in range(2):
            result = self.run_build("--warnings-as-errors", code=1)
            self.assertIn(b"partially annotated", result.stderr)
        extra = self.write("extra", b"remove", self.output)
        self.run_build("--warnings-as-errors", "--delete", code=1)
        self.assertFalse(extra.exists())

    def test_transpile_warning_promotion(self):
        path = self.write("sample.erlx", b"-module(sample). _export f(X :: integer())->X; f(X)->X.")
        result = subprocess.run([str(CLI), "transpile", "--warnings-as-errors", str(path)],
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"warning:", result.stderr)
        self.assertIn(b"-spec", result.stdout)

    def test_collision_prevents_any_changes(self):
        self.write("sample.erlx", SOURCE)
        self.write("sample.erl", b"plain")
        extra = self.write("extra", b"keep", self.output)
        result = self.run_build("--clean", "--delete", code=1)
        self.assertIn(b"also maps", result.stderr)
        self.assertEqual(list(self.output.iterdir()), [extra])

    def test_directory_collision(self):
        self.write("sample.erlx", SOURCE)
        self.write("sample.erl/child", b"data")
        self.run_build("--delete", code=1)
        self.assertFalse(self.output.exists())

    def test_missing_input_does_not_delete(self):
        self.input.rmdir()
        extra = self.write("extra", b"keep", self.output)
        self.run_build("--delete", code=1)
        self.assertEqual(extra.read_bytes(), b"keep")

    def test_overlap_and_normalization(self):
        source = self.write("file", b"keep")
        for output in ("src_ex", "src_ex/nested", ".", "src_ex/../src_ex"):
            result = self.run_build("--output", output, "--delete", code=1)
            self.assertIn(b"must not overlap", result.stderr)
            self.assertEqual(source.read_bytes(), b"keep")

    def test_source_failure_prevents_cleanup(self):
        self.write("a.bin", b"written before the failure")
        self.write("z.erlx", b"_export")
        extra = self.write("extra", b"keep", self.output)
        result = self.run_build("--delete", code=1)
        self.assertIn(b"z.erlx", result.stderr)
        self.assertEqual(extra.read_bytes(), b"keep")
        self.assertEqual((self.output / "a.bin").read_bytes(), b"written before the failure")
        self.assertFalse(list(self.output.glob(".angler-*")))

    def test_output_root_symlink(self):
        external = self.root / "external"
        external.mkdir()
        sentinel = self.write("keep", b"outside", external)
        self.output.symlink_to(external, target_is_directory=True)
        self.run_build("--delete", code=1)
        self.assertEqual(sentinel.read_bytes(), b"outside")

    def test_mapped_symlink_is_not_followed(self):
        self.write("sample.erlx", SOURCE)
        external = self.write("outside", b"outside", self.root)
        self.output.mkdir()
        (self.output / "sample.erl").symlink_to(external)
        self.run_build("--clean", "--delete", code=1)
        self.assertEqual(external.read_bytes(), b"outside")

    def test_parent_symlink_is_not_followed(self):
        self.write("nested/data", b"input")
        external = self.root / "external"
        external.mkdir()
        self.output.mkdir()
        (self.output / "nested").symlink_to(external, target_is_directory=True)
        self.run_build("--delete", code=1)
        self.assertEqual(list(external.iterdir()), [])

    def test_extra_symlinks_are_unlinked_not_traversed(self):
        self.write("data", b"input")
        external = self.root / "external"
        external.mkdir()
        sentinel = self.write("keep", b"outside", external)
        self.output.mkdir()
        link = self.output / "linked"
        link.symlink_to(external, target_is_directory=True)
        broken = self.output / "broken"
        broken.symlink_to(self.root / "does-not-exist")
        result = self.run_build()
        self.assertIn(b"linked", result.stderr)
        self.assertTrue(link.is_symlink())
        self.run_build("--delete")
        self.assertFalse(link.is_symlink())
        self.assertFalse(broken.is_symlink())
        self.assertEqual(sentinel.read_bytes(), b"outside")

    def test_input_symlinks_are_rejected(self):
        external = self.write("outside", b"outside", self.root)
        (self.input / "linked").symlink_to(external)
        self.run_build("--delete", code=1)
        self.assertFalse(self.output.exists())

    def test_output_type_conflict(self):
        self.write("data", b"input")
        (self.output / "data").mkdir(parents=True)
        extra = self.write("extra", b"keep", self.output)
        self.run_build("--clean", "--delete", code=1)
        self.assertEqual(extra.read_bytes(), b"keep")
        self.assertTrue((self.output / "data").is_dir())

    def test_overrides_encoding_and_arbitrary_bytes(self):
        alternate = self.root / "input with spaces"
        alternate.mkdir()
        self.write("sample.erlx", b"% caf\xe9\r\n-module(sample). _export f()->ok.", alternate)
        self.write("raw.erl", b"\x00\xff", alternate)
        result = self.run_build("--input", str(alternate), "--output", "output with spaces",
                                "--encoding", "latin1")
        out = self.root / "output with spaces"
        self.assertEqual(result.stderr, b"")
        self.assertIn(b"% caf\xe9\r\n", (out / "sample.erl").read_bytes())
        self.assertEqual((out / "raw.erl").read_bytes(), b"\x00\xff")

    def test_hardlinked_output_is_rejected(self):
        source = self.write("sample.erlx", SOURCE)
        self.output.mkdir()
        os.link(source, self.output / "sample.erl")
        result = self.run_build("--clean", "--delete", code=1)
        self.assertIn(b"hard-linked", result.stderr)
        self.assertEqual(source.read_bytes(), SOURCE)

    def test_write_failure_prevents_deletion_and_preserves_output(self):
        if os.geteuid() == 0:
            self.skipTest("requires normal user permission checks")
        self.write("data", b"new")
        mapped = self.write("data", b"old", self.output)
        extra = self.write("extra", b"keep", self.output)
        self.output.chmod(0o500)
        try:
            self.run_build("--clean", "--delete", code=1)
            self.assertEqual(mapped.read_bytes(), b"old")
            self.assertEqual(extra.read_bytes(), b"keep")
            self.assertFalse(list(self.output.glob(".angler-*")))
        finally:
            self.output.chmod(0o700)

    def test_bad_options(self):
        for args in (("--input",), ("--output",), ("--encoding", "utf16"),
                     ("positional",), ("--unknown",)):
            self.run_build(*args, code=2)


if __name__ == "__main__":
    unittest.main()
