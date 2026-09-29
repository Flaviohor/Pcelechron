; PCelechron Windows 安装器脚本（Inno Setup 6）
;
; 一份脚本同时服务本地与 CI，差异全部走命令行 /D 覆盖。
;
; 本地（默认，从 flutter build 产物取文件）：
;   ISCC.exe tool\installer.iss
;
; 本地（推荐：从 tool/package.py 生成的暂存目录取文件，包内已含 app-local
; VC++ 运行库，目标机器无需另装运行库）：
;   ISCC.exe /DStageDir=E:\celechron-windows\dist\Celechron-1.3.0-windows-x64 tool\installer.iss
;
; CI（.github/workflows/build_desktop.yml 调用）：
;   ISCC.exe /DAppVersion=<pubspec 版本> /DArchLabel=x64 /DBuildDir=x64 ^
;            /DSourceRoot=<github.workspace> tool\installer.iss
;
; 可覆盖开关：AppVersion / ArchLabel / BuildDir / SourceRoot / StageDir / OutputDir
; 产物统一落在 {#OutputDir}（默认 installer_output\），文件名
;   PCelechron-<版本>-windows-<架构>-setup.exe

#define AppName      "PCelechron"
#define AppExeName   "PCelechron.exe"
#define AppPublisher "PCelechron contributors"
#define AppURL       "https://github.com/Flaviohor/Celechron"

; ---- 开关默认值：命令行给了就用命令行的（#ifndef 只在未定义时生效）----

#ifndef AppVersion
  #define AppVersion "1.0.1"
#endif

#ifndef ArchLabel
  #define ArchLabel "x64"
#endif

#ifndef BuildDir
  #define BuildDir "x64"
#endif

#ifndef SourceRoot
  ; 本机仓库根目录。CI 通过 /DSourceRoot=${{ github.workspace }} 覆盖，
  ; 所以这里写绝对路径不影响流水线；换机器开发时改这一行即可。
  #define SourceRoot "E:\celechron-windows"
#endif

#ifndef StageDir
  ; 待打包的程序目录：flutter build 的 runner\Release，或含 VC++ 运行库的暂存目录
  #define StageDir SourceRoot + "\build\windows\" + BuildDir + "\runner\Release"
#endif

#ifndef OutputDir
  #define OutputDir SourceRoot + "\installer_output"
#endif

; ---- 按目标架构推导 Inno 的架构开关 ----
; ArchAllowed   给 ArchitecturesAllowed（可以用 *compatible 变体）
; Arch64Mode    给 ArchitecturesInstallIn64BitMode（只接受精确架构名，x86 不用该指令）

#if ArchLabel == "x64"
  #define ArchAllowed "x64compatible"
  #define Arch64Mode  "x64"
#elif ArchLabel == "arm64"
  ; 注意：不存在 "arm64compatible" 这个标识符（ISCC 会报
  ; Architecture identifier "arm64compatible" is invalid），
  ; x64compatible 才是合法的。arm64 用精确值。
  #define ArchAllowed "arm64"
  #define Arch64Mode  "arm64"
#elif ArchLabel == "x86"
  #define ArchAllowed "x86compatible"
#else
  #error ArchLabel 只支持 x64 / arm64 / x86，当前值无法识别
#endif

[Setup]
AppId={{8F1C4E52-3B7A-4D19-9E64-2A7C5B0D83F1}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#AppName} {#AppVersion}
UninstallDisplayIcon={app}\{#AppExeName}
OutputDir={#OutputDir}
OutputBaseFilename={#AppName}-{#AppVersion}-windows-{#ArchLabel}-setup
SetupIconFile={#SourceRoot}\windows\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 默认按用户安装（不弹 UAC）；也允许用户在向导里改为全机器安装
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed={#ArchAllowed}
#if ArchLabel != "x86"
ArchitecturesInstallIn64BitMode={#Arch64Mode}
#endif
MinVersion=10.0.17763
; 不用 Inno 的 Restart Manager 关应用：托盘常驻的应用(隐藏窗口)会让
; 文件占用检测与关闭等待在「准备安装」页长时间卡死。改为 [Code] 段里
; PrepareToInstall / InitializeUninstall 自己确定性地产判并 taskkill。
CloseApplications=no
RestartApplications=no
AllowNoIcons=yes
SetupLogging=yes

[Languages]
; 中文语言包随仓库提供（tool\languages\ChineseSimplified.isl）。
; 不要用 "compiler:Languages\ChineseSimplified.isl" —— Inno Setup 只内置英文，
; 中文包属于"用户贡献翻译"，官方安装包里没有，runner 上因此报
; "Couldn't open include file"。随仓库走就不依赖打包机的安装内容了。
Name: "chinesesimplified"; MessagesFile: "{#SourceRoot}\tool\languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标："; Flags: unchecked
Name: "urlprotocol"; Description: "注册 celechron:// 深链协议（用于桌面小组件跳转付款码）"; GroupDescription: "系统集成："

[Files]
; 整包安装（暂存目录里已含 VC++ 运行时 DLL）
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "使用说明.txt"

[InstallDelete]
; 先删掉可能存在的旧快捷方式再重建。旧 .lnk 会被 Windows 图标缓存住，
; 只更新目标 exe 的图标资源、沿用同名 .lnk，桌面可能一直显示旧图标。
; 删除后由 [Icons] 重新生成，配合安装结束时的图标缓存刷新，桌面图标才会更新。
Type: files; Name: "{autodesktop}\{#AppName}.lnk"
Type: files; Name: "{commondesktop}\{#AppName}.lnk"; Check: IsAdminInstallMode
Type: files; Name: "{group}\{#AppName}.lnk"

[Icons]
; 显式指定 IconFilename/IconIndex，避免依赖 shell 对目标的图标推断。
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; \
  IconFilename: "{app}\{#AppExeName}"; IconIndex: 0
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; \
  IconFilename: "{app}\{#AppExeName}"; IconIndex: 0; Tasks: desktopicon

[Registry]
; ---- celechron:// 深链协议 ----
; 桌面端这一项必须由安装器写入注册表，否则 AppLinks 收不到任何事件。
Root: HKA; Subkey: "Software\Classes\celechron"; ValueType: string; ValueName: ""; \
  ValueData: "URL:PCelechron Protocol"; Flags: uninsdeletekey; Tasks: urlprotocol
Root: HKA; Subkey: "Software\Classes\celechron"; ValueType: string; ValueName: "URL Protocol"; \
  ValueData: ""; Tasks: urlprotocol
Root: HKA; Subkey: "Software\Classes\celechron\DefaultIcon"; ValueType: string; ValueName: ""; \
  ValueData: "{app}\{#AppExeName},0"; Tasks: urlprotocol
Root: HKA; Subkey: "Software\Classes\celechron\shell\open\command"; ValueType: string; ValueName: ""; \
  ValueData: """{app}\{#AppExeName}"" ""%1"""; Tasks: urlprotocol

[Run]
; 刷新 shell 图标缓存，否则桌面/开始菜单可能继续显示旧图标。
; ie4uinit.exe -show 会重建图标缓存且不需要重启 explorer。
Filename: "{sys}\ie4uinit.exe"; Parameters: "-show"; Flags: runhidden
Filename: "{app}\{#AppExeName}"; Description: "立即运行 {#AppName}"; \
  Flags: nowait postinstall skipifsilent

[Code]
const
  // 同时覆盖旧版本镜像名 Celechron.exe（1.3.2 及更早）；
  // 'CELECHRON' 是 'PCELECHRON' 的子串，检测一次即可同时命中两者。
  AppImageNameOld = 'Celechron.exe';
  AppImageName = 'PCelechron.exe';

var
  RemoveDataPage: TInputOptionWizardPage;

function IsAppRunning(): Boolean;
var
  ResultCode: Integer;
  TempFile: String;
  ListContent: String;
begin
  Result := False;
  TempFile := ExpandConstant('{temp}\pcelechron_proclist.txt');
  Exec(ExpandConstant('{sys}\cmd.exe'),
    '/C tasklist /NH /FO CSV | findstr /I "celechron" > "' + TempFile + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if LoadStringFromFile(TempFile, ListContent) then
  begin
    if Pos(UpperCase('celechron'), UpperCase(ListContent)) > 0 then
      Result := True;
    DeleteFile(TempFile);
  end;
end;

function StopAppIfNeeded(const ForUninstall: Boolean): Boolean;
var
  ActionName: String;
  ResultCode: Integer;
  I: Integer;
begin
  Result := True;
  if not IsAppRunning() then Exit;

  if ForUninstall then
    ActionName := '卸载'
  else
    ActionName := '安装';

  if MsgBox('检测到 PCelechron 正在运行（可能在系统托盘中）。' + #13#10 +
            '继续' + ActionName + '将自动关闭它，是否继续？',
            mbConfirmation, MB_OKCANCEL) = IDCANCEL then
  begin
    Result := False;
    Exit;
  end;

  // 强杀是安全的：Hive 为追加写，应用启动时还会清理陈旧 .lock 文件。
  Exec(ExpandConstant('{sys}\taskkill.exe'),
    '/F /T /IM "' + AppImageName + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\taskkill.exe'),
    '/F /T /IM "' + AppImageNameOld + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // 最多等 10 秒确认进程退出，避免文件占用导致复制阶段报错。
  for I := 1 to 20 do
  begin
    if not IsAppRunning() then Break;
    Sleep(500);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not StopAppIfNeeded(False) then
    Result := '安装已取消。';
end;

function InitializeUninstall(): Boolean;
begin
  Result := StopAppIfNeeded(True);
end;

procedure InitializeWizard();
begin
  RemoveDataPage := CreateInputOptionPage(wpSelectTasks,
    '数据清理设置', '是否在卸载时删除本地数据',
    'PCelechron 的数据库保存在「文档」文件夹下（dbuser.hive 等）。' + #13#10 +
    '选择「是」表示卸载本程序时一并删除这些文件（登录信息与本地缓存会丢失，不可恢复）。' + #13#10 +
    '默认保留，卸载后可手动删除。',
    True, False);
  RemoveDataPage.Add('保留我的数据（推荐）');
  RemoveDataPage.Add('卸载时删除上述数据文件');
  RemoveDataPage.Values[0] := True;
end;

function GetRemoveData(): Boolean;
begin
  Result := RemoveDataPage.Values[1];
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Docs: String;
  Names: TArrayOfString;
  I: Integer;
  Found: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    if not GetRemoveData() then Exit;
    // 注意：[Code] 段是 Pascal 代码，注释只能用 // 或 { }，
    // 这里写 ; 会被当成语句开头，报 "Syntax error"。
    Docs := ExpandConstant('{userdocs}');
    SetArrayLength(Names, 7);
    Names[0] := 'dbuser.hive';
    Names[1] := 'dboptions.hive';
    Names[2] := 'dbdeadline.hive';
    Names[3] := 'dbflow.hive';
    Names[4] := 'dbfuse.hive';
    Names[5] := 'dbcustomgpa.hive';
    Names[6] := 'dboriginalwebpage.hive';
    Found := 0;
    for I := 0 to GetArrayLength(Names) - 1 do
    begin
      if FileExists(Docs + '\' + Names[I]) then
      begin
        if DeleteFile(Docs + '\' + Names[I]) then
          Found := Found + 1;
      end;
    end;
  end;
end;
