#Requires AutoHotkey v2.0
#SingleInstance Force
#Include Lib\WebViewToo.ahk

; MouseMacro Manager - multiple mouse-click macros, AutoHotkey v2 / Windows.
; Ctrl+Alt+R   Start a new recording / stop and save current recording.
; Ctrl+Alt+Esc Cancel current recording.
; F9           Emergency stop during playback.
; Each saved macro has its own configurable playback hotkey.
; Recorded: left/right/middle mouse clicks and wheel up/down + screen coordinates + timing.
; Not recorded: keyboard input, drags, horizontal/precision wheel deltas, plain mouse moves.

CoordMode("Mouse", "Screen")
CoordMode("Pixel", "Screen")
SendMode("Event")
SetMouseDelay(-1)

global IniPath := A_ScriptDir "\MouseMacro.ini"
global Macros := []
global NextId := 1
global Draft := ""
; 0 means a new macro; a nonzero ID means record extra steps for an existing one.
global RecordingTargetId := 0
global RecordingAfterStep := 0
global SelectedId := 0
global IsRecording := false
global IsPlaying := false
global StopRequested := false
global PendingPlaybackId := 0
global PendingPlaybackDeadline := 0
global PickerOpen := false
global RefreshingList := false
global LastRecordedAt := 0
global MouseGuardHook := 0
global MouseGuardCallback := 0
global MouseGuardActive := false
; Give the active application time to register the final mouse-up before restoring cursor.
global CursorRestoreDelayMs := 50

global MainGui := ""
global MacroLV := ""
global StepLV := ""
global StatusText := ""
global BtnStart := ""
global BtnStop := ""
global BtnPlay := ""
global BtnRename := ""
global BtnRekey := ""
global BtnDelete := ""
global BtnDelay := ""
global BtnRemoveStep := ""
global BtnAddSteps := ""
global BtnSelectAllSteps := ""
global BtnImageClick := ""
global BtnWaitImage := ""
global BtnConfigureImage := ""
global BtnRepeat := ""
global MacroPanelTitle := ""
global TitleText := ""
global MacroInfoText := ""
global SelectionSummaryText := ""
global AddStepMenu := ""
global RecordMenu := ""
global BtnRecordDropdown := ""
global BtnCopy := ""
global BtnMoveUp := ""
global BtnMoveDown := ""
global RepeatEdit := ""
global RepeatSpin := ""
global UpdatingRepeat := false
global PendingCopyId := 0
global WebGui := ""
global WebLastState := ""
global StepUndoHistory := []
global UpdateCheckRequest := ""
global UpdateCheckStartedAt := 0
global AppUpdatePending := false


; Automated version-check regression test; exits before opening GUI.
if (A_Args.Length > 0 && A_Args[1] = "--test-versions") {
    samples := [
        ["0.1.0-preview.4", "0.1.0-preview.4", "latest"],
        ["0.1.0-preview.4", Chr(0xFEFF) "0.1.0-preview.4`r`n", "latest"],
        ["0.1.0-preview.5", "0.1.0-preview.4", "available"],
        ["0.1.0-preview.3", "0.1.0-preview.4", "latest"],
        ["bad-version", "0.1.0-preview.4", "error"]
    ]
    for sample in samples {
        actual := AppUpdateState(sample[1], sample[2])
        if (actual != sample[3])
            throw Error("Version check failed: " sample[1] " vs " sample[2] " => " actual)
    }
    ExitApp(0)
}


; Core data regression tests run with AHK v2 without opening Windows GUI.
if (A_Args.Length > 0 && A_Args[1] = "--test-core") {
    try {
    cases := [
        ["100|LButton|40|55", "click", 100],
        ["25|RButton|-30|122", "click", 25],
        ["15|MButton|0|0", "click", 15],
        ["S|18|WheelDown|-120|900", "wheel", 18],
        ["S|22|WheelUp|10|20", "wheel", 22],
        ["W|500|10000|5|example.png", "wait_image", 500]
    ]
    for test in cases {
        ; Historical click format has no explicit kind prefix.
        record := ParseStep(test[1])
        if !IsObject(record)
            throw Error("Could not parse event: " test[1])
        if (StepKind(record) != test[2] || record.delay != test[3])
            throw Error("Incorrect parsed event: " test[1])
    }
    for invalid in ["", "bad-data", "S|10|WheelLeft|0|0", "W|12|bad|0|x.png", "3|Invalid|2|3"] {
        if IsObject(ParseStep(invalid))
            throw Error("Unexpectedly accepted invalid event: " invalid)
    }
    original := [{delay: 250, button: "LButton", x: 2, y: 3}, {type: "wheel", delay: 20, button: "WheelUp", x: 4, y: 5}]
    cloned := CloneMacroSteps(original)
    cloned[1].delay := 999
    cloned[2].x := 900
    if (original[1].delay != 250 || original[2].x != 4)
        throw Error("Cloned steps unexpectedly mutated source data.")
    ; Every entry point must use the same HTML picker mode.
    if (PickerModeForTarget(0) != "new"
        || PickerModeForTarget(-1) != "copy"
        || PickerModeForTarget(42) != "rekey")
        throw Error("Hotkey-picker routing returned an incorrect mode.")
    ; Mouse buttons and their modifier combinations must be valid macro hotkeys.
    for key in ["XButton1", "XButton2", "MButton", "^XButton1", "!XButton2", "+MButton", "F6", "Numpad1"] {
        if !CheckKey(key)
            throw Error("Valid hotkey rejected: " key)
    }
    ; F9 must cancel a macro scheduled to start after a mouse-button release.
    PendingPlaybackId := 42
    PendingPlaybackDeadline := A_TickCount + 5000
    StopPlayback()
    if (PendingPlaybackId != 0 || PendingPlaybackDeadline != 0)
        throw Error("F9 failed to cancel queued mouse-hotkey playback.")
    } catch as err {
        FileAppend(err.Message "`n" err.Stack, A_Temp "\\MouseMacro_core_test_error.log", "UTF-8")
        ExitApp(1)
    }
    ExitApp(0)
}

OnExit(ReleaseMouseGuard)
LoadAll()
BuildGui()
SetupTray()
InitWebInterface()

^!r::ToggleRecording()
^!Esc::CancelRecording()
F9::StopPlayback()

~*LButton::RecordClick("LButton")
~*RButton::RecordClick("RButton")
~*MButton::RecordClick("MButton")
~*WheelUp::RecordClick("WheelUp")
~*WheelDown::RecordClick("WheelDown")

; Mouse-key capture must stay active while the hotkey picker is open,
; even if a mouse driver briefly shifts focus away from WebView2.
#HotIf PickerOpen
*XButton1::OnWebSideButton("XButton1")
*XButton2::OnWebSideButton("XButton2")
*MButton::OnWebSideButton("MButton")
#HotIf

; Outside the picker, consume side buttons only while our window is active.
; Assigned global macro hotkeys remain usable in other applications.
#HotIf WebWindowIsActive() && !PickerOpen
*XButton1::OnWebSideButton("XButton1")
*XButton2::OnWebSideButton("XButton2")
*MButton::OnWebSideButton("MButton")
#HotIf

; Some mouse utilities generate browser-navigation keys rather than XButtons.
#HotIf WebWindowIsActive()
*Browser_Back::Return
*Browser_Forward::Return
#HotIf

WebWindowIsActive() {
    global WebGui
    return IsObject(WebGui) && WinActive("ahk_id " WebGui.Hwnd)
}

MouseHotkeyModifiers() {
    ; Include Win in captured combinations so protected Win+mouse shortcuts
    ; are rejected instead of silently being saved as a plain mouse button.
    return ((GetKeyState("LWin", "P") || GetKeyState("RWin", "P")) ? "#" : "")
        . (GetKeyState("Ctrl", "P") ? "^" : "")
        . (GetKeyState("Alt", "P") ? "!" : "")
        . (GetKeyState("Shift", "P") ? "+" : "")
}

OnWebSideButton(button) {
    global PickerOpen, IsRecording, IsPlaying, Macros, WebGui
    combo := MouseHotkeyModifiers() button
    if PickerOpen {
        ; Native AHK intercepts XButton before Chromium; send it to the key picker.
        try WebGui.PostWebMessageAsJson('{"type":"capturedHotkey","key":' WebJsonQuote(combo) '}')
        return
    }
    if (IsRecording || IsPlaying)
        return
    for macro in Macros {
        if (StrLower(macro.key) = StrLower(combo)) {
            PlayById(macro.id)
            return
        }
    }
    ; Without an assignment, pressing a side button INSIDE our window does nothing.
}

BuildGui() {
    global MainGui, MacroLV, StepLV, StatusText
    global BtnStart, BtnStop, BtnPlay, BtnRename, BtnRekey, BtnDelete, BtnDelay, BtnRemoveStep, BtnAddSteps, BtnSelectAllSteps
    global BtnImageClick, BtnWaitImage, BtnConfigureImage, BtnRepeat
    global MacroPanelTitle, TitleText, MacroInfoText, SelectionSummaryText, AddStepMenu
    global RecordMenu, BtnRecordDropdown, BtnCopy, BtnMoveUp, BtnMoveDown, RepeatEdit, RepeatSpin

    ; Native Windows controls are intentional: this light GUI follows the
    ; updated mockup without shipping a custom renderer or other dependencies.
    MainGui := Gui("-Resize", "MouseMacro — менеджер действий")
    MainGui.BackColor := "F5F7FA"
    MainGui.SetFont("s9 c17212C", "Segoe UI")

    fileMenu := Menu()
    fileMenu.Add("Новая запись", (*) => StartRecordingPrompt())
    fileMenu.Add("Сохранить запись", (*) => FinishRecording())
    fileMenu.Add("Отменить запись", (*) => CancelRecording())
    fileMenu.Add()
    fileMenu.Add("Выход", (*) => ExitManager())

    macroMenu := Menu()
    macroMenu.Add("Воспроизвести", (*) => PlaySelected())
    macroMenu.Add("Переименовать", (*) => RenameSelected())
    macroMenu.Add("Изменить горячую клавишу", (*) => RebindSelected())
    macroMenu.Add("Копировать макрос", (*) => CopySelected())
    macroMenu.Add("Удалить макрос", (*) => DeleteSelected())

    AddStepMenu := Menu()
    AddStepMenu.Add("Добавить записанные клики", (*) => AddStepsToSelected())
    AddStepMenu.Add("Ожидание изображения...", (*) => OpenImageEditor("wait_image"))

    serviceMenu := Menu()
    serviceMenu.Add("Добавить шаг...", (*) => ShowAddStepMenu())
    serviceMenu.Add("Изменить паузы...", (*) => EditDelay())
    serviceMenu.Add("Выделить все шаги", (*) => SelectAllSteps())
    serviceMenu.Add("Шаг вверх", (*) => MoveStep(-1))
    serviceMenu.Add("Шаг вниз", (*) => MoveStep(1))
    serviceMenu.Add("Настроить изображение...", (*) => EditImageStep())

    helpMenu := Menu()
    helpMenu.Add("Управление и подсказки", (*) => ShowHelp())
    bar := MenuBar()
    bar.Add("Файл", fileMenu)
    bar.Add("Макрос", macroMenu)
    bar.Add("Сервис", serviceMenu)
    bar.Add("Справка", helpMenu)
    MainGui.MenuBar := bar

    ; Toolbar: a compact 1:1 structural match for the reference.
    MainGui.AddText("x0 y0 w800 h51 BackgroundECF0F5")
    BtnStart := MainGui.AddButton("x14 y11 w131 h28", "🔴 Новая запись")
    BtnRecordDropdown := MainGui.AddButton("x145 y11 w25 h28", "▾")
    BtnPlay := MainGui.AddButton("x182 y11 w126 h28", "▶ Воспроизвести")
    MainGui.AddText("x321 y14 w1 h21 BackgroundCBD2DD")
    BtnRename := MainGui.AddButton("x332 y11 w116 h28", "✎ Переименовать")
    BtnRekey := MainGui.AddButton("x457 y11 w133 h28", "⌨ Сменить клавишу")
    MainGui.AddText("x604 y18 w70 h18 BackgroundTrans", "Повторы:")
    RepeatEdit := MainGui.AddEdit("x668 y12 w59 h25 Number Right", "1")
    RepeatSpin := MainGui.AddUpDown("Range1-1000", 1)
    BtnRepeat := RepeatSpin
    BtnStop := MainGui.AddButton("x0 y0 w1 h1 Hidden", "Сохранить запись")

    RecordMenu := Menu()
    RecordMenu.Add("Новая запись", (*) => StartRecordingPrompt())
    RecordMenu.Add("Добавить клики в выбранный макрос", (*) => AddStepsToSelected())
    RecordMenu.Add()
    RecordMenu.Add("Остановить и сохранить запись", (*) => FinishRecording())
    RecordMenu.Add("Отменить запись", (*) => CancelRecording())

    BtnStart.OnEvent("Click", (*) => StartRecordingPrompt())
    BtnRecordDropdown.OnEvent("Click", (*) => RecordMenu.Show())
    BtnPlay.OnEvent("Click", (*) => PlaySelected())
    BtnRename.OnEvent("Click", (*) => RenameSelected())
    BtnRekey.OnEvent("Click", (*) => RebindSelected())
    BtnStop.OnEvent("Click", (*) => FinishRecording())
    RepeatSpin.OnEvent("Change", OnRepeatChanged)
    RepeatEdit.OnEvent("LoseFocus", (*) => CommitRepeatEdit())

    ; Left side: saved macros and exactly three practical actions.
    MainGui.SetFont("s9 bold c19283A", "Segoe UI")
    MacroPanelTitle := MainGui.AddText("x14 y65 w265 h20 BackgroundTrans", "Макросы (0)")
    MainGui.SetFont("s9 c17212C", "Segoe UI")
    MacroLV := MainGui.AddListView("x14 y89 w283 h176 Grid -Multi NoSortHdr LV0x10000 BackgroundFFFFFF c142238", ["Название", "Клавиша", "Шагов"])
    MacroLV.ModifyCol(1, 158)
    MacroLV.ModifyCol(2, 72)
    MacroLV.ModifyCol(3, 50)
    MacroLV.OnEvent("ItemSelect", OnMacroSelected)
    MacroLV.OnEvent("DoubleClick", (*) => RenameSelected())
    TryStyleList(MacroLV)
    BtnMacroNew := MainGui.AddButton("x14 y276 w87 h27", "+ Добавить")
    BtnCopy := MainGui.AddButton("x108 y276 w87 h27", "⧉ Копировать")
    BtnDelete := MainGui.AddButton("x202 y276 w95 h27", "✕ Удалить")
    BtnMacroNew.OnEvent("Click", (*) => StartRecordingPrompt())
    BtnCopy.OnEvent("Click", (*) => CopySelected())
    BtnDelete.OnEvent("Click", (*) => DeleteSelected())

    ; Right side: actions, timing, and reorder arrows.
    MainGui.AddText("x314 y61 w1 h247 BackgroundD5DCE6")
    MainGui.SetFont("s9 bold c19283A", "Segoe UI")
    TitleText := MainGui.AddText("x327 y65 w440 h20 BackgroundTrans", "Шаги макроса: выбери макрос")
    MainGui.SetFont("s9 c17212C", "Segoe UI")
    MacroInfoText := MainGui.AddText("x327 y0 w1 h1 Hidden", "")
    StepLV := MainGui.AddListView("x327 y89 w438 h176 Grid NoSortHdr LV0x10000 BackgroundFFFFFF c142238", ["№", "Действие", "Пауза перед"])
    StepLV.ModifyCol(1, 38)
    StepLV.ModifyCol(2, 288)
    StepLV.ModifyCol(3, 108)
    StepLV.OnEvent("DoubleClick", (ctrl, row) => row ? EditDelay(row) : 0)
    TryStyleList(StepLV)
    BtnMoveUp := MainGui.AddButton("x771 y128 w25 h27", "▲")
    BtnMoveDown := MainGui.AddButton("x771 y160 w25 h27", "▼")
    BtnMoveUp.OnEvent("Click", (*) => MoveStep(-1))
    BtnMoveDown.OnEvent("Click", (*) => MoveStep(1))

    BtnAddSteps := MainGui.AddButton("x327 y276 w133 h27", "➤ Добавить клики")
    BtnWaitImage := MainGui.AddButton("x635 y276 w161 h27", "◷ Ждать изображение...")
    BtnDelay := MainGui.AddButton("x327 y310 w140 h27", "◷ Изменить паузы...")
    BtnRemoveStep := MainGui.AddButton("x476 y310 w114 h27", "✕ Удалить шаг")
    BtnSelectAllSteps := MainGui.AddButton("x598 y310 w88 h27", "Все шаги")
    BtnConfigureImage := MainGui.AddButton("x693 y310 w103 h27", "Настроить...")
    BtnAddSteps.OnEvent("Click", (*) => AddStepsToSelected())
    BtnWaitImage.OnEvent("Click", (*) => OpenImageEditor("wait_image"))
    BtnDelay.OnEvent("Click", (*) => EditDelay())
    BtnRemoveStep.OnEvent("Click", (*) => RemoveStep())
    BtnSelectAllSteps.OnEvent("Click", (*) => SelectAllSteps())
    BtnConfigureImage.OnEvent("Click", (*) => EditImageStep())
    SelectionSummaryText := MainGui.AddText("x15 y0 w1 h1 Hidden", "")

    ; Status bar: keep the existing status messages from the playback engine.
    MainGui.AddText("x0 y348 w800 h1 BackgroundD0D7E1")
    MainGui.AddText("x15 y359 w15 h20 c2DA44E BackgroundTrans", "●")
    StatusText := MainGui.AddText("x34 y358 w605 h23 BackgroundTrans", "Готово")
    MainGui.AddText("x645 y358 w145 h23 Right c5B6678 BackgroundTrans", "F9 — остановить")

    MainGui.OnEvent("Close", OnWindowClose)
    RefreshList()
    UpdateButtons()
    UpdateDashboard()
    MainGui.Show("Hide w810 h382")
}

ShowHelp(*) {
    MsgBox("Запись: Ctrl+Alt+R — начать/сохранить, Ctrl+Alt+Esc — отменить.`n"
        . "F9 — аварийная остановка макроса.`n`n"
        . "Щёлкай по строкам с Ctrl или Shift, чтобы выбрать несколько шагов; кнопка «Все шаги» выделяет все.`n"
        . "«Клик по изображению» ищет образец и нажимает на него, «Ждать изображение» ожидает появления образца.`n"
        . "Все макросы хранятся в MouseMacro.ini рядом со скриптом.",
        "MouseMacro — справка", "Iconi")
}

ShowAddStepMenu(*) {
    global AddStepMenu
    AddStepMenu.Show()
}

TryStyleList(ctrl) {
    ; Keep native Explorer appearance, as in the reference screenshot.
    try DllCall("uxtheme\SetWindowTheme", "ptr", ctrl.Hwnd, "str", "Explorer", "ptr", 0)
}

OnRepeatChanged(ctrl, *) {
    global UpdatingRepeat, IsRecording, IsPlaying, PickerOpen, StatusText
    if (UpdatingRepeat || IsRecording || IsPlaying || PickerOpen)
        return
    macro := GetSelected()
    if !IsObject(macro)
        return
    value := ctrl.Value
    if (value < 1 || value > 1000)
        return
    if (macro.repeat = value)
        return
    macro.repeat := value
    saved := TrySaveAll()
    StatusText.Text := saved ? "Повторов для «" macro.name "»: " value : "Не удалось сохранить повторы в файл."
}

CommitRepeatEdit(*) {
    global RepeatEdit, RepeatSpin, UpdatingRepeat
    if !IsObject(RepeatEdit)
        return
    raw := Trim(RepeatEdit.Value)
    if (RegExMatch(raw, "^\d+$") && (raw + 0) >= 1 && (raw + 0) <= 1000) {
        UpdatingRepeat := true
        RepeatSpin.Value := Floor(raw + 0)
        UpdatingRepeat := false
        OnRepeatChanged(RepeatSpin)
    } else {
        UpdateDashboard()
    }
}

UpdateDashboard() {
    global Macros, MacroPanelTitle, TitleText, MacroInfoText, SelectionSummaryText
    global RepeatSpin, RepeatEdit, UpdatingRepeat
    if IsObject(MacroPanelTitle)
        MacroPanelTitle.Text := "Макросы (" Macros.Length ")"
    macro := GetSelected()
    if !IsObject(macro) {
        if IsObject(TitleText)
            TitleText.Text := "Шаги макроса: выбери макрос"
        if IsObject(RepeatSpin) {
            UpdatingRepeat := true
            RepeatSpin.Value := 1
            UpdatingRepeat := false
        }
        return
    }
    repeatCount := HasProp(macro, "repeat") ? macro.repeat : 1
    if IsObject(TitleText)
        TitleText.Text := "Шаги макроса: " macro.name
    if IsObject(RepeatSpin) {
        UpdatingRepeat := true
        RepeatSpin.Value := repeatCount
        UpdatingRepeat := false
    }
}

SetupTray() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Открыть MouseMacro", ShowWindow)
    A_TrayMenu.Add()
    A_TrayMenu.Add("Выйти", ExitManager)
    A_TrayMenu.Default := "Открыть MouseMacro"
    A_TrayMenu.ClickCount := 2
    A_IconTip := "MouseMacro — действия мыши"
}

ShowWindow(*) {
    global WebGui
    global MainGui
    WebGui.Show()
    WinActivate("ahk_id " WebGui.Hwnd)
}

OnWindowClose(*) {
    ; GUI close callbacks must explicitly veto the default destroy when exit is refused.
    ExitManager()
    return 1
}

ExitManager(*) {
    global IsRecording, IsPlaying
    if IsPlaying {
        MsgBox("Сначала останови воспроизведение клавишей F9.", "MouseMacro")
        return
    }
    if IsRecording {
        result := MsgBox("Текущая запись не сохранена. Сохранить перед выходом?", "MouseMacro", "YesNoCancel Icon?")
        if (result = "Cancel")
            return
        if (result = "Yes") {
            if !FinishRecording()
                return
        } else {
            CancelRecording()
        }
    }
    ExitApp()
}

ToggleRecording(*) {
    global IsRecording
    if IsRecording
        FinishRecording()
    else
        StartRecordingPrompt()
}

StartRecordingPrompt(*) {
    global IsRecording, IsPlaying, PickerOpen
    if (IsRecording || IsPlaying || PickerOpen)
        return
    ShowKeyPicker("Выбери клавишу для нового действия", 0)
}

; Route native-menu and Ctrl+Alt+R commands into the same HTML hotkey picker.
; Gui.AddHotkey does not support XButton1/XButton2/MButton or many media keys.
PickerModeForTarget(targetId) {
    return targetId = 0 ? "new" : targetId = -1 ? "copy" : "rekey"
}

ShowKeyPicker(title, targetId, initialKey := "") {
    global WebGui, PickerOpen
    if PickerOpen
        return
    try {
        ShowWindow()
        ; The HTML picker calls WebAction("picker","on") and temporarily
        ; disables assigned hotkeys until the user confirms or cancels.
        WebGui.PostWebMessageAsJson('{"type":"openHotkeyPicker","mode":'
            . WebJsonQuote(PickerModeForTarget(targetId)) '}')
    } catch as err {
        MsgBox("Не удалось открыть окно выбора клавиши. " err.Message, "MouseMacro")
    }
}

CheckKey(key, skipId := 0) {
    global Macros
    key := Trim(String(key))
    if (key = "" || InStr(key, "#")) {
        MsgBox("Выбери клавишу или сочетание без Win. Системные клавиши Windows не переназначаются.", "MouseMacro")
        return false
    }
    ; Canonical modifier prefix (^ Ctrl, ! Alt, + Shift). Raw keys cannot
    ; contain AHK wildcard, pass-through, custom combo or key-up syntax.
    if !RegExMatch(key, "i)^([\^!+]*)([a-z0-9_]+)$", &parts) {
        MsgBox("Неизвестная клавиша или формат сочетания.", "MouseMacro")
        return false
    }
    mods := parts[1], base := parts[2]
    if (StrLen(mods) != (InStr(mods, "^") ? 1 : 0) + (InStr(mods, "!") ? 1 : 0) + (InStr(mods, "+") ? 1 : 0)) {
        MsgBox("Модификаторы Ctrl, Alt и Shift не должны повторяться.", "MouseMacro")
        return false
    }
    ctrl := InStr(mods, "^") != 0
    alt := InStr(mods, "!") != 0
    shift := InStr(mods, "+") != 0
    b := StrLower(base)
    allowed := RegExMatch(base, "i)^(?:F(?:[1-9]|1[0-9]|2[0-4])|[a-z0-9]|sc(?:0(?:0[CD]|1[AB]|27|28|29|2B|33|34|35|56))|Numpad(?:[0-9]|Add|Sub|Mult|Div|Dot|Enter|Del|Ins|Up|Down|Left|Right|Home|End|PgUp|PgDn|Clear)|XButton[12]|MButton|Wheel(?:Up|Down|Left|Right)|LButton|RButton|Space|Esc|Up|Down|Left|Right|Delete|Insert|Backspace|PgUp|PgDn|Home|End|Enter|Tab|CapsLock|ScrollLock|Pause|PrintScreen|AppsKey|Volume_(?:Up|Down|Mute)|Media_(?:Play_Pause|Stop|Prev|Next)|Browser_(?:Back|Forward|Refresh|Stop|Search|Favorites|Home))$")
    if !allowed {
        MsgBox("Эта клавиша не поддерживается для макросов.", "MouseMacro")
        return false
    }
    ; Reserve emergency controls, Windows shortcuts, application editing keys,
    ; and bare essential keys needed for normal mouse/keyboard use.
    protected := (b = "f9")
        || (ctrl && alt && (b = "r" || b = "esc" || b = "delete"))
        || (ctrl && shift && b = "esc")
        || (alt && (b = "tab" || b = "f4" || b = "esc" || b = "space"))
        || (ctrl && !alt && !shift && (b = "d" || b = "z"))
        || (!ctrl && !alt && !shift && (b = "esc" || b = "tab" || b = "enter" || b = "backspace" || b = "delete" || b = "space" || b = "capslock" || b = "scrolllock" || b = "printscreen" || b = "appskey" || b = "pause"))
        || (b = "lbutton" || b = "rbutton" || (InStr(b, "wheel") && !ctrl && !alt && !shift))
        || InStr(b, "browser_")
    if protected {
        MsgBox("Комбинация зарезервирована или помешает обычному управлению Windows. Выбери другую.", "MouseMacro")
        return false
    }
    for macro in Macros {
        if (macro.id != skipId && StrLower(macro.key) = StrLower(key)) {
            MsgBox("Клавиша уже назначена действию «" macro.name "». Выбери другую.", "MouseMacro")
            return false
        }
    }
    return true
}

BeginNewRecording(key) {
    global WebGui
    global Draft, NextId, IsRecording, LastRecordedAt, StatusText
    global RecordingTargetId, RecordingAfterStep
    global MainGui, PickerOpen
    if !CheckKey(key)
        return
    candidate := {id: NextId, name: "Действие " NextId, key: key, repeat: 1, events: []}
    try {
        Hotkey(key, PlayById.Bind(candidate.id), "On")
    } catch as err {
        MsgBox("Не удалось назначить клавишу «" key "».`n" err.Message, "MouseMacro")
        return
    }
    NextId += 1
    Draft := candidate
    RecordingTargetId := 0
    RecordingAfterStep := 0
    LastRecordedAt := A_TickCount
    IsRecording := true
    UpdateButtons()
    StatusText.Text := "ИДЁТ ЗАПИСЬ: " candidate.name " [" key "]. Нажимай мышью за пределами окна."
    ToolTip("Запись мыши: Ctrl+Alt+R — сохранить | Ctrl+Alt+Esc — отменить", 16, 16)
    WinMinimize("ahk_id " WebGui.Hwnd)
}

AddStepsToSelected(*) {
    global WebGui
    global IsRecording, IsPlaying, PickerOpen, Draft, LastRecordedAt
    global RecordingTargetId, RecordingAfterStep, StatusText, MainGui, StepLV
    if (IsRecording || IsPlaying || PickerOpen)
        return
    macro := GetSelected()
    if !IsObject(macro)
        return

    ; No change is made to the saved macro until recording is completed.
    selectedRow := StepLV.GetNext()
    if (selectedRow && StepLV.GetNext(selectedRow)) {
        MsgBox("Для добавления действий выбери один шаг или сними выделение, чтобы добавить в конец.", "MouseMacro")
        return
    }
    RecordingTargetId := macro.id
    RecordingAfterStep := selectedRow ? selectedRow : macro.events.Length
    Draft := {id: macro.id, name: macro.name, key: macro.key, events: []}
    LastRecordedAt := A_TickCount
    IsRecording := true
    UpdateButtons()
    insertHint := (RecordingAfterStep = macro.events.Length) ? "в конец" : "после шага №" RecordingAfterStep
    StatusText.Text := "ДОЗАПИСЬ «" macro.name "» (" insertHint "). Ctrl+Alt+R — сохранить."
    ToolTip("Добавление действий мыши: Ctrl+Alt+R — сохранить | Ctrl+Alt+Esc — отменить", 16, 16)
    WinMinimize("ahk_id " WebGui.Hwnd)
}

RecordClick(button) {
    global WebGui
    global IsRecording, IsPlaying, Draft, LastRecordedAt, MainGui
    ; Prevent the save/cancel hotkeys from changing Draft during this click handler.
    Critical()
    if (!IsRecording || IsPlaying || !IsObject(Draft))
        return
    ; Repair a missing event list rather than crashing on Draft.events.Push().
    if !HasProp(Draft, "events")
        Draft.events := []

    MouseGetPos(&x, &y, &windowId)
    if (windowId = MainGui.Hwnd || windowId = WebGui.Hwnd)
        return
    ; Restoring the minimized manager from the Windows taskbar is not a macro step.
    if windowId {
        try {
            windowClass := WinGetClass("ahk_id " windowId)
            if (windowClass = "Shell_TrayWnd" || windowClass = "Shell_SecondaryTrayWnd")
                return
        }
    }

    now := A_TickCount
    delay := Max(0, now - LastRecordedAt)
    if (button = "WheelUp" || button = "WheelDown")
        Draft.events.Push({type: "wheel", delay: delay, button: button, x: x, y: y})
    else
        Draft.events.Push({delay: delay, button: button, x: x, y: y})
    LastRecordedAt := now
    if (Draft.events.Length >= 10000) {
        Critical("Off")
        FinishRecording()
    }
}

FinishRecording(*) {
    global WebGui
    global Draft, IsRecording, Macros, MainGui, StatusText, SelectedId, StepLV
    global RecordingTargetId, RecordingAfterStep
    if !IsRecording
        return

    targetId := RecordingTargetId
    insertAfter := RecordingAfterStep
    IsRecording := false
    ToolTip()
    WinRestore("ahk_id " WebGui.Hwnd)
    if (Draft.events.Length = 0) {
        if (targetId = 0)
            try Hotkey(Draft.key, "Off")
        Draft := ""
        RecordingTargetId := 0
        RecordingAfterStep := 0
        UpdateButtons()
        StatusText.Text := targetId ? "Новых действий мыши нет — макрос не изменился." : "Запись пустая — действие не создано."
        WebGui.Show()
        return true
    }

    savedId := Draft.id
    savedCount := Draft.events.Length
    before := ""
    if targetId {
        macro := FindById(targetId)
        if !IsObject(macro) {
            Draft := ""
            RecordingTargetId := 0
            RecordingAfterStep := 0
            UpdateButtons()
            WebGui.Show()
            MsgBox("Действие для дозаписи больше не найдено.", "MouseMacro")
            return false
        }
        ; Insert added clicks after the step selected when recording began.
        ; Original steps, hotkey and any custom delays remain unchanged.
        before := CloneMacroSteps(macro.events)
        insertIndex := Min(insertAfter, macro.events.Length) + 1
        for event in Draft.events {
            macro.events.InsertAt(insertIndex, event)
            insertIndex += 1
        }
    } else {
        Macros.Push(Draft)
    }

    Draft := ""
    RecordingTargetId := 0
    RecordingAfterStep := 0
    SelectedId := savedId
    wasSaved := targetId ? CommitStepChange(FindById(targetId), before) : TrySaveAll()
    if (!wasSaved && !targetId) {
        ; The unsaved newly created hotkey must not stay registered.
        for index, entry in Macros {
            if (entry.id = savedId) {
                try Hotkey(entry.key, "Off")
                Macros.RemoveAt(index)
                break
            }
        }
    }
    RefreshList(wasSaved ? savedId : (targetId ? savedId : 0))
    if (targetId && insertAfter + 1 <= FindById(savedId).events.Length)
        StepLV.Modify(insertAfter + 1, "Select Focus Vis")
    UpdateButtons()
    if wasSaved {
        if targetId
            StatusText.Text := "Добавлено " savedCount " шагов в «" FindById(savedId).name "». Старые шаги сохранены."
        else
            StatusText.Text := "Сохранено действие с " savedCount " шагами. Можно менять название, клавишу и паузы."
    } else {
        StatusText.Text := "Не удалось сохранить запись. Изменения отменены, проверь доступность MouseMacro.ini."
    }
    WebGui.Show()
    return wasSaved
}

CancelRecording(*) {
    global WebGui
    global IsRecording, Draft, MainGui, StatusText
    global RecordingTargetId, RecordingAfterStep
    if !IsRecording
        return
    wasAdding := RecordingTargetId != 0
    IsRecording := false
    ToolTip()
    if !wasAdding
        try Hotkey(Draft.key, "Off")
    Draft := ""
    RecordingTargetId := 0
    RecordingAfterStep := 0
    WinRestore("ahk_id " WebGui.Hwnd)
    WebGui.Show()
    UpdateButtons()
    if wasAdding
        StatusText.Text := "Дозапись отменена — существующее действие не изменилось."
    else
        StatusText.Text := "Запись отменена, сохранённые действия не изменились."
}

OnMacroSelected(ctrl, row, selected) {
    global RefreshingList, Macros, SelectedId
    if (RefreshingList || !selected || row < 1 || row > Macros.Length)
        return
    SelectedId := Macros[row].id
    RefreshSteps()
    UpdateButtons()
    UpdateDashboard()
}

RefreshList(preferredId := 0) {
    global Macros, MacroLV, SelectedId, RefreshingList
    RefreshingList := true
    MacroLV.Opt("-Redraw")
    MacroLV.Delete()
    selectedRow := 0
    for index, macro in Macros {
        MacroLV.Add(, macro.name, macro.key, macro.events.Length)
        if (macro.id = preferredId || (preferredId = 0 && macro.id = SelectedId))
            selectedRow := index
    }
    if (selectedRow = 0 && Macros.Length > 0)
        selectedRow := 1
    if selectedRow {
        SelectedId := Macros[selectedRow].id
        MacroLV.Modify(selectedRow, "Select Focus Vis")
    } else {
        SelectedId := 0
    }
    MacroLV.Opt("+Redraw")
    RefreshingList := false
    RefreshSteps()
    UpdateButtons()
    UpdateDashboard()
}

RefreshSteps() {
    global StepLV
    if !IsObject(StepLV)
        return
    StepLV.Opt("-Redraw")
    StepLV.Delete()
    macro := GetSelected()
    if IsObject(macro) {
        for index, event in macro.events {
            kind := StepKind(event)
            if (kind = "click") {
                StepLV.Add(, index, ButtonLabel(event.button) " кнопка: X=" event.x "  Y=" event.y, event.delay " мс")
            } else if (kind = "wheel") {
                direction := (event.button = "WheelUp") ? "вверх" : "вниз"
                StepLV.Add(, index, "Прокрутка " direction ": X=" event.x "  Y=" event.y, event.delay " мс")
            } else {
                SplitPath(event.image, &imageName)
                actionName := (kind = "image_click") ? "Картинка → " ButtonLabel(event.button) : "Ждать картинку"
                StepLV.Add(, index, (kind = "image_click" ? "Клик по изображению: " : "Ждать изображение: ") imageName (kind = "wait_image" ? " (до " event.timeout " мс)" : ""), event.delay " мс")
            }
        }
    }
    StepLV.Opt("+Redraw")
    UpdateDashboard()
}

ButtonLabel(button) {
    if (button = "LButton")
        return "Левая"
    if (button = "RButton")
        return "Правая"
    return "Средняя"
}

GetSelected() {
    global Macros, SelectedId
    for macro in Macros {
        if (macro.id = SelectedId)
            return macro
    }
    return ""
}

FindById(id) {
    global Macros
    for macro in Macros {
        if (macro.id = id)
            return macro
    }
    return ""
}

UpdateButtons() {
    global IsRecording, IsPlaying, PickerOpen, SelectedId
    global BtnStart, BtnStop, BtnPlay, BtnRename, BtnRekey, BtnDelete, BtnDelay, BtnRemoveStep, BtnAddSteps, BtnSelectAllSteps
    global BtnImageClick, BtnWaitImage, BtnConfigureImage, BtnRepeat, BtnRecordDropdown, BtnCopy, BtnMoveUp, BtnMoveDown
    if !IsObject(BtnStart)
        return
    available := (SelectedId != 0 && !IsRecording && !IsPlaying && !PickerOpen)
    BtnStart.Enabled := (!IsRecording && !IsPlaying && !PickerOpen)
    BtnStop.Enabled := IsRecording
    BtnPlay.Enabled := available
    BtnRename.Enabled := available
    BtnRekey.Enabled := available
    BtnDelete.Enabled := available
    BtnDelay.Enabled := available
    BtnRemoveStep.Enabled := available
    BtnAddSteps.Enabled := available
    BtnSelectAllSteps.Enabled := available
    if IsObject(BtnImageClick)
        BtnImageClick.Enabled := available
    if IsObject(BtnWaitImage)
        BtnWaitImage.Enabled := available
    BtnConfigureImage.Enabled := available
    BtnRepeat.Enabled := available
    BtnRecordDropdown.Enabled := (!IsPlaying && !PickerOpen)
    BtnCopy.Enabled := available
    BtnMoveUp.Enabled := available
    BtnMoveDown.Enabled := available
    UpdateDashboard()
}

RenameSelected(*) {
    global IsRecording, IsPlaying, PickerOpen, StatusText
    if (IsRecording || IsPlaying || PickerOpen)
        return
    macro := GetSelected()
    if !IsObject(macro)
        return
    answer := InputBox("Название действия:", "Переименовать", "w400 h135", macro.name)
    if (answer.Result != "OK")
        return
    newName := Trim(answer.Value)
    if (newName = "") {
        MsgBox("Название не может быть пустым.", "MouseMacro")
        return
    }
    macro.name := newName
    TrySaveAll()
    RefreshList(macro.id)
    StatusText.Text := "Действие переименовано."
}

RebindSelected(*) {
    global IsRecording, IsPlaying, PickerOpen
    if (IsRecording || IsPlaying || PickerOpen)
        return
    macro := GetSelected()
    if IsObject(macro)
        ShowKeyPicker("Переназначить клавишу", macro.id, macro.key)
}

ApplyNewKey(id, newKey) {
    global StatusText
    macro := FindById(id)
    if !IsObject(macro)
        return
    if (StrLower(newKey) = StrLower(macro.key))
        return
    try {
        Hotkey(newKey, PlayById.Bind(id), "On")
    } catch as err {
        MsgBox("Не удалось назначить «" newKey "».`n" err.Message, "MouseMacro")
        return
    }
    previousKey := macro.key
    try Hotkey(previousKey, "Off")
    macro.key := newKey
    saved := TrySaveAll()
    if !saved {
        macro.key := previousKey
        try Hotkey(newKey, "Off")
        try Hotkey(previousKey, "On")
    }
    RefreshList(id)
    StatusText.Text := saved ? "Новая клавиша действия «" macro.name "»: " newKey
        : "Клавиша не изменена: не удалось сохранить INI."
}

DeleteSelected(*) {
    global IsRecording, IsPlaying, PickerOpen, Macros, SelectedId, StatusText
    if (IsRecording || IsPlaying || PickerOpen)
        return
    macro := GetSelected()
    if !IsObject(macro)
        return
    if (MsgBox("Удалить действие «" macro.name "» вместе со всеми шагами?", "MouseMacro", "YesNo Icon?") != "Yes")
        return
    removedAt := 0
    for index, item in Macros {
        if (item.id = macro.id) {
            removedAt := index
            break
        }
    }
    if !removedAt
        return
    try Hotkey(macro.key, "Off")
    Macros.RemoveAt(removedAt)
    SelectedId := 0
    saved := TrySaveAll()
    if !saved {
        Macros.InsertAt(removedAt, macro)
        SelectedId := macro.id
        try Hotkey(macro.key, "On")
    }
    RefreshList(saved ? 0 : macro.id)
    StatusText.Text := saved ? "Действие удалено." : "Удаление отменено: сохранить INI не удалось."
}

CopySelected(*) {
    global IsRecording, IsPlaying, PickerOpen, PendingCopyId
    if (IsRecording || IsPlaying || PickerOpen)
        return
    macro := GetSelected()
    if !IsObject(macro)
        return
    PendingCopyId := macro.id
    ShowKeyPicker("Горячая клавиша для копии", -1)
}

CommitCopy(key) {
    global PendingCopyId, Macros, NextId, SelectedId, StatusText
    original := FindById(PendingCopyId)
    PendingCopyId := 0
    if !IsObject(original)
        return
    copiedEvents := []
    for event in original.events
        copiedEvents.Push(event.Clone())
    copy := {id: NextId, name: original.name " (копия)", key: key,
        repeat: (HasProp(original, "repeat") ? original.repeat : 1), events: copiedEvents}
    try {
        Hotkey(key, PlayById.Bind(copy.id), "On")
    } catch as err {
        MsgBox("Не удалось назначить клавишу «" key "».`n" err.Message, "MouseMacro")
        return
    }
    NextId += 1
    Macros.Push(copy)
    SelectedId := copy.id
    saved := TrySaveAll()
    if !saved {
        try Hotkey(key, "Off")
        Macros.Pop()
        NextId -= 1
        SelectedId := original.id
    }
    RefreshList(saved ? copy.id : original.id)
    StatusText.Text := saved ? "Создана копия макроса: " copy.name : "Копирование отменено: не удалось сохранить INI."
}


; Step snapshots are independent clones: editing a delay must never modify undo history.
CloneMacroSteps(events) {
    result := []
    for event in events
        result.Push(event.Clone())
    return result
}

CommitStepChange(macro, previousSteps) {
    global StepUndoHistory
    if !TrySaveAll() {
        ; Never keep an edit in memory if the INI write failed.
        macro.events := previousSteps
        RefreshSteps()
        return false
    }
    StepUndoHistory.Push({id: macro.id, events: previousSteps})
    ; Keep memory predictable even for lengthy recordings.
    if (StepUndoHistory.Length > 10)
        StepUndoHistory.RemoveAt(1)
    return true
}

UndoStepChange(*) {
    global StepUndoHistory, IsRecording, IsPlaying, PickerOpen, SelectedId, StepLV
    if (IsRecording || IsPlaying || PickerOpen)
        return
    while StepUndoHistory.Length {
        change := StepUndoHistory[StepUndoHistory.Length]
        macro := FindById(change.id)
        if !IsObject(macro) {
            StepUndoHistory.Pop()
            continue
        }
        current := CloneMacroSteps(macro.events)
        macro.events := CloneMacroSteps(change.events)
        if !TrySaveAll() {
            macro.events := current
            RefreshSteps()
            WebReport("Не удалось отменить действие: сохранение INI завершилось ошибкой.")
            return
        }
        StepUndoHistory.Pop()
        SelectedId := macro.id
        RefreshList(macro.id)
        if StepLV.GetCount()
            StepLV.Modify(1, "Select Focus Vis")
        WebReport("Последнее изменение шагов отменено.")
        return
    }
    WebReport("Нет изменений шагов для отмены.")
}

DuplicateSelectedSteps(*) {
    global IsRecording, IsPlaying, PickerOpen, StepLV
    if (IsRecording || IsPlaying || PickerOpen)
        return
    macro := GetSelected()
    if !IsObject(macro)
        return
    rows := []
    row := 0
    while (row := StepLV.GetNext(row))
        rows.Push(row)
    if !rows.Length {
        WebReport("Сначала выдели один или несколько шагов для дублирования.")
        return
    }
    if (macro.events.Length + rows.Length > 10000) {
        WebReport("Превышено ограничение 10000 шагов на макрос.")
        return
    }
    before := CloneMacroSteps(macro.events)
    insertion := rows[rows.Length] + 1
    for row in rows {
        macro.events.InsertAt(insertion, macro.events[row].Clone())
        insertion += 1
    }
    if !CommitStepChange(macro, before) {
        WebReport("Не удалось сохранить копии шагов. Изменения отменены.")
        return
    }
    RefreshList(macro.id)
    StepLV.Modify(0, "-Select")
    Loop rows.Length
        StepLV.Modify(rows[rows.Length] + A_Index, "Select" (A_Index = 1 ? " Focus Vis" : ""))
    WebReport("Дублировано шагов: " rows.Length ". Копии добавлены после последнего выделенного шага.")
}

MoveStep(direction) {
    global IsRecording, IsPlaying, PickerOpen, StepLV, StatusText
    if (IsRecording || IsPlaying || PickerOpen)
        return
    macro := GetSelected()
    if !IsObject(macro)
        return
    row := StepLV.GetNext()
    if (!row || StepLV.GetNext(row)) {
        MsgBox("Для перемещения выбери ровно один шаг.", "MouseMacro")
        return
    }
    targetRow := row + direction
    if (targetRow < 1 || targetRow > macro.events.Length)
        return
    before := CloneMacroSteps(macro.events)
    item := macro.events[row]
    macro.events[row] := macro.events[targetRow]
    macro.events[targetRow] := item
    saved := CommitStepChange(macro, before)
    RefreshSteps()
    StepLV.Modify(saved ? targetRow : row, "Select Focus Vis")
    StatusText.Text := saved ? "Шаг перемещён. Его задержка перемещена вместе с ним." : "Не удалось сохранить перемещение — изменение отменено."
}

; New image commands are implemented with native AutoHotkey v2 ImageSearch,
; not with code or binary components from Pulover's Macro Creator.
StepKind(event) {
    return HasProp(event, "type") ? event.type : "click"
}

ConfigureRepeats(*) {
    global IsRecording, IsPlaying, PickerOpen, StatusText
    if (IsRecording || IsPlaying || PickerOpen)
        return
    macro := GetSelected()
    if !IsObject(macro)
        return
    oldCount := HasProp(macro, "repeat") ? macro.repeat : 1
    answer := InputBox("Сколько раз выполнять ВСЮ последовательность?`nОт 1 до 1000. F9 — досрочная остановка.",
        "Повторы действия", "w410 h160", oldCount)
    if (answer.Result != "OK")
        return
    newCount := Trim(answer.Value)
    if (!RegExMatch(newCount, "^\d+$") || newCount + 0 < 1 || newCount + 0 > 1000) {
        MsgBox("Укажи целое число от 1 до 1000.", "MouseMacro")
        return
    }
    macro.repeat := Floor(newCount + 0)
    saved := TrySaveAll()
    RefreshList(macro.id)
    StatusText.Text := saved ? "Повторов для «" macro.name "»: " macro.repeat : "Повторы изменены в памяти, но не сохранены."
}

; Add a new image step immediately after the only selected row, or at the end.
; Existing event data and its timing remain unchanged.
OpenImageEditor(kind, row := 0) {
    global WebGui
    global MainGui, PickerOpen, IsRecording, IsPlaying, StepLV
    if (PickerOpen || IsRecording || IsPlaying)
        return
    macro := GetSelected()
    if !IsObject(macro)
        return
    if (kind != "wait_image")
        return

    original := ""
    if row {
        if (row > macro.events.Length || StepKind(macro.events[row]) != kind)
            return
        original := macro.events[row]
    } else {
        selection := StepLV.GetNext()
        if (selection && StepLV.GetNext(selection)) {
            MsgBox("Выбери один шаг для вставки после него или сними выделение для вставки в конец.", "MouseMacro")
            return
        }
    }
    insertAfter := row ? 0 : StepLV.GetNext()
    PickerOpen := true
    UpdateButtons()

    title := kind = "image_click" ? "Клик по изображению" : "Ожидание изображения"
    dlg := Gui("+Owner" WebGui.Hwnd, title)
    dlg.BackColor := "F5F7FA"
    dlg.SetFont("s9 c17212C", "Segoe UI")
    dlg.AddText("x16 y14 w440 h19", "Файл изображения:")
    pathCtrl := dlg.AddEdit("x16 y39 w334 h25", IsObject(original) ? original.image : "")
    chooseBtn := dlg.AddButton("x358 y38 w96 h27", "Обзор...")

    dlg.AddText("x16 y75 w438 h64 BackgroundE8EDF4")
    previewText := dlg.AddText("x119 y94 w325 h30 BackgroundTrans c56657D",
        "Предпросмотр выбранного образца PNG, BMP или JPG")
    previewState := {picture: "", label: previewText}
    chooseBtn.OnEvent("Click", (*) => BrowseTemplate(pathCtrl, dlg, previewState))
    pathCtrl.OnEvent("LoseFocus", (*) => UpdateImagePreview(dlg, previewState, pathCtrl.Value))

    dlg.AddText("x16 y153 w215 h18", "Максимальное ожидание, мс:")
    timeoutCtrl := dlg.AddEdit("x16 y176 w116 h25 Number", IsObject(original) ? original.timeout : (kind = "image_click" ? 0 : 10000))
    dlg.AddText("x138 y181 w84 h18 c627087", "0–60000")
    dlg.AddText("x242 y153 w212 h18", "Допуск различий цвета:")
    variationCtrl := dlg.AddEdit("x242 y176 w87 h25 Number", IsObject(original) ? original.variation : 0)
    dlg.AddText("x336 y181 w92 h18 c627087", "0–255")

    buttonCtrl := ""
    if (kind = "image_click") {
        dlg.AddText("x16 y213 w210 h18", "Кнопка мыши:")
        buttonCtrl := dlg.AddDropDownList("x16 y235 w185", ["Левая", "Правая", "Средняя"])
        oldButton := IsObject(original) ? original.button : "LButton"
        buttonCtrl.Choose(oldButton = "RButton" ? 2 : oldButton = "MButton" ? 3 : 1)
    }
    hint := kind = "image_click" ? "Если образец не найден — пропустить клик." : "Если образец не появился вовремя — остановить макрос."
    dlg.AddText("x16 y273 w438 h37 c42648A BackgroundEAF2FE", "  " hint)
    saveBtn := dlg.AddButton("x245 y323 w111 h29 Default", "Сохранить")
    cancelBtn := dlg.AddButton("x365 y323 w89 h29", "Отмена")
    saveBtn.OnEvent("Click", (*) => CommitImageStep(dlg, macro.id, kind, row, insertAfter,
        pathCtrl, timeoutCtrl, variationCtrl, buttonCtrl))
    cancelBtn.OnEvent("Click", (*) => CloseImageEditor(dlg))
    dlg.OnEvent("Close", (*) => CloseImageEditor(dlg))
    dlg.OnEvent("Escape", (*) => CloseImageEditor(dlg))
    dlg.Show("w470 h365 Center")
    if IsObject(original)
        UpdateImagePreview(dlg, previewState, original.image)
}

UpdateImagePreview(dlg, previewState, candidate) {
    full := ResolveTemplatePath(Trim(candidate, ' "'))
    if (full = "" || !FileExist(full)) {
        previewState.label.Text := "Файл не выбран или не найден"
        if IsObject(previewState.picture)
            previewState.picture.Visible := false
        return
    }
    SplitPath(full, &filename, , &ext)
    if !InStr("|png|bmp|jpg|jpeg|", "|" StrLower(ext) "|") {
        previewState.label.Text := "Поддерживаются PNG, BMP и JPG"
        if IsObject(previewState.picture)
            previewState.picture.Visible := false
        return
    }
    previewState.label.Text := filename "`nОбразец будет сохранён рядом со скриптом"
    try {
        if IsObject(previewState.picture) {
            previewState.picture.Value := "*w86 *h50 " full
            previewState.picture.Visible := true
        } else {
            previewState.picture := dlg.AddPicture("x24 y81 w86 h50", full)
        }
    }
}

EditImageStep(*) {
    global IsRecording, IsPlaying, PickerOpen, StepLV
    if (IsRecording || IsPlaying || PickerOpen)
        return
    macro := GetSelected()
    if !IsObject(macro)
        return
    row := StepLV.GetNext()
    if (!row || StepLV.GetNext(row)) {
        MsgBox("Выбери ровно один шаг с картинкой, чтобы изменить его настройки.", "MouseMacro")
        return
    }
    kind := StepKind(macro.events[row])
    if (kind = "click" || kind = "wheel") {
        MsgBox("Для кликов и прокрутки используй редактор шага в главном окне.", "MouseMacro")
        return
    }
    OpenImageEditor(kind, row)
}

BrowseTemplate(pathCtrl, dlg := "", previewState := "") {
    ; 1 = existing file, single selection; 3 would allow multiple files.
    chosen := FileSelect(1, , "Выбрать изображение кнопки", "Изображения (*.png; *.bmp; *.jpg; *.jpeg)")
    if (chosen != "") {
        pathCtrl.Value := chosen
        if IsObject(dlg) && IsObject(previewState)
            UpdateImagePreview(dlg, previewState, chosen)
    }
}

CloseImageEditor(dlg) {
    global PickerOpen
    if !PickerOpen
        return
    PickerOpen := false
    dlg.Destroy()
    UpdateButtons()
}

CommitImageStep(dlg, macroId, kind, row, insertAfter, pathCtrl, timeoutCtrl, variationCtrl, buttonCtrl) {
    global StatusText, StepLV
    macro := FindById(macroId)
    if !IsObject(macro)
        return
    rawPath := Trim(pathCtrl.Value, ' "')
    timeoutText := Trim(timeoutCtrl.Value)
    variationText := Trim(variationCtrl.Value)
    if (!RegExMatch(timeoutText, "^\d+$") || (timeoutText + 0) > 60000) {
        MsgBox("Ожидание должно быть целым числом от 0 до 60000 мс.", "MouseMacro")
        return
    }
    if (!RegExMatch(variationText, "^\d+$") || (variationText + 0) > 255) {
        MsgBox("Допуск цвета должен быть целым числом от 0 до 255.", "MouseMacro")
        return
    }
    sourcePath := ResolveTemplatePath(rawPath)
    if (sourcePath = "" || !FileExist(sourcePath)) {
        MsgBox("Файл картинки не найден. Выбери существующий PNG, BMP или JPG.", "MouseMacro")
        return
    }
    SplitPath(sourcePath, , , &ext)
    if !InStr("|png|bmp|jpg|jpeg|", "|" StrLower(ext) "|") {
        MsgBox("Для образца выбери PNG, BMP или JPG.", "MouseMacro")
        return
    }
    ; Validate the image before copying it or modifying the saved macro.
    try {
        imageSize := GetTemplateSize(sourcePath)
    } catch as err {
        MsgBox("Не удалось прочитать изображение:`n" err.Message, "MouseMacro")
        return
    }
    if (imageSize.w < 1 || imageSize.h < 1) {
        MsgBox("Неверный размер изображения.", "MouseMacro")
        return
    }
    original := row ? macro.events[row] : ""
    if (IsObject(original) && ResolveTemplatePath(original.image) = sourcePath) {
        storedPath := original.image
    } else {
        try storedPath := StoreTemplate(sourcePath)
        catch as err {
            MsgBox("Не удалось сохранить образец рядом со скриптом:`n" err.Message, "MouseMacro")
            return
        }
    }
    delay := row ? original.delay : 0
    action := {type: kind, delay: delay, image: storedPath,
        timeout: Floor(timeoutText + 0), variation: Floor(variationText + 0)}
    if (kind = "image_click")
        action.button := ["LButton", "RButton", "MButton"][buttonCtrl.Value]
    if row {
        macro.events[row] := action
        modifiedRow := row
    } else {
        modifiedRow := insertAfter ? insertAfter + 1 : macro.events.Length + 1
        macro.events.InsertAt(modifiedRow, action)
    }
    CloseImageEditor(dlg)
    saved := TrySaveAll()
    RefreshList(macro.id)
    StepLV.Modify(modifiedRow, "Select Focus Vis")
    StatusText.Text := saved ? "Шаг с поиском изображения сохранён. F9 — остановка макроса."
        : "Шаг добавлен в память, но не сохранён на диск."
}

ResolveTemplatePath(path) {
    if (path = "")
        return ""
    ; Absolute Windows paths (including UNC) are supported for legacy and manual input.
    if RegExMatch(path, "i)^[a-z]:\\|^\\\\")
        return path
    return A_ScriptDir "\" path
}

StoreTemplate(sourcePath) {
    targetDir := A_ScriptDir "\MouseMacro_Images"
    if !DirExist(targetDir)
        DirCreate(targetDir)
    SplitPath(sourcePath, , , &ext)
    ; Keep a local copy so the original picture may be deleted or moved later.
    Loop 100 {
        name := "sample_" A_NowUTC "_" A_TickCount "_" A_Index "." StrLower(ext)
        targetPath := targetDir "\" name
        if !FileExist(targetPath) {
            FileCopy(sourcePath, targetPath)
            return "MouseMacro_Images\" name
        }
    }
    throw Error("Не удалось подобрать уникальное имя файла изображения.")
}

; LoadPicture returns an HBITMAP when no OutImageType is supplied.
GetTemplateSize(path) {
    hBitmap := LoadPicture(path)
    if !hBitmap
        throw Error("Не удалось загрузить " path)
    try {
        bm := Buffer(32, 0)
        if !DllCall("GetObjectW", "Ptr", hBitmap, "Int", bm.Size, "Ptr", bm, "Int")
            throw Error("Не удалось получить размер картинки.")
        return {w: NumGet(bm, 4, "Int"), h: NumGet(bm, 8, "Int")}
    } finally {
        DllCall("DeleteObject", "Ptr", hBitmap)
    }
}

SelectAllSteps(*) {
    global IsRecording, IsPlaying, PickerOpen, StepLV, StatusText
    if (IsRecording || IsPlaying || PickerOpen || StepLV.GetCount() = 0)
        return
    StepLV.Modify(0, "Select")
    StatusText.Text := "Выделены все шаги. Нажми «Изменить паузы», чтобы установить общую задержку."
}

EditDelay(row := 0) {
    global WebGui
    global IsRecording, IsPlaying, PickerOpen, StepLV
    if (IsRecording || IsPlaying || PickerOpen)
        return
    macro := GetSelected()
    if !IsObject(macro)
        return

    rows := []
    if (row > 0) {
        if (row > macro.events.Length)
            return
        rows.Push(row)
    } else {
        selectedRow := 0
        while (selectedRow := StepLV.GetNext(selectedRow))
            rows.Push(selectedRow)
    }
    if (rows.Length = 0) {
        MsgBox("Выбери один или несколько шагов в таблице. Можно использовать Ctrl или Shift.", "MouseMacro")
        return
    }

    firstDelay := macro.events[rows[1]].delay
    shared := true
    for selectedRow in rows {
        if (macro.events[selectedRow].delay != firstDelay) {
            shared := false
            break
        }
    }
    PickerOpen := true
    UpdateButtons()
    dlg := Gui("+Owner" WebGui.Hwnd, "Изменить паузу")
    dlg.BackColor := "F5F7FA"
    dlg.SetFont("s9 c17212C", "Segoe UI")
    dlg.AddText("x18 y17 w335 h22", rows.Length = 1
        ? "Пауза ПЕРЕД шагом №" rows[1] ":" : "Общая пауза ПЕРЕД " rows.Length " выбранными шагами:")
    delayInput := dlg.AddEdit("x18 y47 w130 h27 Number", shared ? firstDelay : "")
    dlg.AddUpDown("Range0-600000", shared ? firstDelay : 0)
    dlg.AddText("x166 y52 w45 h18", "мс")
    dlg.AddText("x18 y85 w336 h36 c627087", "1000 мс = 1 секунда. Допустимые значения: 0–600000.")
    if !shared
        dlg.AddText("x18 y116 w336 h22 c42648A", "У выделенных шагов разные паузы. Введи новое значение.")
    apply := dlg.AddButton("x162 y153 w96 h28 Default", "Применить")
    cancel := dlg.AddButton("x267 y153 w86 h28", "Отмена")
    apply.OnEvent("Click", (*) => ApplyDelayEditor(dlg, macro.id, rows, delayInput))
    cancel.OnEvent("Click", (*) => CloseDelayEditor(dlg))
    dlg.OnEvent("Close", (*) => CloseDelayEditor(dlg))
    dlg.OnEvent("Escape", (*) => CloseDelayEditor(dlg))
    dlg.Show("w370 h197 Center")
}

CloseDelayEditor(dlg) {
    global PickerOpen
    if !PickerOpen
        return
    PickerOpen := false
    dlg.Destroy()
    UpdateButtons()
}

ApplyDelayEditor(dlg, macroId, rows, input) {
    global StatusText, StepLV
    macro := FindById(macroId)
    if !IsObject(macro)
        return
    raw := Trim(input.Value)
    if (!RegExMatch(raw, "^\d+$") || (raw + 0) > 600000) {
        MsgBox("Введи целое число от 0 до 600000 миллисекунд.", "MouseMacro")
        return
    }
    newDelay := Floor(raw + 0)
    for row in rows {
        macro.events[row].delay := newDelay
        StepLV.Modify(row, "Col3", newDelay " мс")
    }
    CloseDelayEditor(dlg)
    saved := TrySaveAll()
    StatusText.Text := saved
        ? "Пауза перед " rows.Length " шаг(ами) установлена на " newDelay " мс."
        : "Паузы изменены в памяти, но не сохранены в MouseMacro.ini."
}

RemoveStep(*) {
    global IsRecording, IsPlaying, PickerOpen, StepLV, StatusText
    if (IsRecording || IsPlaying || PickerOpen)
        return
    macro := GetSelected()
    if !IsObject(macro)
        return

    ; Multi-selection is supported: delete from the end to avoid shifting indices.
    rows := []
    row := 0
    while (row := StepLV.GetNext(row))
        rows.Push(row)
    if (rows.Length = 0) {
        MsgBox("Сначала выдели один или несколько шагов.", "MouseMacro")
        return
    }
    ; Empty macros are ignored by LoadAll(), so the final step must remain.
    if (rows.Length >= macro.events.Length) {
        MsgBox("Нельзя удалить все шаги макроса. Если он больше не нужен, удали макрос целиком.", "MouseMacro")
        return
    }

    ; Keep the original timing rule: transfer each removed pause to the next step.
    ; A large transfer must not exceed the 600000 ms limit of image-based steps.
    pending := Map()
    for removedRow in rows
        pending[removedRow] := true
    delayToCarry := 0
    for i, event in macro.events {
        if pending.Has(i) {
            delayToCarry += event.delay
        } else if (delayToCarry > 0) {
            if ((StepKind(event) = "image_click" || StepKind(event) = "wait_image") && event.delay + delayToCarry > 600000) {
                MsgBox("После удаления пауза шага с изображением превысит 600000 мс. Уменьши задержки перед удалением.", "MouseMacro")
                return
            }
            delayToCarry := 0
        }
    }

    before := CloneMacroSteps(macro.events)
    Loop rows.Length {
        row := rows[rows.Length - A_Index + 1]
        if (row < macro.events.Length)
            macro.events[row + 1].delay += macro.events[row].delay
        macro.events.RemoveAt(row)
    }
    saved := CommitStepChange(macro, before)
    RefreshList(macro.id)
    StepLV.Modify(Min(rows[1], macro.events.Length), "Select Focus Vis")
    StatusText.Text := saved
        ? (rows.Length = 1 ? "Шаг удалён." : "Удалено шагов: " rows.Length ".") " Паузы до следующих шагов сохранены."
        : "Удаление отменено: изменения не удалось сохранить в MouseMacro.ini."
}

PlaySelected(*) {
    global SelectedId
    if SelectedId
        PlayById(SelectedId)
}

PlayById(id, *) {
    global IsRecording, IsPlaying, StopRequested, PickerOpen, StatusText, CursorRestoreDelayMs
    if (IsRecording || IsPlaying || PickerOpen)
        return
    macro := FindById(id)
    if (!IsObject(macro) || macro.events.Length = 0)
        return

    ; Older INI files may contain image-click actions. Keep them in the file for
    ; non-destructive migration, but never execute an unsupported click action.
    for event in macro.events {
        if (StepKind(event) = "image_click") {
            MsgBox("Этот макрос содержит устаревший шаг «Клик по изображению».`n" 
                . "Функция удалена: удали этот шаг и замени обычным кликом. `n" 
                . "Исходные данные сохранены в MouseMacro.ini.", "MouseMacro", "Icon!")
            return
        }
    }

    ; Validate image file references before blocking physical mouse input.
    for event in macro.events {
        if ((StepKind(event) = "image_click" || StepKind(event) = "wait_image") && !FileExist(ResolveTemplatePath(event.image))) {
            MsgBox("Не найден файл образца:`n" event.image "`n`nПроверь папку MouseMacro_Images.", "MouseMacro", "Icon!")
            return
        }
    }

    ; A mouse-bound hotkey fires on button-down. Wait asynchronously for
    ; its release before enabling the physical mouse-blocking guard.
    if PhysicalMouseButtonHeld() {
        QueuePlaybackAfterRelease(id)
        return
    }

    MouseGetPos(&startX, &startY)
    IsPlaying := true
    StopRequested := false
    UpdateButtons()
    repeatCount := HasProp(macro, "repeat") ? macro.repeat : 1
    StatusText.Text := "Выполняется: " macro.name " — повторов: " repeatCount "; F9 для остановки."
    targetTick := A_TickCount
    wasStopped := false
    errorText := ""
    stopReason := ""
    heldButton := ""
    imageSizes := Map()

    try {
        ; Block physical mouse input during playback, while allowing injected
        ; macro events and keyboard shortcuts (including emergency F9).
        StartMouseGuard()
        Loop repeatCount {
            targetTick := A_TickCount
            for event in macro.events {
                targetTick += event.delay
                while (!StopRequested && A_TickCount < targetTick)
                    Sleep(Min(10, targetTick - A_TickCount))
                if StopRequested {
                    wasStopped := true
                    break
                }
                kind := StepKind(event)
                if (kind = "wheel") {
                    ; Replay one physical wheel notch at the recorded pointer position.
                    ; The next event keeps its own recorded delay.
                    MouseMove(event.x, event.y, 0)
                    SendEvent("{" event.button "}")
                    continue
                }
                if (kind = "click") {
                    clickX := event.x
                    clickY := event.y
                    clickButton := event.button
                } else {
                    found := FindImageWithTimeout(event, &foundX, &foundY)
                    if StopRequested {
                        wasStopped := true
                        break
                    }
                    if !found {
                        if (kind = "wait_image") {
                            stopReason := "Изображение не появилось за " event.timeout " мс: " event.image
                            wasStopped := true
                            break
                        }
                        ; Conditional click: no match means no click, not a blind click.
                        targetTick := A_TickCount
                        continue
                    }
                    if (kind = "wait_image") {
                        targetTick := A_TickCount
                        continue
                    }
                    imagePath := ResolveTemplatePath(event.image)
                    if !imageSizes.Has(imagePath)
                        imageSizes[imagePath] := GetTemplateSize(imagePath)
                    size := imageSizes[imagePath]
                    clickX := foundX + Floor(size.w / 2)
                    clickY := foundY + Floor(size.h / 2)
                    clickButton := event.button
                }
                MouseMove(clickX, clickY, 0)
                heldButton := clickButton
                SendEvent("{" heldButton " down}")
                Sleep(50)
                SendEvent("{" heldButton " up}")
                heldButton := ""
                if (kind != "click")
                    targetTick := A_TickCount
            }
            if (wasStopped || StopRequested)
                break
        }
        ; Allow the last mouse-up to reach the target before restoring position.
        if (!wasStopped && !StopRequested) {
            endTick := A_TickCount + CursorRestoreDelayMs
            while (!StopRequested && A_TickCount < endTick)
                Sleep(Min(10, endTick - A_TickCount))
            if StopRequested
                wasStopped := true
        }
    } catch as err {
        errorText := err.Message
    } finally {
        if (heldButton != "")
            try SendEvent("{" heldButton " up}")
        try MouseMove(startX, startY, 0)
        ReleaseMouseGuard()
        IsPlaying := false
        StopRequested := false
        UpdateButtons()
        if (errorText != "")
            StatusText.Text := "Ошибка воспроизведения: " errorText
        else if (stopReason != "")
            StatusText.Text := stopReason
        else
            StatusText.Text := wasStopped ? "Воспроизведение остановлено." : "Воспроизведение завершено: " macro.name
    }
    if (errorText != "")
        MsgBox("Воспроизведение прервано:`n" errorText, "MouseMacro", "Icon!")
}

FindImageWithTimeout(event, &foundX, &foundY) {
    global StopRequested
    path := ResolveTemplatePath(event.image)
    if !FileExist(path)
        throw Error("Отсутствует образец изображения: " path)
    left := SysGet(76)   ; SM_XVIRTUALSCREEN (may be negative)
    top := SysGet(77)    ; SM_YVIRTUALSCREEN
    width := SysGet(78)  ; SM_CXVIRTUALSCREEN
    height := SysGet(79) ; SM_CYVIRTUALSCREEN
    if (width < 1 || height < 1)
        throw Error("Не удалось определить размеры рабочего стола.")
    imageSize := GetTemplateSize(path)
    if (imageSize.w > width || imageSize.h > height)
        return false
    options := "*" event.variation " " path
    deadline := A_TickCount + event.timeout
    Loop {
        if StopRequested
            return false
        if ImageSearch(&foundX, &foundY, left, top, left + width - 1, top + height - 1, options)
            return true
        if (event.timeout = 0 || A_TickCount >= deadline)
            return false
        Sleep(Min(100, Max(1, deadline - A_TickCount)))
    }
}

; WH_MOUSE_LL: suppress physical mouse events, but let our SendEvent/MouseMove through.
; Unlike BlockInput On, it leaves keyboard input (including emergency F9) available.
StartMouseGuard() {
    global MouseGuardHook, MouseGuardCallback, MouseGuardActive
    if MouseGuardHook {
        MouseGuardActive := true
        return
    }
    MouseGuardCallback := CallbackCreate(MouseGuardProc, "Fast", 3)
    MouseGuardHook := DllCall("SetWindowsHookExW", "Int", 14, "Ptr", MouseGuardCallback,
        "Ptr", 0, "UInt", 0, "Ptr")
    if !MouseGuardHook {
        errCode := A_LastError
        CallbackFree(MouseGuardCallback)
        MouseGuardCallback := 0
        throw Error("Не удалось включить защиту мыши (код Windows " errCode ").")
    }
    MouseGuardActive := true
}

MouseGuardProc(nCode, wParam, lParam) {
    global MouseGuardHook, MouseGuardActive
    ; MSLLHOOKSTRUCT.flags is at offset 12. Bit 0 = LLMHF_INJECTED.
    if (MouseGuardActive && nCode >= 0 && !(NumGet(lParam, 12, "UInt") & 1))
        return 1
    return DllCall("CallNextHookEx", "Ptr", MouseGuardHook, "Int", nCode,
        "UPtr", wParam, "Ptr", lParam, "Ptr")
}

ReleaseMouseGuard(*) {
    global MouseGuardHook, MouseGuardCallback, MouseGuardActive
    ; Fail-safe: even if Windows cannot remove the hook, it stops blocking input.
    MouseGuardActive := false
    if MouseGuardHook {
        try {
            if DllCall("UnhookWindowsHookEx", "Ptr", MouseGuardHook, "Int")
                MouseGuardHook := 0
        }
    }
    ; Do not free the callback while its hook could still be installed.
    if (!MouseGuardHook && MouseGuardCallback) {
        CallbackFree(MouseGuardCallback)
        MouseGuardCallback := 0
    }
}

StopPlayback(*) {
    global IsPlaying, StopRequested
    ; F9 also cancels playback waiting for the physical mouse-button release.
    CancelPendingPlayback()
    if IsPlaying
        StopRequested := true
}

PhysicalMouseButtonHeld() {
    for button in ["LButton", "RButton", "MButton", "XButton1", "XButton2"] {
        if GetKeyState(button, "P")
            return true
    }
    return false
}

CancelPendingPlayback() {
    global PendingPlaybackId, PendingPlaybackDeadline
    PendingPlaybackId := 0
    PendingPlaybackDeadline := 0
    SetTimer(PlayPendingAfterRelease, 0)
}

QueuePlaybackAfterRelease(id) {
    global PendingPlaybackId, PendingPlaybackDeadline, StatusText
    PendingPlaybackId := id
    PendingPlaybackDeadline := A_TickCount + 5000
    StatusText.Text := "Отпусти кнопку мыши для запуска макроса. F9 — отмена."
    SetTimer(PlayPendingAfterRelease, 20)
}

PlayPendingAfterRelease(*) {
    global PendingPlaybackId, PendingPlaybackDeadline
    global IsRecording, IsPlaying, PickerOpen, StatusText
    id := PendingPlaybackId
    if !id {
        SetTimer(PlayPendingAfterRelease, 0)
        return
    }
    if (IsRecording || IsPlaying || PickerOpen) {
        CancelPendingPlayback()
        return
    }
    if (A_TickCount > PendingPlaybackDeadline) {
        CancelPendingPlayback()
        StatusText.Text := "Запуск отменён: кнопка мыши не была отпущена."
        return
    }
    if PhysicalMouseButtonHeld()
        return
    CancelPendingPlayback()
    ; Run outside the originating mouse-hotkey callback and only after release.
    PlayById(id)
}

TrySaveAll() {
    try {
        SaveAll()
        return true
    } catch as err {
        MsgBox("Не удалось сохранить макросы на диск:`n" err.Message, "MouseMacro", "Icon!")
        return false
    }
}

SaveAll() {
    global IniPath, Macros, NextId
    temp := IniPath ".tmp"
    if FileExist(temp)
        FileDelete(temp)
    ; IniWrite automatically creates new INI files as UTF-16 for Unicode names.
    IniWrite(Macros.Length, temp, "Settings", "MacroCount")
    IniWrite(NextId, temp, "Settings", "NextId")
    for index, macro in Macros {
        section := "Macro" index
        IniWrite(macro.id, temp, section, "Id")
        IniWrite(macro.name, temp, section, "Name")
        IniWrite(macro.key, temp, section, "Hotkey")
        IniWrite(HasProp(macro, "repeat") ? macro.repeat : 1, temp, section, "Repeat")
        IniWrite(macro.events.Length, temp, section, "StepCount")
        for stepIndex, event in macro.events {
            kind := StepKind(event)
            if (kind = "image_click")
                encoded := "I|" event.delay "|" event.button "|" event.timeout "|" event.variation "|" event.image
            else if (kind = "wait_image")
                encoded := "W|" event.delay "|" event.timeout "|" event.variation "|" event.image
            else if (kind = "wheel")
                encoded := "S|" event.delay "|" event.button "|" event.x "|" event.y
            else
                encoded := event.delay "|" event.button "|" event.x "|" event.y
            IniWrite(encoded, temp, section, "Step" stepIndex)
        }
    }
    ; Preserve the previous complete version in case saving is interrupted or corrupt.
    ; A failure to create this backup must not destroy the original INI.
    if FileExist(IniPath)
        FileCopy(IniPath, IniPath ".bak", 1)
    FileMove(temp, IniPath, true)
}

LoadAll() {
    global IniPath, Macros, NextId
    if !FileExist(IniPath)
        return

    countText := IniRead(IniPath, "Settings", "MacroCount", "")
    if (countText = "") {
        ImportLegacyMacro()
        return
    }
    count := SafeNonnegativeInt(countText, 0)
    if (count > 1000) {
        MsgBox("В файле настроек слишком много макросов.", "MouseMacro")
        return
    }
    maxId := 0
    Loop count {
        section := "Macro" A_Index
        id := SafeNonnegativeInt(IniRead(IniPath, section, "Id", "0"), 0)
        name := IniRead(IniPath, section, "Name", "Действие " A_Index)
        key := Trim(IniRead(IniPath, section, "Hotkey", ""))
        total := SafeNonnegativeInt(IniRead(IniPath, section, "StepCount", "0"), 0)
        repeats := SafeNonnegativeInt(IniRead(IniPath, section, "Repeat", "1"), 1)
        if (id = 0 || key = "" || total > 10000)
            continue
        macro := {id: id, name: name, key: key, repeat: Max(1, Min(1000, repeats)), events: []}
        Loop total {
            encoded := IniRead(IniPath, section, "Step" A_Index, "")
            event := ParseStep(encoded)
            if IsObject(event)
                macro.events.Push(event)
        }
        if (macro.events.Length = 0 || !CheckKey(key))
            continue
        try {
            Hotkey(key, PlayById.Bind(id), "On")
            Macros.Push(macro)
            maxId := Max(maxId, id)
        } catch {
            ; An unavailable/invalid shortcut does not prevent loading the rest.
        }
    }
    NextId := Max(maxId + 1, SafeNonnegativeInt(IniRead(IniPath, "Settings", "NextId", "1"), 1))
}

ImportLegacyMacro() {
    global IniPath, Macros, NextId
    countText := IniRead(IniPath, "Events", "Count", "")
    if (countText = "")
        return
    count := SafeNonnegativeInt(countText, 0)
    if (count > 10000 || count = 0)
        return
    key := Trim(IniRead(IniPath, "Settings", "PlaybackHotkey", "F8"))
    if (key = "" || StrLower(key) = "f9" || StrLower(key) = "^!r" || StrLower(key) = "^!esc")
        key := "F8"
    macro := {id: 1, name: "Импортированный макрос", key: key, repeat: 1, events: []}
    Loop count {
        encoded := IniRead(IniPath, "Events", A_Index, "")
        event := ParseStep(encoded)
        if IsObject(event)
            macro.events.Push(event)
    }
    if (macro.events.Length = 0)
        return
    try {
        Hotkey(key, PlayById.Bind(1), "On")
    } catch as err {
        MsgBox("Старый макрос найден, но горячая клавиша недоступна:`n" err.Message, "MouseMacro")
        return
    }
    Macros.Push(macro)
    NextId := 2
    try {
        FileCopy(IniPath, IniPath ".legacy.bak", true)
        SaveAll()
    } catch as err {
        MsgBox("Старый макрос импортирован в память, но не сохранён.`n" err.Message, "MouseMacro")
    }
}

ParseStep(encoded) {
    parts := StrSplit(encoded, "|")
    ; S = one mouse-wheel step; older four-field click records stay unchanged.
    if (parts.Length = 5 && parts[1] = "S") {
        if !(parts[2] ~= "^\d+$") || !(parts[4] ~= "^-?\d+$") || !(parts[5] ~= "^-?\d+$")
            return ""
        if (parts[3] != "WheelUp" && parts[3] != "WheelDown")
            return ""
        return {type: "wheel", delay: Floor(parts[2] + 0), button: parts[3],
            x: Floor(parts[4] + 0), y: Floor(parts[5] + 0)}
    }
    if (parts.Length = 6 && parts[1] = "I") {
        if !RegExMatch(parts[2], "^\d+$") || !RegExMatch(parts[4], "^\d+$") || !RegExMatch(parts[5], "^\d+$")
            return ""
        if (parts[3] != "LButton" && parts[3] != "RButton" && parts[3] != "MButton")
            return ""
        if (parts[2] + 0 > 600000 || parts[4] + 0 > 60000 || parts[5] + 0 > 255 || parts[6] = "")
            return ""
        return {type: "image_click", delay: Floor(parts[2] + 0), button: parts[3],
            timeout: Floor(parts[4] + 0), variation: Floor(parts[5] + 0), image: parts[6]}
    }
    if (parts.Length = 5 && parts[1] = "W") {
        if !RegExMatch(parts[2], "^\d+$") || !RegExMatch(parts[3], "^\d+$") || !RegExMatch(parts[4], "^\d+$")
            return ""
        if (parts[2] + 0 > 600000 || parts[3] + 0 > 60000 || parts[4] + 0 > 255 || parts[5] = "")
            return ""
        return {type: "wait_image", delay: Floor(parts[2] + 0),
            timeout: Floor(parts[3] + 0), variation: Floor(parts[4] + 0), image: parts[5]}
    }
    ; Previous releases used four fields; continue reading them unchanged.
    if (parts.Length != 4)
        return ""
    if !RegExMatch(parts[1], "^\d+$")
        return ""
    if !RegExMatch(parts[3], "^-?\d+$") || !RegExMatch(parts[4], "^-?\d+$")
        return ""
    if (parts[2] != "LButton" && parts[2] != "RButton" && parts[2] != "MButton")
        return ""
    return {delay: Floor(parts[1] + 0), button: parts[2], x: Floor(parts[3] + 0), y: Floor(parts[4] + 0)}
}

SafeNonnegativeInt(value, fallback := 0) {
    if !RegExMatch(Trim(value), "^\d+$")
        return fallback
    return Floor(value + 0)
}


; =========================================================
; WebView2 front-end. The previous AHK GUI is kept hidden
; solely as a compatibility adapter for the mature editor
; and recording/playback engine. No macro format changes.
; =========================================================
InitWebInterface() {
    global WebGui
    WebGui := WebViewGui("+Resize MinSize850x480", "MouseMacro — менеджер действий")
    ; WebView2 is ONLY a renderer for the local UI, not a browser.
    ; Keep text editing and the JS<->AHK bridge operational.
    try WebGui.Control.AreBrowserAcceleratorKeysEnabled := false
    try WebGui.Control.AreDefaultContextMenusEnabled := false
    try WebGui.Control.AreDevToolsEnabled := false
    try WebGui.Control.IsStatusBarEnabled := false
    try WebGui.Control.IsZoomControlEnabled := false
    try WebGui.Control.IsSwipeNavigationEnabled := false
    try WebGui.Control.IsPinchZoomEnabled := false
    WebGui.Control.wv.add_NavigationStarting(GuardWebNavigation)
    OnMessage(0x0319, BlockWebAppCommand)  ; Windows APPCOMMAND_BROWSER_BACKWARD/FORWARD
    WebGui.OnEvent("Close", OnWindowClose)
    WebGui.AddCallbackToScript("Action", WebAction)
    WebGui.BrowseFolder(A_ScriptDir "\web")
    WebGui.Navigate("index.html")
    WebGui.Show("w1100 h600 Center")
    SetTimer(PublishWebState, 450)
}

BlockWebAppCommand(wParam, lParam, msg, hwnd) {
    ; Some mouse drivers send browser back/forward as WM_APPCOMMAND rather
    ; than XBUTTON. Block only for our foreground application window.
    if !WebWindowIsActive()
        return
    command := (lParam >> 16) & 0x7FF
    if (command = 1 || command = 2)
        return 1
}

GuardWebNavigation(webview, args) {
    ; Prevent mouse-back/browser commands from navigating away from our app UI.
    uri := StrLower(String(args.Uri))
    if !RegExMatch(uri, "^https://ahk\.localhost/(?:index\.html)?(?:[?#].*)?$")
        args.Cancel := true
}

WebJsonQuote(s) {
    s := String(s)
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    ; JSON forbids all other unescaped control characters U+0000..U+001F.
    clean := ""
    Loop Parse, s {
        ch := A_LoopField
        clean .= Ord(ch) < 32 ? "\u" Format("{:04X}", Ord(ch)) : ch
    }
    return '"' clean '"'
}

PublishWebState(*) {
    global WebGui, WebLastState, Macros, SelectedId, IsRecording, IsPlaying
    global StatusText, StepLV
    if !IsObject(WebGui)
        return
    result := '{"type":"state","selected":' SelectedId
        . ',"recording":' (IsRecording ? 'true' : 'false')
        . ',"playing":' (IsPlaying ? 'true' : 'false')
        . ',"status":' WebJsonQuote(StatusText.Text)
        . ',"version":' WebJsonQuote(AppVersion())
        . ',"macros":['
    for macro in Macros {
        if (A_Index > 1)
            result .= ","
        repeats := HasProp(macro, "repeat") ? macro.repeat : 1
        result .= '{"id":' macro.id ',"name":' WebJsonQuote(macro.name)
            . ',"key":' WebJsonQuote(macro.key) ',"count":' macro.events.Length
            . ',"repeat":' repeats '}'
    }
    result .= '],"steps":['
    macro := GetSelected()
    if IsObject(macro) {
        for index, event in macro.events {
            if (index > 1)
                result .= ","
            kind := StepKind(event)
            name := ""
            if (kind = "click") {
                detail := ButtonLabel(event.button) " кнопка: X=" event.x " Y=" event.y
                name := "Клик мышью"
                extra := '"x":' event.x ',"y":' event.y ',"button":' WebJsonQuote(event.button)
            } else if (kind = "wheel") {
                name := "Прокрутка колеса"
                detail := (event.button = "WheelUp" ? "Колесо вверх" : "Колесо вниз") " — X=" event.x " Y=" event.y
                extra := '"x":' event.x ',"y":' event.y ',"button":' WebJsonQuote(event.button)
            } else {
                SplitPath(event.image, &name)
                detail := kind = "image_click" ? "УСТАРЕВШИЙ шаг — удали: " name : "Ждать изображение: " name " (до " event.timeout " мс)"
                extra := '"image":' WebJsonQuote(event.image) ',"timeout":' event.timeout
                    . ',"variation":' event.variation ',"button":' WebJsonQuote(HasProp(event, "button") ? event.button : "LButton")
            }
            result .= '{"n":' index ',"type":' WebJsonQuote(kind)
                . ',"name":' WebJsonQuote(name) ',"detail":' WebJsonQuote(detail)
                . ',"delay":' event.delay ',' extra '}'
        }
    }
    result .= '],"rows":['
    row := 0
    commas := 0
    while (row := StepLV.GetNext(row)) {
        result .= (commas ? "," : "") row
        commas++
    }
    result .= ']}'
    if (result = WebLastState)
        return
    try {
        WebGui.PostWebMessageAsJson(result)
        WebLastState := result
    }
}

WebReport(message) {
    global WebGui, StatusText
    StatusText.Text := message
    try WebGui.PostWebMessageAsJson('{"type":"toast","text":' WebJsonQuote(message) '}')
}

NormalizeAppVersion(version) {
    ; Trim whitespace and an optional Unicode BOM before comparing versions.
    return Trim(String(version), " `t`r`n" Chr(0xFEFF))
}

AppVersion() {
    ; Read the version once per process, not every 450 ms on UI refresh.
    static version := ""
    if (version != "")
        return version
    try {
        version := NormalizeAppVersion(FileRead(A_ScriptDir "\VERSION.txt", "UTF-8"))
    } catch {
        version := "неизвестна"
    }
    return version
}

AppUpdateState(available, installed) {
    available := NormalizeAppVersion(available)
    installed := NormalizeAppVersion(installed)
    ; Do not install on unknown or malformed version information.
    pattern := "i)^\d+\.\d+\.\d+(?:-[a-z0-9.-]+)?$"
    if !RegExMatch(available, pattern) || !RegExMatch(installed, pattern)
        return "error"
    if (VerCompare(available, installed) > 0)
        return "available"
    return "latest"
}

WebUpdateMessage(status, version := "", message := "") {
    global WebGui
    if !IsObject(WebGui)
        return
    try WebGui.PostWebMessageAsJson('{"type":"updateCheck","status":' WebJsonQuote(status)
        . ',"version":' WebJsonQuote(version) ',"installed":' WebJsonQuote(AppVersion())
        . ',"message":' WebJsonQuote(message) '}')
}

CheckAppUpdates() {
    global UpdateCheckRequest, UpdateCheckStartedAt, IsRecording, IsPlaying
    if (IsRecording || IsPlaying) {
        WebUpdateMessage("error", "", "Сначала останови запись или воспроизведение.")
        return
    }
    if IsObject(UpdateCheckRequest)
        return
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(4000, 4000, 7000, 7000)
        req.Open("GET", "https://raw.githubusercontent.com/Gh0StCK/MouseMacro-Manager/updates/update.json", true)
        req.SetRequestHeader("Cache-Control", "no-cache")
        req.Send()
        UpdateCheckRequest := req
        UpdateCheckStartedAt := A_TickCount
        SetTimer(PollAppUpdates, 150)
    } catch as err {
        UpdateCheckRequest := ""
        WebUpdateMessage("error", "", err.Message)
    }
}

PollAppUpdates(*) {
    global UpdateCheckRequest, UpdateCheckStartedAt
    if !IsObject(UpdateCheckRequest) {
        SetTimer(PollAppUpdates, 0)
        return
    }
    try {
        if !UpdateCheckRequest.WaitForResponse(0) {
            if (A_TickCount - UpdateCheckStartedAt > 15000)
                throw Error("Превышено время ожидания ответа GitHub.")
            return
        }
        if (UpdateCheckRequest.Status != 200)
            throw Error("GitHub вернул HTTP " UpdateCheckRequest.Status)
        data := UpdateCheckRequest.ResponseText
        if !RegExMatch(data, 'i)"version"\s*:\s*"([0-9a-z.\-]+)"', &match)
            throw Error("Некорректная версия в update.json.")
        if !RegExMatch(data, 'i)"channel"\s*:\s*"updates"')
            throw Error("Неверный канал обновлений.")
        version := match[1]
        state := AppUpdateState(version, AppVersion())
        if (state = "error")
            throw Error("Не удалось сравнить номера версий.")
        WebUpdateMessage(state, version)
    } catch as err {
        WebUpdateMessage("error", "", err.Message)
    }
    try UpdateCheckRequest.Abort()
    UpdateCheckRequest := ""
    SetTimer(PollAppUpdates, 0)
}

ApplyAppUpdate() {
    global IsRecording, IsPlaying, AppUpdatePending
    if (IsRecording || IsPlaying) {
        WebUpdateMessage("error", "", "Сначала останови запись или воспроизведение.")
        return
    }
    if AppUpdatePending
        return
    if !FileExist(A_ScriptDir "\Update_MouseMacro.cmd")
        return WebUpdateMessage("error", "", "Не найден Update_MouseMacro.cmd рядом с программой.")
    if !FileExist(A_ScriptDir "\Update_MouseMacro.ps1")
        return WebUpdateMessage("error", "", "Не найден Update_MouseMacro.ps1 рядом с программой.")
    ; The WebView2 host-object call is synchronous. ExitApp must NOT run inside
    ; that callback; let the HTML handler return first.
    AppUpdatePending := true
    SetTimer(LaunchAppUpdateAfterWebCallback, -250)
}

LaunchAppUpdateAfterWebCallback(*) {
    global AppUpdatePending
    if !AppUpdatePending
        return
    AppUpdatePending := false
    updater := A_ScriptDir "\Update_MouseMacro.cmd"
    try {
        ; Use exactly the same CMD/PowerShell updater as the working manual path.
        ; A new console displays errors and pauses, instead of failing silently.
        command := '"' A_ComSpec '" /c ""' updater '""'
        Run(command, A_ScriptDir)
        ExitApp()
    } catch as err {
        WebUpdateMessage("error", "", "Не удалось запустить обновление: " err.Message)
    }
}

WebAction(view, command, a := "", b := "", c := "", d := "", e := "", f := "", g := "", h := "") {
    global SelectedId, Macros, MacroLV, StepLV, StatusText
    global IsRecording, IsPlaying, PickerOpen, PendingCopyId, WebGui, WebLastState
    try {
        switch command {
            case "checkUpdate":
                CheckAppUpdates()
            case "applyUpdate":
                ApplyAppUpdate()
            case "ready":
                WebLastState := ""
                PublishWebState()
            case "picker":
                PickerOpen := (String(a) = "on")
                for macro in Macros {
                    try Hotkey(macro.key, PickerOpen ? "Off" : "On")
                }
            case "selectMacro":
                id := Integer(a)
                if !IsObject(FindById(id))
                    return
                SelectedId := id
                for index, macro in Macros {
                    if (macro.id = id) {
                        MacroLV.Modify(0, "-Select")
                        MacroLV.Modify(index, "Select Focus Vis")
                        break
                    }
                }
                RefreshSteps()
            case "selectSteps":
                StepLV.Modify(0, "-Select")
                for val in StrSplit(String(a), ",") {
                    if (val ~= "^\d+$" && Integer(val) >= 1 && Integer(val) <= StepLV.GetCount())
                        StepLV.Modify(Integer(val), "Select")
                }
            case "startRecording":
                if !IsRecording && !IsPlaying && !PickerOpen {
                    if !CheckKey(String(a))
                        return
                    BeginNewRecording(String(a))
                }
            case "finishRecording":
                FinishRecording()
            case "cancelRecording":
                CancelRecording()
            case "recordExtra":
                AddStepsToSelected()
            case "play":
                ; Return the synchronous WebView2 bridge callback before executing
                ; a possibly long macro; F9 and UI state remain responsive.
                if !IsRecording && !IsPlaying && !PickerOpen
                    SetTimer(PlaySelected, -30)
            case "stop":
                StopPlayback()
            case "rename":
                if !IsRecording && !IsPlaying && !PickerOpen {
                    macro := GetSelected()
                    if IsObject(macro) && Trim(String(a)) != "" {
                        oldName := macro.name
                        macro.name := Trim(String(a))
                        saved := TrySaveAll()
                        if !saved
                            macro.name := oldName
                        RefreshList(macro.id)
                        WebReport(saved ? "Макрос переименован." : "Переименование отменено: не удалось сохранить INI.")
                    }
                }
            case "rekey":
                if !IsRecording && !IsPlaying && !PickerOpen && CheckKey(String(a), SelectedId)
                    ApplyNewKey(SelectedId, String(a))
            case "copy":
                if !IsRecording && !IsPlaying && !PickerOpen && CheckKey(String(a)) {
                    PendingCopyId := SelectedId
                    CommitCopy(String(a))
                }
            case "deleteMacro":
                if !IsRecording && !IsPlaying && !PickerOpen {
                    macro := GetSelected()
                    if !IsObject(macro)
                        return
                    removedIndex := 0
                    for index, item in Macros {
                        if (item.id = macro.id) {
                            removedIndex := index
                            break
                        }
                    }
                    if !removedIndex
                        return
                    try Hotkey(macro.key, "Off")
                    Macros.RemoveAt(removedIndex)
                    SelectedId := 0
                    saved := TrySaveAll()
                    if !saved {
                        Macros.InsertAt(removedIndex, macro)
                        SelectedId := macro.id
                        try Hotkey(macro.key, "On")
                    }
                    RefreshList(saved ? 0 : macro.id)
                    WebReport(saved ? "Макрос удалён." : "Удаление отменено: не удалось сохранить INI.")
                }
            case "repeat":
                if !IsRecording && !IsPlaying && !PickerOpen && String(a) ~= "^\d+$" {
                    count := Integer(a)
                    macro := GetSelected()
                    if IsObject(macro) && count >= 1 && count <= 1000 {
                        previousRepeat := macro.repeat
                        macro.repeat := count
                        saved := TrySaveAll()
                        if !saved
                            macro.repeat := previousRepeat
                        RefreshList(macro.id)
                        if !saved
                            WebReport("Число повторов не изменено: сохранить INI не удалось.")
                    }
                }
            case "delay":
                if !IsRecording && !IsPlaying && !PickerOpen
                    WebSetDelay(String(a))
            case "editClick":
                if !IsRecording && !IsPlaying && !PickerOpen
                    WebEditClick(String(a), String(b), String(c), String(d), String(e))
            case "selectAll":
                SelectAllSteps()
            case "deleteStep":
                RemoveStep()
            case "duplicateStep":
                DuplicateSelectedSteps()
            case "undoStep":
                UndoStepChange()
            case "moveUp":
                MoveStep(-1)
            case "moveDown":
                MoveStep(1)
            case "browseImage":
                path := FileSelect(1,, "Выбери файл образца", "Изображения (*.png; *.bmp; *.jpg; *.jpeg)")
                if (path != "") {
                    photo := ""
                    try photo := WebImageDataUri(path)
                    WebGui.PostWebMessageAsJson('{"type":"imagePicked","path":' WebJsonQuote(path)
                        . ',"preview":' WebJsonQuote(photo) '}')
                }
            case "previewImage":
                path := ResolveTemplatePath(String(a))
                if FileExist(path) {
                    photo := ""
                    try photo := WebImageDataUri(path)
                    WebGui.PostWebMessageAsJson('{"type":"imagePicked","path":' WebJsonQuote(String(a))
                        . ',"preview":' WebJsonQuote(photo) '}')
                }
            case "imageSave":
                if !IsRecording && !IsPlaying && !PickerOpen
                    WebSaveImage(String(a), String(b), String(c), String(d), String(e), String(f), String(g))
            case "testImage":
                ; Do not hide WebView during a synchronous JS-to-AHK callback.
                ; Schedule the probe immediately after the bridge call returns.
                SetTimer(WebTestImage.Bind(String(a), String(b)), -30)
            case "exit":
                ExitManager()
            case "help":
                MsgBox("Запись: Ctrl+Alt+R. Отмена записи: Ctrl+Alt+Esc. Аварийная остановка воспроизведения: F9.`n`nЗаписываются клики и прокрутка колеса вверх/вниз (с координатами и паузами). «Редактировать шаг» меняет координаты и действие мыши. «Изменить паузы» работает сразу с несколькими шагами. Ожидание изображения останавливает макрос по тайм-ауту.", "MouseMacro")
        }
    } catch as err {
        WebReport("Ошибка: " err.Message)
    }
    PublishWebState()
}

WebEditClick(rowRaw, xRaw, yRaw, buttonRaw, delayRaw) {
    global StepLV, WebGui
    macro := GetSelected()
    if !IsObject(macro)
        return
    if !(rowRaw ~= "^\d+$") || Integer(rowRaw) < 1 || Integer(rowRaw) > macro.events.Length
        return WebReport("Шаг не найден.")
    row := Integer(rowRaw)
    if (StepKind(macro.events[row]) != "click" && StepKind(macro.events[row]) != "wheel")
        return WebReport("Редактировать координаты можно только у кликов и прокрутки.")
    if !(xRaw ~= "^-?\d+$") || !(yRaw ~= "^-?\d+$")
        return WebReport("Координаты должны быть целыми числами.")
    if Abs(Integer(xRaw)) > 100000 || Abs(Integer(yRaw)) > 100000
        return WebReport("Координаты должны находиться в диапазоне от -100000 до 100000.")
    if !(delayRaw ~= "^\d+$") || Integer(delayRaw) > 600000
        return WebReport("Пауза должна быть в диапазоне от 0 до 600000 мс.")
    if !InStr("|LButton|RButton|MButton|WheelUp|WheelDown|", "|" buttonRaw "|")
        return WebReport("Недопустимое действие мыши.")

    before := CloneMacroSteps(macro.events)
    if (buttonRaw = "WheelUp" || buttonRaw = "WheelDown")
        macro.events[row] := {type: "wheel", delay: Integer(delayRaw), button: buttonRaw,
            x: Integer(xRaw), y: Integer(yRaw)}
    else
        macro.events[row] := {delay: Integer(delayRaw), button: buttonRaw,
            x: Integer(xRaw), y: Integer(yRaw)}
    if !CommitStepChange(macro, before) {
        StepLV.Modify(row, "Select Focus Vis")
        return WebReport("Изменение не сохранено; прежние значения восстановлены.")
    }
    RefreshSteps()
    StepLV.Modify(row, "Select Focus Vis")
    WebReport("Шаг №" row " обновлён: " buttonRaw " (" xRaw ", " yRaw "), пауза " delayRaw " мс.")
    try WebGui.PostWebMessageAsJson('{"type":"closeModal"}')
}

WebSetDelay(value) {
    global StepLV
    macro := GetSelected()
    if !IsObject(macro)
        return
    if !(value ~= "^\d+$") || Integer(value) > 600000 {
        WebReport("Пауза должна быть числом от 0 до 600000 мс.")
        return
    }
    rows := []
    row := 0
    while (row := StepLV.GetNext(row))
        rows.Push(row)
    if (rows.Length = 0) {
        WebReport("Сначала выдели один или несколько шагов.")
        return
    }
    before := CloneMacroSteps(macro.events)
    for row in rows
        macro.events[row].delay := Integer(value)
    saved := CommitStepChange(macro, before)
    RefreshSteps()
    for row in rows
        StepLV.Modify(row, "Select")
    WebReport(saved ? "Задержка обновлена для " rows.Length " шаг(ов)." : "Паузы не изменены: сохранение INI не удалось.")
}

WebSaveImage(kind, rawPath, timeoutRaw, variationRaw, mouseButton, delayRaw, editRowRaw) {
    global StepLV, WebGui
    macro := GetSelected()
    if !IsObject(macro)
        return
    if (kind != "wait_image") {
        WebReport("Клик по изображению удалён. Доступно только ожидание изображения.")
        return
    }
    if !(timeoutRaw ~= "^\d+$") || Integer(timeoutRaw) > 60000
        return WebReport("Ожидание: от 0 до 60000 мс.")
    if !(variationRaw ~= "^\d+$") || Integer(variationRaw) > 255
        return WebReport("Допуск цвета: от 0 до 255.")
    if !(delayRaw ~= "^\d+$") || Integer(delayRaw) > 600000
        return WebReport("Пауза: от 0 до 600000 мс.")
    path := ResolveTemplatePath(Trim(rawPath, ' "'))
    if !FileExist(path)
        return WebReport("Файл образца не найден.")
    SplitPath(path, , , &ext)
    if !InStr("|png|bmp|jpg|jpeg|", "|" StrLower(ext) "|")
        return WebReport("Допустимы только PNG, BMP, JPG.")
    try {
        size := GetTemplateSize(path)
        if (size.w < 1 || size.h < 1)
            throw Error("Файл не является изображением.")
    } catch as err {
        return WebReport("Не удалось прочитать изображение: " err.Message)
    }
    row := (editRowRaw ~= "^\d+$") ? Integer(editRowRaw) : 0
    if (row < 1 || row > macro.events.Length)
        row := 0
    if !row {
        if (macro.events.Length >= 10000)
            return WebReport("Нельзя добавить шаг: достигнут предел 10000 шагов.")
        selectedRow := StepLV.GetNext()
        if (selectedRow && StepLV.GetNext(selectedRow))
            return WebReport("Для вставки выбери один шаг или сними выделение.")
    }
    if row {
        prev := macro.events[row]
        if (StepKind(prev) = "click" || StepKind(prev) = "wheel")
            return WebReport("Редактирование образца доступно только шагам с изображением.")
        stored := (ResolveTemplatePath(prev.image) = path) ? prev.image : StoreTemplate(path)
    } else {
        stored := StoreTemplate(path)
    }
    before := CloneMacroSteps(macro.events)
    action := {type: kind, image: stored, timeout: Integer(timeoutRaw), variation: Integer(variationRaw), delay: Integer(delayRaw)}
    if (kind = "image_click")
        action.button := InStr("|LButton|RButton|MButton|", "|" mouseButton "|") ? mouseButton : "LButton"
    if row {
        macro.events[row] := action
    } else {
        row := selectedRow ? selectedRow + 1 : macro.events.Length + 1
        macro.events.InsertAt(row, action)
    }
    saved := CommitStepChange(macro, before)
    RefreshList(macro.id)
    StepLV.Modify(Min(row, macro.events.Length), "Select Focus Vis")
    WebReport(saved ? "Шаг ожидания изображения сохранён." : "Шаг не изменён: сохранить INI не удалось.")
    if saved
        try WebGui.PostWebMessageAsJson('{"type":"closeModal"}')
}

WebTestImage(rawPath, rawVariation) {
    global WebGui, IsRecording, IsPlaying, PickerOpen
    if (IsRecording || IsPlaying || PickerOpen)
        return WebReport("Проверка доступна только когда макрос не выполняется.")
    if !(rawVariation ~= "^\d+$") || Integer(rawVariation) > 255
        return WebReport("Допуск цвета: от 0 до 255.")
    path := ResolveTemplatePath(Trim(rawPath, ' "'))
    if !FileExist(path)
        return WebReport("Сначала выбери существующий файл изображения.")
    SplitPath(path, , , &ext)
    if !InStr("|png|bmp|jpg|jpeg|", "|" StrLower(ext) "|")
        return WebReport("Для проверки поддерживаются PNG, BMP и JPG.")
    wasFound := false
    errText := ""
    foundX := 0
    foundY := 0
    try {
        ; The browser preview must not be included in the image-search area.
        WinHide("ahk_id " WebGui.Hwnd)
        Sleep(200)
        event := {image: path, variation: Integer(rawVariation), timeout: 0}
        wasFound := FindImageWithTimeout(event, &foundX, &foundY)
    } catch as err {
        errText := err.Message
    } finally {
        WebGui.Show()
    }
    if (errText != "")
        WebReport("Ошибка проверки изображения: " errText)
    else if wasFound
        WebReport("Образец найден на экране: X=" foundX ", Y=" foundY ". Клик не выполнялся.")
    else
        WebReport("Образец на экране не найден. Проверь масштаб и допуск цвета.")
}

WebImageDataUri(path) {
    SplitPath(path, , , &ext)
    format := StrLower(ext) = "png" ? "image/png" : (StrLower(ext) = "bmp" ? "image/bmp" : "image/jpeg")
    bytes := FileRead(path, "RAW")
    ; Preview cap protects the bridge from enormous multi-megabyte resources.
    if bytes.Size > 1500000
        return ""
    flags := 0x40000001 ; CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
    chars := 0
    if !DllCall("Crypt32\CryptBinaryToStringW", "ptr", bytes.Ptr, "uint", bytes.Size, "uint", flags, "ptr", 0, "uint*", &chars)
        return ""
    output := Buffer(chars * 2, 0)
    if !DllCall("Crypt32\CryptBinaryToStringW", "ptr", bytes.Ptr, "uint", bytes.Size, "uint", flags, "ptr", output.Ptr, "uint*", &chars)
        return ""
    return "data:" format ";base64," StrGet(output.Ptr, "UTF-16")
}
