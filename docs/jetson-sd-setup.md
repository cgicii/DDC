# 젯슨 Orin Nano SD 카드 설치

작성일: 2026-09-27

## 결론

**Orin Nano 개발자 키트는 microSD 부팅이 표준이다. 단, 두 가지를 먼저 확인해야 한다.**

1. **펌웨어(QSPI) 버전** — 36.x 미만이면 JetPack 6.x SD 카드로 부팅되지 않는다. 먼저 펌웨어를 올려야 한다.
2. **JetPack 버전** — Orin Nano는 JetPack 6.2.2 가 현재 권장. JetPack 7.x 는 Orin Nano 미지원(AGX Thor 등 전용).

호스트(카드를 굽는 PC)별로:

- **Linux**: `tools/jetson/flash_sd.sh` (이 저장소, 의존성 없음)
- **Windows**: `tools/jetson/flash_sd.ps1` (관리자 PowerShell) 또는 Balena Etcher
- **macOS**: Balena Etcher

부팅 후 Jetson 본체에서 `tools/jetson/postinstall.sh` 로 전원 모드·서비스를 한 번에 설정한다.

준비물: Orin Nano 개발자 키트, **64GB 이상** microSD(UHS-I U3/A2 권장), 카드 리더, 5V/DC 어댑터, (펌웨어 확인용) 모니터·키보드.

## 1단계 — 펌웨어(QSPI) 버전 확인

microSD 를 굽기 전에 보드 펌웨어가 JetPack 6 를 받을 수 있는지부터 본다.

**부팅 화면에서 확인**: 전원을 넣고 NVIDIA 로고가 뜨면 `Esc` 를 반복해서 눌러 UEFI 설정 메뉴에 진입, 상단의 펌웨어 버전 줄을 본다.

**이미 리눅스가 떠 있으면**:

```bash
cat /sys/devices/virtual/dmi/id/bios_version
```

- **36.x 이상** → 3단계(SD 카드 굽기)로 바로 진행.
- **36.x 미만(구형 출고본)** → 2단계 펌웨어 업데이트 먼저.

## 2단계 — 펌웨어 업데이트 (필요할 때만)

펌웨어가 36.x 미만이면 JetPack 6 SD 카드로 곧바로 부팅되지 않는다. NVIDIA 공식 경로는 다음과 같다.

1. **JetPack 5.1.3** microSD 이미지로 부팅한다(브리지 단계).
2. 부팅 후 QSPI 업데이터 패키지를 설치한다.

   ```bash
   sudo apt-get update
   sudo apt-get install nvidia-l4t-jetson-orin-nano-qspi-updater
   ```

3. 안내대로 재부팅하면 UEFI 에서 QSPI 펌웨어가 갱신되고 화면이 멈춘다(완료 신호).
4. 전원을 끄고 **JetPack 6.x microSD 로 교체**한 뒤 3단계 결과물로 부팅한다.

> Linux 호스트가 있으면 SDK Manager 로 한 번에 플래시하는 방법도 있으나, 본 문서는 호스트 없이 SD 카드만으로 진행하는 경로를 기준으로 한다. 정확한 최신 절차와 패키지명은 NVIDIA "Jetson Orin Nano Developer Kit — JetPack 6.x Update Path" 문서를 확인한다.

## 3단계 — SD 카드 이미지 굽기

### 이미지 내려받기

NVIDIA JetPack 다운로드 페이지에서 **Jetson Orin Nano Developer Kit SD Card Image** (JetPack 6.2.1 기준)를 받는다. 페이지에 표기된 **SHA-256** 값을 함께 적어 둔다. (6.2.2 는 별도 SD 이미지가 없고, 6.2.1 로 부팅 후 `apt` 업그레이드한다 — 5단계.)

### Linux 호스트

```bash
# 카드 리더 연결 후, 대상 장치 확인
sudo ./tools/jetson/flash_sd.sh --list

# 굽기 + SHA 대조 + 기록 후 읽기 검증
sudo ./tools/jetson/flash_sd.sh \
    -i jp621-orin-nano-sd-card-image.zip \
    -d /dev/sdX \
    --sha256 <다운로드 페이지의 해시>
```

`-d` 에는 파티션(`/dev/sdX1`)이 아니라 **디스크 전체**(`/dev/sdX`)를 넣는다. 스크립트는 시스템 디스크·비이동식 디스크·용량 부족 카드를 거부하고, 장치 이름을 다시 입력해야 기록을 시작한다.

### Windows 호스트

관리자 PowerShell 에서:

```powershell
# 대상 디스크 번호 확인
.\tools\jetson\flash_sd.ps1 -List

# 굽기 (DiskNumber 는 위에서 확인한 번호)
.\tools\jetson\flash_sd.ps1 `
    -Image .\jp621-orin-nano-sd-card-image.zip `
    -DiskNumber 2 `
    -Sha256 <다운로드 페이지의 해시>
```

`.xz` 이미지는 7-Zip 등으로 먼저 풀거나 Balena Etcher 를 사용한다. GUI 를 선호하면 어느 OS든 **Balena Etcher** 가 NVIDIA 공식 안내 방법이다(검증 포함).

## 4단계 — 첫 부팅

1. 구운 카드를 **Jetson 모듈 아래 microSD 슬롯**에 꽂는다(캐리어 보드가 아니라 모듈 쪽).
2. 모니터·키보드·마우스·랜을 연결하고 전원을 넣는다.
3. oem-config 마법사(언어·키보드·시간대·계정)를 진행한다. 한국어 선택 가능.
4. 데스크톱 진입 후 버전을 확인한다.

   ```bash
   cat /etc/nv_tegra_release          # L4T(R36.x) 버전
   ```

## 5단계 — 설치 후 설정 (Jetson 본체에서)

이 저장소를 Jetson 으로 가져온 뒤:

```bash
# 전원 모드(MAXN SUPER) + 팬 + jtop + 브리지 서비스 한 번에
sudo ./tools/jetson/postinstall.sh --service

# 전원 모드만
sudo ./tools/jetson/postinstall.sh --power-only
```

`postinstall.sh` 가 하는 일:

- Jetson 하드웨어·L4T 버전 확인 (아니면 즉시 중단)
- `nvpmodel -m 0` 로 **MAXN SUPER** 전원 모드 고정 (JetPack 6.2+, 재부팅 후에도 유지)
- `jetson_clocks --fan` 팬 프로파일
- `jetson-stats`(jtop) 설치 — `sudo jtop` 로 모니터링
- `--service` 지정 시 `tools/point_bridge.py` 를 systemd 서비스(`ddc-point-bridge`)로 등록

JetPack 6.2.2 로 올리려면(6.2.1 이미지에서 부팅한 경우):

```bash
sudo apt-get update && sudo apt-get upgrade
```

## 검증 결과

`flash_sd.sh` 는 loop 장치(가짜 SD 카드)로 전 경로를 검증했다.

- `.img` / `.zip` 입력 → 기록 후 원본과 바이트 대조 통과
- 안전장치 동작 확인: SHA 불일치 거부, 파티션 지정 거부, 이동식 아님 거부, 용량 부족 거부
- `shellcheck` 경고 0건

`flash_sd.ps1` 은 Windows PowerShell 5.1+ 기준으로 작성했으며, 실제 Windows 하드웨어에서의 최종 확인이 남아 있다.

## 참고

각 스크립트는 `tools/jetson/lib/common.sh` 하나만 함께 복사하면 다른 프로젝트로 이식된다. 메시지는 `DDC_LANG=ko|en` 으로 전환되고, `MSG_<언어>` 배열만 추가하면 언어를 늘릴 수 있다.

버전 숫자(JetPack 6.2.2, 펌웨어 36.x 등)와 이미지 파일명·해시는 시점에 따라 바뀌므로, 실제 작업 전 NVIDIA 공식 다운로드 페이지와 Quick Start Guide 에서 최신 값을 확인한다.
