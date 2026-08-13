; FluxWave Inno Setup 7.x 脚本
; 适用 Inno Setup 7.0.2 及以上稳定版（https://jrsoftware.org/isdl.php）
;
; 用法（在项目根目录执行）：
;   1. 先构建 Flutter Windows 发布版：flutter build windows --release
;   2. 调用 ISCC 编译：iscc windows\packaging\inno_setup.iss
;   3. 产物输出到 dist\FluxWave-<version>-setup.exe
;
; 设计要点：
;   - Per-user 安装（PrivilegesRequired=lowest），不弹 UAC，写入 HKCU
;   - 桌面快捷方式：默认不勾选
;   - 开机自启动：默认不勾选

#define MyAppName "FluxWave"
#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#ifndef MyAppVersionFile
  #define MyAppVersionFile "0.1.0"
#endif
#ifndef ArchSuffix
  #define ArchSuffix "x64"
#endif
#define MyAppPublisher "QiuQianZzz"
#define MyAppExeName "fluxwave.exe"
#define MyAppSourceDir "..\..\build\windows\" + ArchSuffix + "\runner\Release"

[Setup]
AppId={{A7E3F2D1-8B4C-4E5A-9F6D-2C1B0A3E5D7F}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://github.com/QiuQianZzz/FluxWave
AppSupportURL=https://github.com/QiuQianZzz/FluxWave/issues
AppUpdatesURL=https://github.com/QiuQianZzz/FluxWave/releases

DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes

PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

OutputDir=..\..\dist
OutputBaseFilename=FluxWave-{#MyAppVersionFile}-{#ArchSuffix}-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

#if ArchSuffix == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; GroupDescription: "附加选项："; Description: "在桌面创建快捷方式"; Flags: unchecked
Name: "autostart"; GroupDescription: "附加选项："; Description: "开机自启动 FluxWave"; Flags: unchecked

[Files]
Source: "{#MyAppSourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "FluxWave"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
