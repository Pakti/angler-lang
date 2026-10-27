"""Exercise the real launcher and its stdin/stdout/stderr process contract."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / "bin" / "angler"


def run(*args, data=b"", cwd=None):
    return subprocess.run([str(CLI), *args], input=data, capture_output=True,
                          cwd=cwd or ROOT, timeout=20)


class CliTests(unittest.TestCase):
    def test_help_and_version(self):
        for arg in ("--help", "-h"):
            result = run(arg)
            self.assertEqual(result.returncode, 0)
            self.assertIn(b"Usage:", result.stdout)
            self.assertEqual(result.stderr, b"")
        result = run("--version")
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, b"Angler 0.3.0\n", b""))

    def test_snippet_bytes(self):
        for source in (b"", b"% EOF", b"X = 40, X + 2.\r\n", b"42.",
                       '"caf\u00e9 \U0001f41f".\n'.encode(), b"\xef\xbb\xbf42."):
            with self.subTest(source=source):
                result = run("snippet", data=source)
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (0, source, b""))

    def test_chunked_input(self):
        source = ("% " + "\u00e9" * 100000 + "\n42.").encode()
        result = run("snippet", data=source)
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, source, b""))

    def test_latin1(self):
        source = b"% caf\xe9\r\n42."
        result = run("snippet", "--encoding", "latin1", data=source)
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, source, b""))
        result = run("snippet", data=source)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"invalid or incomplete utf8", result.stderr)

    def test_snippet_diagnostics(self):
        for source in (b"X =", b"42", b"-module(m).", b"_export f()->ok.",
                       b"P :: #person{} = get_person(), P.name.", b"\xff"):
            result = run("snippet", data=source)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, b"")
            self.assertIn(b"<stdin>:", result.stderr)
            self.assertNotIn(b"init terminating", result.stderr)

    def test_usage_errors(self):
        for args in ((), ("wat",), ("build",), ("transpile",),
                     ("transpile", "a", "b"), ("snippet", "file"),
                     ("snippet", "--eqwalizer"), ("snippet", "--encoding"),
                     ("snippet", "--encoding", "utf16")):
            result = run(*args)
            self.assertEqual(result.returncode, 2, args)
            self.assertEqual(result.stdout, b"")
            self.assertIn(b"angler:", result.stderr)

    def test_missing_file(self):
        result = run("transpile", "/no/such/angler/file.erlx")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"no such file", result.stderr)

    def test_file_and_working_directory(self):
        with tempfile.TemporaryDirectory(prefix="angler cli ") as directory:
            path = pathlib.Path(directory) / "-source file.erlx"
            source = b"-module(cli_fixture).\n_export\nrun()->42.\n"
            path.write_bytes(source)
            result = run("transpile", "--", path.name, cwd=directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, b"")
            self.assertEqual(path.read_bytes(), source)
            self.assertIn(b"-export([run/0]).", result.stdout)
            emitted = pathlib.Path(directory) / "cli_fixture.erl"
            emitted.write_bytes(result.stdout)
            subprocess.run(["erlc", "-Werror", "-o", directory, str(emitted)],
                           check=True, capture_output=True, timeout=20)
            executed = subprocess.run(["erl", "-noshell", "-pa", directory,
                "-eval", "42 = cli_fixture:run(), halt()."],
                capture_output=True, timeout=20)
            self.assertEqual(executed.returncode, 0, executed.stderr)

    def test_file_error_and_latin1(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "input.erlx"
            path.write_bytes(b"-module(m).\n_export\n-spec f()->ok.\nf()->ok.")
            result = run("transpile", str(path))
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, b"")
            self.assertIn(b": 2:1:", result.stderr)
            path.write_bytes(b"% caf\xe9\r\n-module(m).\r\nf()->ok.")
            result = run("transpile", str(path), "--encoding", "latin1")
            self.assertEqual((result.returncode, result.stdout, result.stderr),
                             (0, path.read_bytes(), b""))

    def test_unicode_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "café.erlx"
            source = '-module(m).\n% café 🐟\n_export f()->ok.'.encode()
            path.write_bytes(source)
            result = run("transpile", str(path))
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stderr, b"")
            self.assertIn("% café 🐟\n".encode(), result.stdout)
            path.write_bytes(b"_export")
            result = run("transpile", str(path))
            self.assertEqual(result.returncode, 1)
            self.assertIn(str(path).encode(), result.stderr)


if __name__ == "__main__":
    unittest.main()
