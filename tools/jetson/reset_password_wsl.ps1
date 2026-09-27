<#
.SYNOPSIS
    Windows 11 에서 젯슨 SD 카드의 사용자 비밀번호를 한 번에 초기화 (원스톱)

.DESCRIPTION
    아래 과정을 명령 한 줄로 자동 수행한다.
      1. USB 로 연결된 젯슨 SD 카드(디스크) 자동 탐지
      2. WSL2 로 루트(ext4) 파티션 마운트 (partition 1..N 자동 탐색)
      3. reset_password.sh 로 /etc/shadow 의 비번 초기화 (수정 전 백업)
      4. 마운트 해제

    이 스크립트는 같은 폴더의 reset_password.sh 를 호출한다.
    WSL2 가 설치돼 있어야 한다 (없으면 관리자 PowerShell 에서 `wsl --install`).

    반드시 관리자 PowerShell 에서 실행한다.

.PARAMETER Username
    초기화할 계정. 기본값 nvidia.

.PARAMETER NewPassword
    설정할 새 비밀번호. -Blank 와 함께 쓰면 안 됨.

.PARAMETER Blank
    비번을 제거(콘솔 무암호). 부팅 후 즉시 passwd 로 재설정.

.PARAMETER DiskNumber
    대상 디스크 번호를 직접 지정 (생략 시 자동 탐지, 여러 개면 목록 표시).

.PARAMETER ListUsers
    카드의 로그인 가능 사용자만 출력하고 종료.

.EXAMPLE
    .\reset_password_wsl.ps1 -Username nvidia -NewPassword 'jetson123'

.EXAMPLE
    .\reset_password_wsl.ps1 -ListUsers

.NOTES
    종료 코드: 0 성공 / 1 오류 / 2 사용법
#>
[CmdletBinding()]
param(
    [string]$Username = 'nvidia',
    [string]$NewPassword,
    [switch]$Blank,
    [int]$DiskNumber = -1,
    [switch]$ListUsers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "[정보] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[주의] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[오류] $m" -ForegroundColor Red; exit 1 }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Fail '관리자 권한 PowerShell 에서 실행하세요. (시작 > PowerShell > 관리자 권한으로 실행)'
}

# --- WSL2 확인 ------------------------------------------------------------
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wsl) { Fail 'WSL 이 설치돼 있지 않습니다. 관리자 PowerShell 에서 "wsl --install" 후 재부팅하세요.' }
$distros = (& wsl.exe -l -q) 2>$null | Where-Object { $_ -and $_.Trim() -ne '' }
if (-not $distros) { Fail 'WSL 배포판이 없습니다. "wsl --install -d Ubuntu" 로 설치하세요.' }

# --- reset_password.sh 경로 (같은 폴더) → WSL 경로 -----------------------
$shWin = Join-Path $PSScriptRoot 'reset_password.sh'
if (-not (Test-Path -LiteralPath $shWin)) { Fail "reset_password.sh 를 찾을 수 없습니다: $shWin" }
$shWsl = (& wsl.exe wslpath -a "$shWin").Trim()

# --- 대상 디스크 선택 -----------------------------------------------------
function Get-CardDisks {
    Get-Disk | Where-Object { $_.BusType -in 'USB','SD','MMC' -and -not $_.IsBoot -and -not $_.IsSystem }
}

if ($DiskNumber -lt 0) {
    $cands = @(Get-CardDisks)
    if ($cands.Count -eq 0) {
        Fail 'USB/SD 이동식 디스크가 없습니다. 카드 리더 연결을 확인하세요.'
    } elseif ($cands.Count -eq 1) {
        $DiskNumber = $cands[0].Number
        Info ("카드 자동 선택: 디스크 {0}  {1}  {2}GB" -f $DiskNumber, $cands[0].FriendlyName, [int]($cands[0].Size/1GB))
    } else {
        Warn '이동식 디스크가 여러 개입니다. -DiskNumber 로 지정하세요:'
        $cands | Select-Object Number, FriendlyName,
            @{N='GB'; E={[int]($_.Size/1GB)}}, BusType | Format-Table -AutoSize | Out-String | Write-Host
        exit 2
    }
} else {
    $d = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if (-not $d) { Fail "디스크 $DiskNumber 를 찾을 수 없습니다." }
    if ($d.IsBoot -or $d.IsSystem) { Fail "디스크 $DiskNumber 는 시스템/부팅 디스크입니다. 거부합니다." }
}

$phys = "\\.\PHYSICALDRIVE$DiskNumber"

# --- 마운트 (루트 파티션 자동 탐색) --------------------------------------
$mount = $null
$mountedPart = $null
try {
    # 후보 파티션 번호: Get-Partition 결과 우선, 없으면 1..4
    $parts = @()
    try { $parts = @((Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop).PartitionNumber) } catch {}
    if ($parts.Count -eq 0) { $parts = @(1, 2, 3, 4) }

    foreach ($p in $parts) {
        Info "파티션 $p 마운트 시도..."
        # 이전 시도가 남아있을 수 있으니 정리
        & wsl.exe --unmount $phys 2>$null | Out-Null
        $out = & wsl.exe --mount $phys --partition $p --type ext4 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Verbose ($out -join "`n"); continue }

        $mp = "/mnt/wsl/PHYSICALDRIVE${DiskNumber}p${p}"
        & wsl.exe -u root test -f "$mp/etc/shadow" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $mount = $mp; $mountedPart = $p
            Info "루트 파일시스템 발견: 파티션 $p ($mp)"
            break
        }
        & wsl.exe --unmount $phys 2>$null | Out-Null
    }
    if (-not $mount) {
        Fail '루트 파일시스템(/etc/shadow) 이 있는 ext4 파티션을 찾지 못했습니다. 젯슨 카드가 맞는지 확인하세요.'
    }

    # --- reset_password.sh 실행 (root 로) --------------------------------
    if ($ListUsers) {
        & wsl.exe -u root bash "$shWsl" --root "$mount" --list-users
    } elseif ($Blank) {
        & wsl.exe -u root bash "$shWsl" --root "$mount" --user "$Username" --blank --yes
    } else {
        if (-not $NewPassword) { Fail '-NewPassword 를 지정하거나 -Blank / -ListUsers 를 쓰세요.' }
        & wsl.exe -u root bash "$shWsl" --root "$mount" --user "$Username" --set "$NewPassword" --yes
    }
    $rc = $LASTEXITCODE
    & wsl.exe -u root sync 2>$null | Out-Null
    if ($rc -ne 0) { Fail "reset_password.sh 실패 (코드 $rc)." }
}
finally {
    if ($mount) {
        Info '마운트 해제 중...'
        & wsl.exe --unmount $phys 2>$null | Out-Null
    }
}

if (-not $ListUsers) {
    Info '완료. 카드를 빼서 젯슨에 다시 꽂고 부팅한 뒤 새 비번으로 로그인하세요.'
    if ($Blank) { Warn '무암호로 설정했습니다. 부팅 후 즉시 "passwd" 로 새 비번을 지정하세요.' }
}
