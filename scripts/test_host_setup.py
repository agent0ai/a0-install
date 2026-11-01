#!/usr/bin/env python3
"""Exercise both standalone installers with fixtures, a PTY and a fake Docker CLI."""

import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class HostSetupTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="a0-import-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.host = self.root / "host with spaces"
        self.data = self.root / "instance data"
        self.host.mkdir()
        self.data.mkdir()
        self.env = os.environ.copy()
        for name in ("CODEX_HOME", "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME", "HERMES_HOME"):
            self.env.pop(name, None)
        self.env.update(A0_TEST_HOME=str(self.host), A0_TEST_DATA=str(self.data), TERM="xterm")
        self.bash = self.root / "functions.sh"
        bash_source = (ROOT / "install.sh").read_text().rsplit('\nparse_args "$@"', 1)[0]
        # Redirect only filesystem roots in the test copy, without changing HOME.
        bash_source = bash_source.replace('INSTALL_ROOT="$HOME/agent-zero"', 'INSTALL_ROOT="$A0_TEST_HOME/agent-zero"')
        bash_source = bash_source.replace('choose_host_setup "$DATA_DIR" "$HOME"', 'choose_host_setup "$DATA_DIR" "$A0_TEST_HOME"')
        self.bash.write_text(bash_source)
        self.ps = self.root / "functions.ps1"
        self.ps.write_text((ROOT / "install.ps1").read_text().rsplit("\nShow-Banner\nmain", 1)[0])

    def write(self, relative, content="fixture"):
        path = self.host / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def fixture(self):
        skill = self.write(".agents/skills/portable/SKILL.md", "---\nname: portable\ndescription: Test skill\n---\nHello\n").parent
        self.write(".agents/skills/portable/scripts/run.sh", "#!/bin/sh\nprintf 'fixture'\n").chmod(0o755)
        for name in (".env", "node_modules/package/index.js", "auth.json", "id_rsa"):
            self.write(".agents/skills/portable/" + name, "excluded-canary")
        self.write(".agents/skills/.system/hidden/SKILL.md", "excluded-canary")
        self.write(".claude/CLAUDE.md", "reference instructions")
        self.write(".claude/settings.json", '{"env":{"API_KEY":"explicit-config-canary"}}')
        self.write(".claude/.credentials.json", "excluded-canary")
        self.write(".codex/auth.json", "excluded-canary")
        self.write(".codex/history.jsonl", "excluded-canary")
        self.write(".codex/config.toml", 'model = "fixture-model"')
        blocked_root = self.host / '.codex/skills'
        blocked_root.mkdir(mode=0)
        self.addCleanup(blocked_root.chmod, 0o700)
        self.write(".gemini/skills/gemini/SKILL.md", "---\nname: gemini\ndescription: Gemini fixture\n---\nHello\n")
        self.write(".config/opencode/commands/check.md", "reference command")
        self.write(".hermes/SOUL.md", "reference personality")
        self.write(".cursor/rules/example.promptinclude.md", "not active")
        links = self.host / ".claude/skills"
        links.mkdir(exist_ok=True)
        (links / "shared").symlink_to(skill, target_is_directory=True)
        (links / "cycle").symlink_to(links, target_is_directory=True)
        (links / "missing").symlink_to(self.root / "missing", target_is_directory=True)
        outside = self.host / '.agents/skills-extra'
        outside.mkdir()
        (outside / "SKILL.md").write_text("excluded-canary")
        (links / "outside").symlink_to(outside, target_is_directory=True)
        (skill / "leak").symlink_to(outside / "SKILL.md")

    def runner(self, language, code):
        if language == "bash":
            path = self.root / "run.sh"
            path.write_text(f"source {shlex.quote(str(self.bash))}\n{code}\n")
            return ["bash", str(path)]
        if not shutil.which("pwsh"):
            self.skipTest("pwsh is not installed")
        path = self.root / "run.ps1"
        path.write_text(f". '{self.ps}'\n{code}\n")
        return ["pwsh", "-NoProfile", "-File", str(path)]

    def run_code(self, language, code, expected=0):
        result = subprocess.run(self.runner(language, code), env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout

    def run_tty(self, language, code, actions=(), timeout=12, size=(24, 100)):
        command = self.runner(language, code)
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe(command[0], command, self.env)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", *size, 0, 0))
        output = b""
        pending = list(actions)
        deadline = time.monotonic() + timeout
        finished = 0
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.05)[0]:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
                    if b"\x1b[6n" in chunk:
                        os.write(fd, b"\x1b[1;1R")
                if pending and pending[0][0].encode() in output:
                    _, keys = pending.pop(0)
                    os.write(fd, keys)
                finished, status = os.waitpid(pid, os.WNOHANG)
                if finished:
                    break
            else:
                self.fail("TTY timeout:\n" + output.decode(errors="replace"))
            if not finished:
                _, status = os.waitpid(pid, 0)
                finished = pid
            self.assertFalse(pending, f"Unsent keys {pending}: {output!r}")
            return os.waitstatus_to_exitcode(status), output.decode(errors="replace")
        finally:
            if not finished:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)
            os.close(fd)

    def test_responsive_banner(self):
        ansi = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|[=>])")
        rendered = {}
        for language, code in (("bash", "print_banner"), ("pwsh", "Show-Banner")):
            for rows, columns, expected_rows in ((24, 80, 6), (24, 43, 6), (24, 42, 4),
                                                (24, 13, 4), (24, 12, 0), (12, 80, 6)):
                with self.subTest(language=language, rows=rows, columns=columns):
                    status, output = self.run_tty(language, code, size=(rows, columns))
                    self.assertEqual(status, 0, output)
                    plain = ansi.sub("", output)
                    lines = [line for line in plain.splitlines() if line.strip()]
                    self.assertEqual(len(lines), expected_rows, plain)
                    self.assertTrue(all(len(line) <= columns for line in lines), plain)
                    if expected_rows == 4:
                        self.assertEqual(lines[-1], "▄█▀ ▄▄▄▄▄ ▀█▄")
                    key = (rows, columns)
                    if language == "bash":
                        rendered[key] = lines
                    else:
                        self.assertEqual(lines, rendered[key])
            plain = ansi.sub("", self.run_code(language, code))
            self.assertEqual(len([line for line in plain.splitlines() if line.strip()]), 6)

    def import_code(self, language):
        if language == "bash":
            return '''detect_host_setup "$A0_TEST_HOME"
printf '%s\n' "${HOST_SETUP_TARGETS[@]}"
HOST_SETUP_SELECTED=("${!HOST_SETUP_SOURCES[@]}")
HOST_SETUP_DECISION=imported
apply_host_setup "$A0_TEST_DATA"'''
        return '''$items = @(Get-HostSetupItems $env:A0_TEST_HOME)
$items.Target
Import-HostSetup $env:A0_TEST_DATA @{Decision='imported'; Items=$items}'''

    def test_discovery_and_import_bash(self):
        self.check_discovery_and_import("bash")

    def test_discovery_and_import_powershell(self):
        self.check_discovery_and_import("pwsh")

    def check_discovery_and_import(self, language):
        self.fixture()
        output = self.run_code(language, self.import_code(language))
        self.assertIn("skills/imported/gemini", output)
        self.assertIn("imports/codex/config.toml.reference", output)
        self.assertEqual(len(list(self.data.rglob("SKILL.md"))), 2)
        self.assertEqual((self.data / "imports/claude/CLAUDE.md.reference").read_text(), "reference instructions")
        self.assertIn("explicit-config-canary", (self.data / "imports/claude/settings.json.reference").read_text())
        self.assertTrue((self.data / "imports/cursor/rules/example.promptinclude.md.reference").is_file())
        self.assertFalse(list(self.data.rglob("*.promptinclude.md")))
        for path in self.data.rglob("*"):
            self.assertFalse(path.is_symlink(), path)
            if path.is_file():
                self.assertNotIn("excluded-canary", path.read_text(), path)
        self.assertEqual((self.data / ".a0-install/host-setup-v1").read_text().strip(), "imported")
        self.assertFalse(list((self.data / ".a0-install").glob("import.*")))
        self.assertTrue((self.host / ".claude/.credentials.json").exists())
        if language == "bash":
            self.assertTrue(os.access(self.data / "skills/imported/agents/portable/scripts/run.sh", os.X_OK))
            self.assertEqual((self.data / "imports/claude/settings.json.reference").stat().st_mode & 0o077, 0)

    def test_silence_and_one_time_bash(self):
        code = '''select_from_menu() { echo UNEXPECTED_PROMPT; exit 99; }
choose_host_setup "$A0_TEST_DATA" "$A0_TEST_HOME"
test -z "$HOST_SETUP_DECISION"
echo SILENT'''
        for state in ("empty", "empty-folder", "already-decided"):
            if state == "empty-folder":
                (self.host / ".cursor").mkdir()
            if state == "already-decided":
                self.fixture()
                (self.data / ".a0-install").mkdir()
                (self.data / ".a0-install/host-setup-v1").write_text("declined\n")
            status, output = self.run_tty("bash", code)
            self.assertEqual(status, 0, output)
            self.assertNotIn("UNEXPECTED_PROMPT", output)
        self.assertFalse((self.data / "imports").exists())

    def test_silence_and_one_time_powershell(self):
        code = '''function Test-InteractiveConsole { return $true }
function select_from_menu { throw 'UNEXPECTED_PROMPT' }
$selection = Select-HostSetup $env:A0_TEST_DATA $env:A0_TEST_HOME
if ($selection.Decision) { throw 'Unexpected decision' }'''
        self.run_code("pwsh", code)
        (self.host / ".cursor").mkdir()
        self.run_code("pwsh", code)
        self.fixture()
        (self.data / ".a0-install").mkdir()
        (self.data / ".a0-install/host-setup-v1").write_text("declined\n")
        self.run_code("pwsh", code)

    def test_noninteractive_skips_import(self):
        self.fixture()
        self.run_code("bash", '''A0_CLI_NON_INTERACTIVE=1
choose_host_setup "$A0_TEST_DATA" "$A0_TEST_HOME"
test -z "$HOST_SETUP_DECISION"''')
        self.run_code("pwsh", '''$script:CliNonInteractive=$true
function Test-InteractiveConsole { throw 'Should not probe console' }
$result=Select-HostSetup $env:A0_TEST_DATA $env:A0_TEST_HOME
if ($result.Decision) { throw 'Unexpected import' }''')
        self.assertFalse(list(self.data.iterdir()))

    def test_unselected_configuration_stays_on_host(self):
        self.fixture()
        for language in ("bash", "pwsh"):
            with self.subTest(language=language):
                shutil.rmtree(self.data)
                self.data.mkdir()
                code = ('''detect_host_setup "$A0_TEST_HOME"
HOST_SETUP_SELECTED=(0); HOST_SETUP_DECISION=imported
apply_host_setup "$A0_TEST_DATA"''' if language == "bash" else '''
$items = @(Get-HostSetupItems $env:A0_TEST_HOME)
Import-HostSetup $env:A0_TEST_DATA @{Decision='imported'; Items=@($items[0])}''')
                self.run_code(language, code)
                self.assertFalse((self.data / "imports").exists())
                self.assertEqual(len(list(self.data.rglob("SKILL.md"))), 1)

    def test_configured_roots(self):
        custom = self.host / "custom codex Ω"
        custom.mkdir()
        (custom / "AGENTS.md").write_text("custom instructions")
        self.env["CODEX_HOME"] = str(custom)
        for language in ("bash", "pwsh"):
            with self.subTest(language=language):
                code = ('''detect_host_setup "$A0_TEST_HOME"
printf '%s\n' "${HOST_SETUP_SOURCES[@]}"''' if language == "bash" else '''
(Get-HostSetupItems $env:A0_TEST_HOME).Source''')
                self.assertIn(str(custom / "AGENTS.md"), self.run_code(language, code))

    def test_existing_files_and_destination_links(self):
        self.write(".claude/CLAUDE.md", "new instructions")
        for language in ("bash", "pwsh"):
            with self.subTest(language=language):
                shutil.rmtree(self.data)
                self.data.mkdir()
                target = self.data / "imports/claude/CLAUDE.md.reference"
                target.parent.mkdir(parents=True)
                target.write_text("keep me")
                self.run_code(language, self.import_code(language))
                self.assertEqual(target.read_text(), "keep me")
                shutil.rmtree(self.data)
                self.data.mkdir()
                outside = self.root / ("untouched-" + language)
                outside.mkdir()
                (self.data / "imports").symlink_to(outside, target_is_directory=True)
                self.run_code(language, self.import_code(language), expected=1)
                self.assertFalse(list(outside.iterdir()))
                self.assertFalse((self.data / ".a0-install/host-setup-v1").exists())

    def test_checkbox_keys_bash(self):
        code = '''select_checkboxes 'Test choices' one two three
printf 'SELECTED=%s\n' "${CHECKED_INDICES[*]}"'''
        for fractional in (1, 0):
            with self.subTest(fractional=fractional):
                script = f'HAS_FRACTIONAL_TIMEOUT={fractional}\n' + code
                status, output = self.run_tty("bash", script, [("Esc skip", b" \x1b[B \n")])
                self.assertEqual(status, 0, output)
                self.assertIn("SELECTED=0 1", output)
                status, output = self.run_tty("bash", script, [("Esc skip", b"\x1b")])
                self.assertEqual(status, 1, output)

    def test_checkbox_keys_powershell(self):
        code = '''$indices = @(select_checkboxes 'Test choices' @('one','two','three'))
Write-Host "SELECTED=$($indices -join ' ')"'''
        status, output = self.run_tty("pwsh", code, [("Esc skips", b" \x1b[B \r")])
        self.assertEqual(status, 0, output)
        self.assertIn("SELECTED=0 1", output)

    def test_checkbox_defaults_and_paging(self):
        for language in ("bash", "pwsh"):
            with self.subTest(language=language):
                code = ('''select_checkboxes Choices $(seq 1 20)
printf 'SELECTED=%s\n' "${CHECKED_INDICES[*]}"''' if language == "bash" else '''
$indices = @(select_checkboxes Choices (1..20 | ForEach-Object { "$_" }))
Write-Host "SELECTED=$($indices -join ' ')"''')
                status, output = self.run_tty(language, code, [("Esc skip", b"\x1b[A \r")])
                self.assertEqual(status, 0, output)
                self.assertIn("SELECTED=19", output)
                self.assertIn("Items 19-20 of 20", output)
                status, output = self.run_tty(language, code, [("Esc skip", b"\r")])
                self.assertEqual(status, 0, output)
                self.assertIn("SELECTED=\r\n", output)

    def test_escape_records_decline(self):
        self.write(".claude/CLAUDE.md")
        status, output = self.run_tty("bash", '''
choose_host_setup "$A0_TEST_DATA" "$A0_TEST_HOME"
apply_host_setup "$A0_TEST_DATA"
''', [("Ctrl+C to exit", b"\x1b")])
        self.assertEqual(status, 0, output)
        self.assertEqual((self.data / ".a0-install/host-setup-v1").read_text().strip(), "declined")
        self.assertFalse((self.data / "imports").exists())

    def fake_docker(self):
        binary = self.root / "bin/docker"
        binary.parent.mkdir()
        binary.write_text('''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
Path(os.environ['A0_TEST_CALLS']).write_text(json.dumps(sys.argv[1:]))
Path(os.environ['A0_TEST_PID']).write_text(str(os.getpid()))
with open(os.environ['A0_TEST_EVENTS'], 'a') as events:
    events.write(json.dumps(sys.argv[1:]) + '\\n')
time.sleep(float(os.environ.get('A0_TEST_DELAY', '0.1')))
sys.exit(int(os.environ.get('A0_TEST_EXIT', '0')))
''')
        binary.chmod(0o755)
        self.env.update(PATH=str(binary.parent) + os.pathsep + self.env['PATH'],
                        A0_TEST_CALLS=str(self.root / "calls.json"), A0_TEST_PID=str(self.root / "pid"),
                        A0_TEST_EVENTS=str(self.root / "events.jsonl"))

    def test_background_pull_reuse_and_failure(self):
        self.fake_docker()
        for language in ("bash", "pwsh"):
            with self.subTest(language=language):
                code = ('''DOCKER=(docker --host unix:///fixture.sock)
start_image_pull v1.2
old_pid=$A0_PULL_PID
start_image_pull v1.2
test "$old_pid" = "$A0_PULL_PID"
finish_image_pull''' if language == "bash" else '''
$script:DockerHostArgs=@('--host','unix:///fixture.sock')
Start-ImagePull v1.2
$oldPid=$script:ImagePull.Process.Id
Start-ImagePull v1.2
if ($oldPid -ne $script:ImagePull.Process.Id) { throw 'Pull restarted' }
Complete-ImagePull''')
                self.env['A0_TEST_EXIT'] = '0'
                self.run_code(language, code)
                self.assertEqual(json.loads((self.root / "calls.json").read_text()),
                                 ['--host', 'unix:///fixture.sock', 'pull', '--quiet', 'agent0ai/agent-zero:v1.2'])
                self.env['A0_TEST_EXIT'] = '1'
                self.run_code(language, code, expected=1)
                self.assertFalse(list(self.data.iterdir()))

    def test_complete_wizard_overlaps_pull_and_stops_on_failure(self):
        self.write(".agents/skills/portable/SKILL.md", "---\nname: portable\ndescription: fixture\n---\nHello")
        self.fake_docker()
        self.env["A0_TEST_DELAY"] = "1"
        destination = self.host / "agent-zero/agent-zero/usr"
        for language in ("bash", "pwsh"):
            for exit_code in (0, 1):
                with self.subTest(language=language, exit_code=exit_code):
                    shutil.rmtree(self.host / "agent-zero", ignore_errors=True)
                    (self.root / "events.jsonl").write_text("")
                    self.env["A0_TEST_EXIT"] = str(exit_code)
                    code = ('''find_free_port() { echo 5080; }
suggest_next_instance_name() { echo agent-zero; }
default_image_tag() { echo v1.2; }
select_from_menu() { echo 0; }
select_checkboxes() { CHECKED_INDICES=(0); }
read_input() {
    kill -0 "$A0_PULL_PID" || return 1
    echo QUESTION_DURING_PULL
    INPUT_VALUE=""
}
wait_for_ready() { echo READY; }
if create_instance; then echo CREATED; else exit 1; fi
''' if language == "bash" else '''
$script:HomeDir=$env:A0_TEST_HOME
function Find-FreePort { return 5080 }
function suggest_next_instance_name { return 'agent-zero' }
function default_image_tag { return 'v1.2' }
function select_from_menu { return 0 }
function select_checkboxes { return 0 }
function Read-InputWithEscape {
    if ($script:ImagePull.Process.HasExited) { throw 'Pull ended before question' }
    Write-Host QUESTION_DURING_PULL
    return ''
}
function Wait-ForReady { Write-Host READY }
function Start-WslDockerKeepAlive { }
$null = create_instance
Write-Host CREATED
''')
                    status, output = self.run_tty(language, code)
                    self.assertEqual(status, exit_code, output)
                    self.assertIn("QUESTION_DURING_PULL", output)
                    calls = [json.loads(line) for line in (self.root / "events.jsonl").read_text().splitlines()]
                    self.assertEqual([args[0] for args in calls], ["pull", "run"] if exit_code == 0 else ["pull"])
                    self.assertEqual((destination / ".a0-install/host-setup-v1").exists(), exit_code == 0)
                    self.assertEqual(bool(list(destination.rglob("SKILL.md"))), exit_code == 0)

    def test_powershell_pull_uses_selected_wsl_distro(self):
        self.fake_docker()
        shutil.copy2(self.root / 'bin/docker', self.root / 'bin/wsl.exe')
        self.run_code('pwsh', '''$script:DockerMode='wsl'
$script:WslDockerDistro='Fixture Distro'
Start-ImagePull v1.2
Complete-ImagePull''')
        self.assertEqual(json.loads((self.root / 'calls.json').read_text()),
                         ['-d', 'Fixture Distro', '--exec', 'docker', 'pull', '--quiet', 'agent0ai/agent-zero:v1.2'])

    def test_cancel_reaps_download(self):
        self.fake_docker()
        self.env["A0_TEST_DELAY"] = "30"
        for language in ("bash", "pwsh"):
            with self.subTest(language=language):
                code = ('''start_image_pull v1.2
while [ ! -s "$A0_TEST_PID" ]; do sleep 0.02; done
select_checkboxes Cancel one two
echo UNEXPECTED_RESUME
''' if language == "bash" else '''
try {
    Start-ImagePull v1.2
    while (-not (Test-Path $env:A0_TEST_PID)) { Start-Sleep -Milliseconds 20 }
    select_checkboxes Cancel @('one','two')
    Write-Host UNEXPECTED_RESUME
} finally { Stop-ImagePull }
''')
                (self.root / "pid").unlink(missing_ok=True)
                status, output = self.run_tty(language, code, [("Esc skip", b"\x03")])
                if language == 'bash':
                    self.assertNotEqual(status, 0, output)
                self.assertNotIn('UNEXPECTED_RESUME', output)
                pull_pid = int((self.root / "pid").read_text())
                with self.assertRaises(ProcessLookupError):
                    os.kill(pull_pid, 0)

    def test_interrupted_copy_removes_staging(self):
        self.write('.claude/CLAUDE.md')
        for language in ('bash', 'pwsh'):
            with self.subTest(language=language):
                code = ('''copy_host_setup_tree() {
    echo COPYING
    IFS= read -rsn1 key </dev/tty
}
''' + self.import_code(language) if language == 'bash' else '''
function Copy-HostSetupTree {
    Write-Host COPYING
    $null = Read-InstallerKey
}
''' + self.import_code(language))
                self.run_tty(language, code, [('COPYING', b'\x03')])
                self.assertFalse((self.data / '.a0-install/host-setup-v1').exists())
                self.assertFalse(list((self.data / '.a0-install').glob('import.*')))
                self.assertFalse(list((self.data / 'imports').rglob('*.reference')))


if __name__ == "__main__":
    unittest.main(verbosity=2)
