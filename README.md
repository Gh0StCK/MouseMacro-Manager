# MouseMacro Manager

A local mouse macro manager for Windows, built with **AutoHotkey v2** and a **WebView2 (HTML/CSS/JavaScript)** interface.

## Features

- Record and replay mouse clicks and vertical scrolling, including delays and screen coordinates.
- Manage multiple macros with customizable hotkeys.
- Edit, duplicate, delete, and undo steps; change delays for multiple selected steps at once.
- Wait for an image to appear using AutoHotkey's built-in `ImageSearch`. Image-based clicking is no longer available for new steps.
- Stop macro playback immediately with **F9**.

## Installation

1. Download the source ZIP from the [`updates` branch](../../tree/updates) (**Code → Download ZIP**) and extract it into a separate folder.
2. Install **AutoHotkey v2** if needed, and make sure **WebView2 Runtime** is available on Windows.
3. Run `Start_MouseMacro.ahk`.
4. On first launch, the script can download the open-source [WebViewToo](https://github.com/The-CoDingman/WebViewToo) library (MIT license) from a pinned commit. No third-party installer is launched.

## Project files

- `MouseMacro_WebView.ahk` — input recording, playback, and WebView2 integration.
- `Start_MouseMacro.ahk` — initial WebViewToo setup and application launcher.
- `web/index.html` — HTML/CSS/JavaScript user interface.
- `Update_MouseMacro.ps1` and `Update_MouseMacro.cmd` — local update utilities.
- `update.json` and `VERSION.txt` — update channel manifest and version information.

**Do not commit** `MouseMacro.ini` or `MouseMacro_Images/`. They may contain personal macro actions and local file paths. Both are excluded by `.gitignore`.

## Project status

This project is a preview release. Automated Windows checks cover AutoHotkey syntax, JavaScript syntax, bridge command contracts, core event data handling, version comparison, and update-package checksums. They do not replace hands-on testing of mouse recording, playback, or WebView2 behavior on a real desktop.

The application is not code-signed. Updates rely on the integrity of the public repository and its `updates` branch.
