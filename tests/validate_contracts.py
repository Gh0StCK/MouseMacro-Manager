"""Static integration contracts for MouseMacro's HTML/WebView2/AHK bridge."""
from pathlib import Path
import hashlib
import io
import json
import os
import re
import urllib.request
import zipfile
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
html = (root / "web/index.html").read_text(encoding="utf-8-sig")
ahk = (root / "MouseMacro_WebView.ahk").read_text(encoding="utf-8-sig")
ps1 = (root / "Update_MouseMacro.ps1").read_text(encoding="utf-8-sig")
manifest = (root / "update.json").read_text(encoding="utf-8-sig")
version = (root / "VERSION.txt").read_text(encoding="utf-8-sig").strip()

errors = []
def check(condition, detail):
    if not condition:
        errors.append(detail)

# There is one inline JS application script, and its syntax must be valid.
scripts = re.findall(r"<script(?:\s[^>]*)?>(.*?)</script>", html, re.S | re.I)
check(len(scripts) == 1, "Expected exactly one application script")
node = shutil.which("node")
check(bool(node), "Node.js is needed for JavaScript syntax checking")
if node and len(scripts) == 1:
    result = subprocess.run([node, "--check", "-"], input=scripts[0], text=True,
                            encoding="utf-8", capture_output=True, timeout=20)
    check(result.returncode == 0, "JavaScript syntax: " + result.stderr.strip())

# Every HTML-to-AHK bridge call must be handled by the command dispatcher.
calls = set(re.findall(r"\bcall\(\s*['\"]([A-Za-z]\w*)['\"]", html))
start = ahk.find("WebAction(view, command")
end = ahk.find("\nWebEditClick(", start)
check(start >= 0 and end > start, "WebAction dispatcher not found")
cases = set(re.findall(r'\bcase\s+"([A-Za-z]\w*)":', ahk[start:end])) if end > start else set()
check(not (calls - cases), "Missing AHK handlers: " + str(sorted(calls - cases)))
check("case \"applyUpdate\":" in ahk, "Update command missing")

# Every picker entry point must use HTML; the native Hotkey control misses mouse keys.
check("picker.AddHotkey(" not in ahk,
      "Native Hotkey input still used instead of mouse-aware picker")
show_picker = re.search(r"ShowKeyPicker\(title, targetId, initialKey := \"\"\)\s*\{(.*?)\n\}", ahk, re.S)
check(bool(show_picker) and "openHotkeyPicker" in show_picker.group(1),
      "Native entry points not routed to HTML hotkey picker")
check("d.type==='openHotkeyPicker'" in html and "keyModal(mode)" in html,
      "WebView is missing native-to-HTML hotkey-picker message handler")
check("d.type==='capturedHotkey'" in html,
      "Mouse buttons are not forwarded to the picker")
check('case "picker":' in ahk, "Hotkey picker state not managed by AHK")
check('ShowKeyPicker("Выбери клавишу для нового действия", 0)' in ahk,
      "Ctrl+Alt+R entry path no longer opens hotkey picker")
check("function keyModal(mode)" in html,
      "Shared HTML key picker no longer exists")

# Mouse side-button capture must survive focus loss while selecting a hotkey.
picker_hotkeys = re.search(r"#HotIf PickerOpen\s*(.*?)#HotIf", ahk, re.S)
check(bool(picker_hotkeys), "Missing global mouse hotkeys during key selection")
if picker_hotkeys:
    for button in ("XButton1", "XButton2", "MButton"):
        check(f"*{button}::OnWebSideButton(\"{button}\")" in picker_hotkeys.group(1),
              "Picker cannot capture " + button)
check("WebWindowIsActive() && !PickerOpen" in ahk,
      "Foreground mouse handler must exclude active hotkey picker")
check("window.addEventListener('mouseup',suppressMouseNavigation,true)" in html
      and "window.addEventListener('auxclick',suppressMouseNavigation,true)" in html,
      "Browser side-button navigation not suppressed during key capture")
check("window.removeEventListener('mouseup',keyMouseReleaseListener,true)" in html
      and "window.removeEventListener('auxclick',keyMouseReleaseListener,true)" in html,
      "Mouse capture listeners are not removed after key selection")

# The route to updates must be unique; About is informational.
check(html.count('data-action="checkUpdate"') == 1, "Duplicate update menu entry")
about_pos = html.find("if(action==='about')")
check(about_pos >= 0, "About dialog missing")
if about_pos >= 0:
    check("noOK:true" in html[about_pos:about_pos+450],
          "About dialog unexpectedly has an action button")
check("launch" not in version.lower(), "Unexpected version format")

# User data must not be part of the updater's replaceable files.
for private_file in ("MouseMacro.ini", "MouseMacro_Images", "Backups"):
    check(private_file not in re.search(r"\$files\s*=\s*@\(([^\n]+)", ps1).group(1),
          "Updater targets user data: " + private_file)
check("Get-FileHash -Algorithm SHA256" in ps1, "Update verification missing")
check("'channel':" not in manifest, "Unexpected non-JSON manifest format")
data = json.loads(manifest)
check(data.get("channel") == "updates", "Unexpected update channel")
check(data.get("version") == version, "VERSION.txt differs from update.json")
expected_files = data.get("files", {})
check(len(expected_files) >= 6, "Missing update manifest file entries")
for relative_path, expected_hash in expected_files.items():
    source_file = root / relative_path
    check(source_file.is_file(), "Update manifest references missing file: " + relative_path)
    if source_file.is_file():
        # GitHub's ZIP contains Git blob bytes (LF), while Windows checkout can
        # change line endings to CRLF. Hash the Git blob, not the worktree.
        blob = subprocess.run(["git", "show", "HEAD:" + relative_path],
                              cwd=root, capture_output=True, check=True).stdout
        actual_hash = hashlib.sha256(blob).hexdigest()
        check(actual_hash.lower() == str(expected_hash).lower(),
              "SHA-256 mismatch in Git blob for " + relative_path +
              ": expected " + str(expected_hash) + ", actual " + actual_hash)

# End-to-end: verify the very ZIP URL that the updater downloads.
if "--check-package" in sys.argv:
    commit = os.environ.get("GITHUB_SHA", "")
    check(bool(re.fullmatch(r"[0-9a-fA-F]{40}", commit)), "Missing GITHUB_SHA")
    if re.fullmatch(r"[0-9a-fA-F]{40}", commit):
        url = "https://codeload.github.com/Gh0StCK/MouseMacro-Manager/zip/" + commit
        request = urllib.request.Request(url, headers={"User-Agent": "MouseMacro-CI"})
        with urllib.request.urlopen(request, timeout=50) as response:
            payload = response.read()
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            for relative_path, expected_hash in expected_files.items():
                archive_paths = [name for name in archive.namelist()
                                 if name.endswith("/" + relative_path)]
                check(len(archive_paths) == 1,
                      "Expected exactly one ZIP entry for " + relative_path)
                if len(archive_paths) == 1:
                    actual_hash = hashlib.sha256(archive.read(archive_paths[0])).hexdigest()
                    check(actual_hash.lower() == str(expected_hash).lower(),
                          "ZIP SHA-256 mismatch for " + relative_path +
                          ": expected " + str(expected_hash) + ", actual " + actual_hash)

# Reject truncated/invalid PowerShell syntax before distributing an updater.
pwsh = shutil.which("pwsh") or shutil.which("powershell")
if pwsh:
    validation = "$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile(" +         "'Update_MouseMacro.ps1',[ref]$t,[ref]$e)|Out-Null;if($e){$e|Out-String|Write-Error;exit 1}"
    result = subprocess.run([pwsh, "-NoProfile", "-Command", validation],
                            cwd=root, text=True, encoding="utf-8",
                            capture_output=True, timeout=20)
    check(result.returncode == 0, "PowerShell updater parse error: " + result.stderr.strip())

if errors:
    for item in errors:
        print("ERROR:", item)
    sys.exit(1)
print(f"OK: JavaScript syntax, {len(calls)} bridge commands, update UI and file safety")
