"""Offline subprocess regressions for model replacement and release tag handling.

Production shell runs use disposable trees and local tool stand-ins. Only the tiny
macOS directory-exchange helper runs natively. No model, network, signing, app,
or camera operations are performed.
"""

import json
import os
import signal
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = "DepthAnythingV2SmallF16.mlpackage"
COMPILED = "DepthAnythingV2SmallF16.mlmodelc"
MEMBERS = (
    "Data/com.apple.CoreML/model.mlmodel",
    "Data/com.apple.CoreML/weights/weight.bin",
    "Manifest.json",
)


class BuildInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="opal build inputs ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.script = scripts / "fetch-models.sh"
        shutil.copy2(ROOT / "scripts/fetch-models.sh", self.script)
        self.models = self.root / "Models"
        self.compiled = self.models / COMPILED
        self.env = {
            **os.environ,
            "PATH": f"{self.tools}{os.pathsep}{os.defpath}",
            "PROBE_ROOT": str(self.root),
        }
        for key in ("DOWNLOAD_MODE", "COMPILE_MODE", "SWAP_MODE", "DMG_FAIL_ONCE"):
            self.env.pop(key, None)
        self.tool("curl", '''
import os, signal, sys
from pathlib import Path
root = Path(os.environ["PROBE_ROOT"])
url = sys.argv[-1]
dest = Path(sys.argv[sys.argv.index("-o") + 1])
with (root / "downloads").open("a") as log:
    log.write(url + "\\n")
mode = os.environ.get("DOWNLOAD_MODE", "success") if url.endswith("weight.bin") else "success"
dest.write_bytes(b"" if mode == "empty" else b"partial" if mode != "success" else b"complete")
if mode == "interrupt":
    os.kill(os.getppid(), signal.SIGTERM)
if mode in ("fail", "interrupt"):
    sys.exit(18)
''')
        self.tool("xcrun", '''
import json, os, signal, subprocess, sys
from pathlib import Path
root = Path(os.environ["PROBE_ROOT"])
if sys.argv[1:3] == ["coremlcompiler", "compile"]:
    mode = os.environ.get("COMPILE_MODE", "success")
    package = Path(sys.argv[3])
    for member in ("Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin", "Manifest.json"):
        assert (package / member).read_bytes() == b"complete"
    if mode != "missing":
        output = Path(sys.argv[4]) / (package.stem + ".mlmodelc")
        output.mkdir()
        (output / "new").write_bytes(b"replacement")
    if mode == "interrupt":
        os.kill(os.getppid(), signal.SIGTERM)
    sys.exit(65 if mode in ("fail", "interrupt") else 0)
if sys.argv[1] == "clang":
    result = subprocess.run(["/usr/bin/xcrun", *sys.argv[1:]])
    if result.returncode:
        sys.exit(result.returncode)
    mode = os.environ.get("SWAP_MODE")
    if mode:
        helper = Path(sys.argv[-1])
        native = helper.with_name("exchange-model-native")
        helper.rename(native)
        helper.write_text(f"""#!{sys.executable}
import os, signal, subprocess, sys
mode = {mode!r}
if mode == "fail":
    sys.exit(1)
if mode in ("interrupt", "kill-before"):
    os.kill(os.getppid(), signal.SIGKILL if mode == "kill-before" else signal.SIGTERM)
    sys.exit(1)
result = subprocess.run([{str(native)!r}, *sys.argv[1:]])
if result.returncode == 0 and mode == "kill-after":
    os.kill(os.getppid(), signal.SIGKILL)
sys.exit(result.returncode)
""")
        helper.chmod(0o755)
    sys.exit(0)
with (root / "notary-args").open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
''')

    def tool(self, name, source):
        path = self.tools / name
        path.write_text(f"#!{sys.executable}\n" + textwrap.dedent(source).lstrip())
        path.chmod(0o755)

    def run_fetch(self, **settings):
        return subprocess.run(
            ["/bin/bash", str(self.script)], cwd=self.root,
            env={**self.env, **settings}, capture_output=True, text=True, timeout=15,
        )

    def previous_model(self):
        if sys.platform != "darwin":
            self.skipTest("Model replacement uses macOS atomic directory exchange")
        self.compiled.mkdir(parents=True)
        (self.compiled / "old").write_bytes(b"last working model")

    def assert_previous_model(self):
        self.assertEqual(sorted(p.name for p in self.compiled.iterdir()), ["old"])
        self.assertEqual((self.compiled / "old").read_bytes(), b"last working model")

    def assert_no_temporary_outputs(self):
        self.assertEqual(list(self.models.rglob("*.download.*")), [])
        self.assertEqual(list(self.models.glob(".compile.*")), [])

    def download_failure_and_retry(self, mode):
        self.previous_model()
        failure = self.run_fetch(DOWNLOAD_MODE=mode)
        self.assertNotEqual(failure.returncode, 0, failure.stdout + failure.stderr)
        self.assertFalse((self.models / PACKAGE / MEMBERS[1]).exists())
        self.assert_previous_model()
        self.assert_no_temporary_outputs()
        retry = self.run_fetch()
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        downloads = (self.root / "downloads").read_text().splitlines()
        for member, count in zip(MEMBERS, (1, 2, 1)):
            self.assertEqual(sum(url.endswith("/" + member) for url in downloads), count)
            self.assertEqual((self.models / PACKAGE / member).read_bytes(), b"complete")
        self.assertEqual((self.compiled / "new").read_bytes(), b"replacement")
        self.assertFalse((self.compiled / "old").exists())
        self.assert_no_temporary_outputs()

    def test_failed_download_is_not_cached_on_retry(self):
        self.download_failure_and_retry("fail")

    def test_interrupted_download_is_not_cached_on_retry(self):
        self.download_failure_and_retry("interrupt")

    def test_empty_successful_download_is_not_cached_on_retry(self):
        self.download_failure_and_retry("empty")

    def compile_failure_and_retry(self, **settings):
        self.previous_model()
        failure = self.run_fetch(**settings)
        self.assertNotEqual(failure.returncode, 0, failure.stdout + failure.stderr)
        self.assert_previous_model()
        self.assert_no_temporary_outputs()
        downloads = (self.root / "downloads").read_bytes()
        retry = self.run_fetch()
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertEqual((self.root / "downloads").read_bytes(), downloads)
        self.assertEqual(sorted(p.name for p in self.compiled.iterdir()), ["new"])
        self.assertEqual((self.compiled / "new").read_bytes(), b"replacement")
        self.assert_no_temporary_outputs()

    def test_failed_compilation_preserves_previous_model(self):
        self.compile_failure_and_retry(COMPILE_MODE="fail")

    def test_interrupted_compilation_preserves_previous_model(self):
        self.compile_failure_and_retry(COMPILE_MODE="interrupt")

    def test_missing_compiler_output_preserves_previous_model(self):
        self.compile_failure_and_retry(COMPILE_MODE="missing")

    def test_failed_install_preserves_previous_model(self):
        self.compile_failure_and_retry(SWAP_MODE="fail")

    def test_interrupted_swap_preserves_previous_model(self):
        self.compile_failure_and_retry(SWAP_MODE="interrupt")

    def test_first_install_publishes_complete_model(self):
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.compiled / "new").read_bytes(), b"replacement")
        self.assert_no_temporary_outputs()

    def test_replacement_keeps_published_directory_visible(self):
        self.previous_model()
        stop = threading.Event()
        observing = threading.Event()
        missing = []

        def observe():
            while not stop.is_set():
                try:
                    self.compiled.stat()
                except FileNotFoundError:
                    missing.append(True)
                observing.set()
                stop.wait(0.0001)

        reader = threading.Thread(target=observe)
        reader.start()
        try:
            self.assertTrue(observing.wait(1))
            result = self.run_fetch()
        finally:
            stop.set()
            reader.join()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(missing, "Replacement briefly removed the published model")
        self.assertEqual((self.compiled / "new").read_bytes(), b"replacement")

    def killed_swap_and_retry(self, mode):
        self.previous_model()
        result = self.run_fetch(SWAP_MODE=mode)
        self.assertEqual(result.returncode, -signal.SIGKILL, result.stdout + result.stderr)
        if mode == "kill-before":
            self.assert_previous_model()
        else:
            self.assertEqual(sorted(p.name for p in self.compiled.iterdir()), ["new"])
            self.assertEqual((self.compiled / "new").read_bytes(), b"replacement")
        retry = self.run_fetch()
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertEqual((self.compiled / "new").read_bytes(), b"replacement")

    def test_killed_swap_before_exchange_keeps_old_model(self):
        self.killed_swap_and_retry("kill-before")

    def test_killed_swap_after_exchange_keeps_new_model(self):
        self.killed_swap_and_retry("kill-after")

    def workflow_step(self, name, tag):
        # Extract and execute the actual YAML block, emulating runner expression
        # expansion in both environment data and shell source.
        lines = (ROOT / ".github/workflows/release.yml").read_text().splitlines()
        start = lines.index("      - name: " + name) + 1
        end = next((i for i in range(start, len(lines)) if lines[i].startswith("      - ")), len(lines))
        block = lines[start:end]
        run = block.index("        run: |")
        source = textwrap.dedent("\n".join(block[run + 1:]))
        environment = dict(self.env)
        for line in block[:run]:
            if line.startswith("          "):
                key, value = line.strip().split(": ", 1)
                environment[key] = tag if value == "${{ github.ref_name }}" else "offline-test-value"
        source = re.sub(r"\$\{\{\s*github\.ref_name\s*\}\}", lambda match: tag, source)
        return subprocess.run(
            ["/bin/bash", "-e", "-c", source], cwd=self.root, env=environment,
            capture_output=True, text=True, timeout=15,
        )

    def test_release_tag_is_literal_filename_in_both_shell_steps(self):
        tag = "v$(touch${IFS}tag-injected)"
        validity = subprocess.run(
            ["git", "check-ref-format", f"refs/tags/{tag}"], cwd=self.root,
            env=self.env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(validity.returncode, 0, validity.stdout + validity.stderr)
        filename = f"OpenOpal-{tag}.dmg"
        self.tool("create-dmg", '''
import json, os, sys
from pathlib import Path
root = Path(os.environ["PROBE_ROOT"])
log = root / "dmg-args"
first = not log.exists()
with log.open("a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\\n")
if first and os.environ.get("DMG_FAIL_ONCE"):
    sys.exit(1)
Path(sys.argv[-2]).write_bytes(b"offline dmg")
''')
        self.env["DMG_FAIL_ONCE"] = "1"
        for step in ("Package DMG", "Notarize DMG"):
            result = self.workflow_step(step, tag)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((self.root / "tag-injected").exists())
        self.assertEqual((self.root / filename).read_bytes(), b"offline dmg")
        calls = [json.loads(line) for line in (self.root / "dmg-args").read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(call[-2] == filename for call in calls))
        notary = [json.loads(line) for line in (self.root / "notary-args").read_text().splitlines()]
        self.assertEqual(notary[0][:3], ["notarytool", "submit", filename])
        self.assertEqual(notary[1], ["stapler", "staple", filename])


if __name__ == "__main__":
    unittest.main()
