"""Static integration contracts for MouseMacro's HTML/WebView2/AHK bridge."""
from pathlib import Path
import re
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

if errors:
    for item in errors:
        print("ERROR:", item)
    sys.exit(1)
print(f"OK: JavaScript syntax, {len(calls)} bridge commands, update UI and file safety")
