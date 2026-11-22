#Requires AutoHotkey v2.0
#SingleInstance Force

; One-time setup for the MIT-licensed WebViewToo bridge.
; Only the source repository archive is downloaded from GitHub;
; no installer or third-party executable is launched.

SetWorkingDir(A_ScriptDir)
engine := A_ScriptDir "\MouseMacro_WebView.ahk"
if !FileExist(engine) {
    MsgBox("Не найден MouseMacro_WebView.ahk рядом с файлом запуска.", "MouseMacro", "Icon!")
    ExitApp()
}

lib := A_ScriptDir "\Lib\WebViewToo.ahk"
loader := A_ScriptDir "\Lib\64bit\WebView2Loader.dll"
if !FileExist(lib) || !FileExist(loader) {
    choice := MsgBox("Для HTML-интерфейса нужна бесплатная библиотека WebViewToo (лицензия MIT).`n`n"
        . "Сейчас будет скачан архив исходного проекта The-CoDingman/WebViewToo (зафиксированная версия) с GitHub, затем в эту папку будут скопированы AHK-файлы библиотеки и WebView2Loader.dll.`n`n"
        . "Это выполняется один раз. Никакие установщики не запускаются. Продолжить?",
        "MouseMacro — первое включение WebView2", "YesNo Icon?")
    if (choice != "Yes")
        ExitApp()
    revision := "53fc321984d1ad9665038950f5ef4cedd1face35"
    zipPath := A_Temp "\mousemacro-webviewtoo.zip"
    unpack := A_Temp "\mousemacro-webviewtoo-source"
    try {
        if FileExist(zipPath)
            FileDelete(zipPath)
        if DirExist(unpack)
            DirDelete(unpack, 1)
        Download("https://codeload.github.com/The-CoDingman/WebViewToo/zip/" revision, zipPath)
        DirCreate(unpack)
        ; Windows 10/11 includes tar.exe, which can extract ZIP archives.
        exitCode := RunWait('tar.exe -xf "' zipPath '" -C "' unpack '"',, "Hide")
        from := unpack "\WebViewToo-" revision "\Lib"
        if (exitCode != 0 || !FileExist(from "\WebViewToo.ahk"))
            throw Error("Не удалось распаковать ZIP библиотеки.")
        DirCopy(from, A_ScriptDir "\Lib", 1)
        license := unpack "\WebViewToo-" revision "\LICENSE"
        if FileExist(license)
            FileCopy(license, A_ScriptDir "\Lib\LICENSE-WebViewToo.txt", 1)
        if (!FileExist(lib) || !FileExist(loader))
            throw Error("В скачанном архиве отсутствуют необходимые файлы WebViewToo.")
    } catch as err {
        MsgBox("Не удалось получить WebViewToo.`n`n" err.Message "`n`n"
            . "Можно вручную скачать исходники с https://github.com/The-CoDingman/WebViewToo и скопировать содержимое папки Lib рядом со скриптом.",
            "MouseMacro — ошибка подготовки", "Icon!")
        ExitApp()
    }
    try FileDelete(zipPath)
    try DirDelete(unpack, 1)
}

try Run('"' A_AhkPath '" "' engine '"', A_ScriptDir)
catch as err
    MsgBox("Не удалось запустить приложение:`n" err.Message, "MouseMacro", "Icon!")
ExitApp()
