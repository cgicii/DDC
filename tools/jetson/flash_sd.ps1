<#
.SYNOPSIS
    Jetson Orin Nano 개발자 키트용 microSD 카드 기록 스크립트 (Windows 호스트용)

.DESCRIPTION
    flash_sd.sh(Linux) 의 Windows 대응판. NVIDIA SD 카드 이미지(.zip / .img)를
    microSD 에 기록하고 읽어서 대조 검증한다.

    안전장치 (실수로 시스템/자료 디스크를 날리지 않도록)
      - 이동식(USB/SD) 디스크만 허용. 시스템·고정 디스크는 -AllowFixed 없이 거부
      - 부팅 디스크는 항상 거부
      - 이미지보다 작은 카드 거부
      - 대상 디스크 번호를 그대로 다시 입력해야 기록 시작
      - -Sha256 지정 시 기록 전 다운로드 무결성 대조

    반드시 관리자 PowerShell 에서 실행한다.
    .xz 이미지는 7-Zip 등으로 먼저 풀거나 Balena Etcher 를 쓴다.

.EXAMPLE
    # 기록 가능한 이동식 디스크 목록
    .\flash_sd.ps1 -List

.EXAMPLE
    # 2번 디스크에 기록 (디스크 번호는 -List 로 확인)
    .\flash_sd.ps1 -Image .\jp62-orin-nano-sd-card-image.zip -DiskNumber 2 -Sha256 <해시>

.NOTES
    영문 메시지: 환경변수 DDC_LANG=en
    종료 코드: 0 성공 / 1 오류 / 2 사용법 / 3 검증 실패
#>
[CmdletBinding(DefaultParameterSetName = 'Flash')]
param(
    [Parameter(ParameterSetName = 'List')]
    [switch]$List,

    [Parameter(ParameterSetName = 'Flash', Mandatory = $true)]
    [string]$Image,

    [Parameter(ParameterSetName = 'Flash', Mandatory = $true)]
    [int]$DiskNumber,

    [Parameter(ParameterSetName = 'Flash')]
    [string]$Sha256,

    [Parameter(ParameterSetName = 'Flash')]
    [switch]$NoVerify,

    [Parameter(ParameterSetName = 'Flash')]
    [switch]$Yes,

    [Parameter(ParameterSetName = 'Flash')]
    [switch]$AllowFixed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- 다국어 메시지 -------------------------------------------------------
$Lang = if ($env:DDC_LANG) { $env:DDC_LANG } else { 'ko' }
$MSG_ko = @{
    need_admin = '관리자 권한 PowerShell 에서 실행하세요. (시작 > PowerShell > 관리자 권한으로 실행)'
    list_head  = '기록 가능한 이동식 디스크:'
    list_none  = '이동식 디스크가 없습니다. SD 카드 리더를 연결했는지 확인하세요.'
    no_img     = '이미지 파일이 없습니다: {0}'
    bad_ext    = '지원하지 않는 형식입니다: {0} (.zip / .img). .xz 는 먼저 풀거나 Balena Etcher 사용.'
    zip_n      = 'zip 안에 .img 파일이 정확히 1개여야 합니다 (발견: {0}개).'
    extracting = 'zip 에서 이미지 추출 중: {0}'
    img_info   = '이미지: {0} ({1:N0} 바이트)'
    no_disk    = '{0}번 디스크를 찾을 수 없습니다. -List 로 번호를 확인하세요.'
    is_boot    = '부팅 디스크입니다. 기록을 거부합니다: 디스크 {0}'
    is_system  = '시스템/고정 디스크입니다: 디스크 {0} (BusType={1}). 확실하면 -AllowFixed'
    disk_info  = '대상: 디스크 {0}  {1}  {2:N0} 바이트  BusType={3}'
    too_small  = '카드 용량 부족: 카드 {0:N0} < 이미지 {1:N0} 바이트'
    sha_run    = 'SHA-256 계산 중 (수 분 소요)...'
    sha_ok     = 'SHA-256 일치'
    sha_bad    = "SHA-256 불일치 — 다운로드 손상.`n  기대값: {0}`n  실제값: {1}"
    sha_skip   = '-Sha256 미지정: 다운로드 무결성 확인 생략.'
    warn_all   = '디스크 {0} 의 모든 데이터가 삭제됩니다.'
    prompt     = '계속하려면 디스크 번호({0})를 그대로 입력하세요: '
    abort      = '입력이 일치하지 않아 중단합니다.'
    clearing   = '기존 파티션 제거 중...'
    writing    = '기록 중... (64GB급 카드 기준 10~30분, 진행률 표시)'
    write_ok   = '기록 완료'
    verifying  = '검증 중: 카드를 다시 읽어 이미지와 대조...'
    verify_ok  = '검증 통과 ({0:N0} 바이트 일치)'
    verify_bad = '검증 실패: {0} 바이트 지점부터 다릅니다. 카드를 교체하고 다시 기록하세요.'
    verify_skip= '-NoVerify: 검증 생략.'
    done       = '완료. 카드를 빼서 Jetson 모듈 아래 microSD 슬롯에 꽂으세요.'
    write_fail = '기록 실패: {0}'
}
$MSG_en = @{
    need_admin = 'Run in an elevated PowerShell (Start > PowerShell > Run as administrator).'
    list_head  = 'Removable disks available for flashing:'
    list_none  = 'No removable disk found. Is the SD card reader connected?'
    no_img     = 'Image not found: {0}'
    bad_ext    = 'Unsupported format: {0} (.zip / .img). Extract .xz first or use Balena Etcher.'
    zip_n      = 'The zip must contain exactly one .img (found: {0}).'
    extracting = 'Extracting image from zip: {0}'
    img_info   = 'Image: {0} ({1:N0} bytes)'
    no_disk    = 'Disk {0} not found. Check the number with -List.'
    is_boot    = 'Boot disk, refusing to write: disk {0}'
    is_system  = 'System/fixed disk: disk {0} (BusType={1}). Use -AllowFixed if sure.'
    disk_info  = 'Target: disk {0}  {1}  {2:N0} bytes  BusType={3}'
    too_small  = 'Card too small: card {0:N0} < image {1:N0} bytes'
    sha_run    = 'Computing SHA-256 (takes minutes)...'
    sha_ok     = 'SHA-256 matches'
    sha_bad    = "SHA-256 mismatch - download corrupted.`n  expected: {0}`n  actual:   {1}"
    sha_skip   = 'No -Sha256 given: skipping integrity check.'
    warn_all   = 'ALL data on disk {0} will be erased.'
    prompt     = 'Type the disk number ({0}) to continue: '
    abort      = 'Input did not match. Aborting.'
    clearing   = 'Clearing existing partitions...'
    writing    = 'Writing... (10-30 min for a 64GB-class card)'
    write_ok   = 'Write complete'
    verifying  = 'Verifying: reading the card back and comparing...'
    verify_ok  = 'Verification passed ({0:N0} bytes match)'
    verify_bad = 'Verification failed: differs at byte {0}. Replace the card and retry.'
    verify_skip= '-NoVerify: verification skipped.'
    done       = 'Done. Insert the card into the microSD slot under the Jetson module.'
    write_fail = 'Write failed: {0}'
}

function M([string]$key) {
    $tbl = if ($Lang -eq 'en') { $MSG_en } else { $MSG_ko }
    $fmt = $tbl[$key]; if (-not $fmt) { $fmt = $MSG_ko[$key] }; if (-not $fmt) { return $key }
    $rest = @($args)
    if ($rest.Count -gt 0) { return ($fmt -f $rest) } else { return $fmt }
}
function Info([string]$k) { Write-Host ("[정보] " + (M $k @args)) -ForegroundColor Green }
function Warn([string]$k) { Write-Host ("[주의] " + (M $k @args)) -ForegroundColor Yellow }
function Die([string]$k)  { Write-Host ("[오류] " + (M $k @args)) -ForegroundColor Red; exit 1 }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RemovableDisks {
    Get-Disk | Where-Object {
        $_.BusType -eq 'USB' -or $_.BusType -eq 'SD' -or $_.BusType -eq 'MMC'
    }
}

function Show-List {
    Info list_head
    $d = Get-RemovableDisks
    if (-not $d) { Warn list_none; return }
    $d | Select-Object Number,
        @{N='Model'; E={ $_.FriendlyName }},
        @{N='SizeGB'; E={ [math]::Round($_.Size / 1GB, 1) }},
        BusType, IsBoot, IsSystem |
        Format-Table -AutoSize | Out-String | Write-Host
}

# ---- 이미지 준비 (.zip 이면 임시폴더에 추출) -----------------------------
function Resolve-Image([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { Die no_img $path }
    $full = (Resolve-Path -LiteralPath $path).Path
    $ext = [IO.Path]::GetExtension($full).ToLower()
    switch ($ext) {
        '.img' { return @{ Path = $full; Temp = $null } }
        '.zip' {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($full)
            try {
                $imgs = @($zip.Entries | Where-Object { $_.FullName.ToLower().EndsWith('.img') })
                if ($imgs.Count -ne 1) { Die zip_n $imgs.Count }
                $tmpDir = Join-Path $env:TEMP ("ddc-sd-" + [guid]::NewGuid().ToString('N').Substring(0,8))
                New-Item -ItemType Directory -Path $tmpDir | Out-Null
                $out = Join-Path $tmpDir ([IO.Path]::GetFileName($imgs[0].FullName))
                Info extracting $out
                [IO.Compression.ZipFileExtensions]::ExtractToFile($imgs[0], $out, $true)
                return @{ Path = $out; Temp = $tmpDir }
            } finally { $zip.Dispose() }
        }
        default { Die bad_ext $full }
    }
}

# ---- 원시 디스크 쓰기/검증 ------------------------------------------------
function Write-Raw([string]$imgPath, [int]$disk, [long]$imgSize, [bool]$verify) {
    $devPath = "\\.\PHYSICALDRIVE$disk"
    $bufSize = 4MB
    $buf = New-Object byte[] $bufSize

    Info clearing
    # 볼륨 잠금 해제 + 파티션 제거 (diskpart 대신 Storage 모듈)
    Get-Disk -Number $disk | Set-Disk -IsOffline $true
    Get-Disk -Number $disk | Set-Disk -IsReadOnly $false
    Clear-Disk -Number $disk -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
    Get-Disk -Number $disk | Set-Disk -IsOffline $true   # Clear-Disk 가 online 시킬 수 있음

    Info writing
    $src = [IO.File]::OpenRead($imgPath)
    $dst = New-Object IO.FileStream($devPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        [long]$written = 0
        while (($n = $src.Read($buf, 0, $bufSize)) -gt 0) {
            # 물리 디스크 쓰기는 섹터(512B) 배수여야 한다. 마지막 조각 패딩.
            if ($n -lt $bufSize -and ($n % 512) -ne 0) {
                $pad = 512 - ($n % 512)
                [Array]::Clear($buf, $n, $pad)
                $n += $pad
            }
            $dst.Write($buf, 0, $n)
            $written += $n
            if ($imgSize -gt 0) {
                Write-Progress -Activity (M writing) -Status ("{0:N0} / {1:N0}" -f $written, $imgSize) `
                    -PercentComplete ([math]::Min(100, $written * 100 / $imgSize))
            }
        }
        $dst.Flush()
    } catch {
        Die write_fail $_.Exception.Message
    } finally {
        $dst.Dispose(); $src.Dispose()
        Write-Progress -Activity (M writing) -Completed
    }
    Info write_ok

    if (-not $verify) { Warn verify_skip; return }

    Info verifying
    $a = [IO.File]::OpenRead($imgPath)
    $b = New-Object IO.FileStream($devPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $ba = New-Object byte[] $bufSize
        $bb = New-Object byte[] $bufSize
        [long]$pos = 0
        while (($n = $a.Read($ba, 0, $bufSize)) -gt 0) {
            $off = 0
            while ($off -lt $n) {
                $r = $b.Read($bb, $off, $n - $off)
                if ($r -le 0) { break }
                $off += $r
            }
            for ($i = 0; $i -lt $n; $i++) {
                if ($ba[$i] -ne $bb[$i]) { Write-Host ("[오류] " + (M verify_bad ($pos + $i))) -ForegroundColor Red; exit 3 }
            }
            $pos += $n
        }
        Info verify_ok $pos
    } finally { $a.Dispose(); $b.Dispose() }
}

# ============================ 진입점 ======================================
if (-not (Test-Admin)) { Die need_admin }

if ($List -or $PSCmdlet.ParameterSetName -eq 'List') { Show-List; exit 0 }

$img = Resolve-Image $Image
try {
    $imgSize = (Get-Item -LiteralPath $img.Path).Length
    Info img_info $img.Path $imgSize

    $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if (-not $disk) { Die no_disk $DiskNumber }
    if ($disk.IsBoot) { Die is_boot $DiskNumber }
    if (($disk.BusType -notin 'USB','SD','MMC') -and -not $AllowFixed) {
        Die is_system $DiskNumber $disk.BusType
    }
    Info disk_info $DiskNumber $disk.FriendlyName $disk.Size $disk.BusType
    if ($disk.Size -lt $imgSize) { Die too_small $disk.Size $imgSize }

    if ($Sha256) {
        Info sha_run
        $actual = (Get-FileHash -LiteralPath (Resolve-Path -LiteralPath $Image).Path -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $Sha256.ToLower()) { Die sha_bad $Sha256.ToLower() $actual }
        Info sha_ok
    } else { Warn sha_skip }

    Warn warn_all $DiskNumber
    if (-not $Yes) {
        $ans = Read-Host (M prompt $DiskNumber)
        if ($ans -ne "$DiskNumber") { Die abort }
    }

    Write-Raw $img.Path $DiskNumber $imgSize (-not $NoVerify)

    # 카드를 다시 온라인/제거하기 좋은 상태로
    Get-Disk -Number $DiskNumber | Set-Disk -IsOffline $false -ErrorAction SilentlyContinue
    Info done
} finally {
    if ($img.Temp -and (Test-Path -LiteralPath $img.Temp)) {
        Remove-Item -LiteralPath $img.Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
