#!/usr/bin/env bash
# Jetson Orin Nano 첫 부팅 후 설정 스크립트 (Jetson 본체에서 실행)
#
# SD 카드로 JetPack 6.x 부팅을 마친 뒤, HMI/브리지를 올리기 전에 필요한
# 기본 설정을 한 번에 처리한다.
#
#   1. Jetson 하드웨어인지 + JetPack(L4T) 버전 확인
#   2. 전원 모드를 MAXN SUPER(0)로 고정 + 팬 프로파일 cool
#   3. jetson-stats(jtop) 설치 (모니터링, 선택)
#   4. point_bridge.py 를 systemd 서비스로 등록 (부팅 시 자동 실행, 선택)
#
# 산업용 기준: 모든 단계는 멱등(여러 번 실행해도 안전)하고, 실패해도
# 다음 단계로 넘어가지 않고 명확히 멈춘다.
#
# 사용법
#   sudo ./postinstall.sh                 # 대화형
#   sudo ./postinstall.sh --power-only    # 전원 모드만
#   sudo ./postinstall.sh --service --user hmi   # 브리지 서비스까지 등록
#   DDC_LANG=en sudo -E ./postinstall.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# shellcheck disable=SC2034  # msg() 가 간접 참조
declare -A MSG_ko=(
    [usage]="사용법: sudo %s [옵션]
      --power-only     전원 모드(MAXN SUPER)만 설정하고 종료
      --service        point_bridge.py 를 systemd 서비스로 등록
      --user <계정>    서비스 실행 계정 (기본: 현재 로그인 사용자)
      --port <포트>    브리지 포트 (기본: 8765)
      --no-jtop        jtop 설치 생략
      --yes            확인 입력 생략
"
    [not_jetson]="Jetson 하드웨어가 아닙니다 (%s). 이 스크립트는 Jetson 본체에서 실행하세요."
    [model]="장비 모델: %s"
    [l4t]="JetPack(L4T) 버전: %s"
    [no_l4t]="L4T 버전 파일을 찾을 수 없습니다. JetPack 이미지가 맞는지 확인하세요."
    [no_nvpmodel]="nvpmodel 이 없습니다. JetPack 정식 이미지가 아닐 수 있습니다."
    [pm_set]="전원 모드를 MAXN SUPER(0)로 설정합니다."
    [pm_now]="현재 전원 모드: %s"
    [pm_ok]="전원 모드 설정 완료 (재부팅 후에도 유지)."
    [fan_set]="팬 프로파일을 cool 로 설정합니다."
    [fan_skip]="jetson_clocks/fan 제어를 찾지 못해 팬 설정을 건너뜁니다."
    [jtop_inst]="jetson-stats(jtop) 설치 중..."
    [jtop_ok]="jtop 설치 완료. 'sudo jtop' 로 모니터링하세요."
    [jtop_skip]="jtop 설치 생략."
    [jtop_fail]="jtop 설치 실패 (네트워크 확인). 건너뜁니다."
    [svc_user]="서비스 실행 계정: %s"
    [svc_no_user]="계정이 없습니다: %s"
    [svc_no_bridge]="브리지 파일이 없습니다: %s"
    [svc_write]="systemd 유닛 작성: %s"
    [svc_ok]="서비스 등록 완료. 상태: systemctl status %s"
    [svc_started]="서비스 시작됨: %s (포트 %s)"
    [done]="첫 부팅 설정 완료."
    [reboot_hint]="전원 모드를 처음 바꾼 경우 'sudo reboot' 로 재부팅하면 확실합니다."
)
# shellcheck disable=SC2034
declare -A MSG_en=(
    [usage]="Usage: sudo %s [options]
      --power-only     Set power mode (MAXN SUPER) only, then exit
      --service        Register point_bridge.py as a systemd service
      --user <name>    Service account (default: current login user)
      --port <port>    Bridge port (default: 8765)
      --no-jtop        Skip jtop installation
      --yes            Skip confirmation
"
    [not_jetson]="Not Jetson hardware (%s). Run this on the Jetson itself."
    [model]="Board model: %s"
    [l4t]="JetPack (L4T) version: %s"
    [no_l4t]="L4T version file not found. Is this a JetPack image?"
    [no_nvpmodel]="nvpmodel not found. This may not be an official JetPack image."
    [pm_set]="Setting power mode to MAXN SUPER (0)."
    [pm_now]="Current power mode: %s"
    [pm_ok]="Power mode set (persists across reboots)."
    [fan_set]="Setting fan profile to cool."
    [fan_skip]="jetson_clocks/fan control not found; skipping fan setup."
    [jtop_inst]="Installing jetson-stats (jtop)..."
    [jtop_ok]="jtop installed. Monitor with 'sudo jtop'."
    [jtop_skip]="Skipping jtop installation."
    [jtop_fail]="jtop install failed (check network). Skipping."
    [svc_user]="Service account: %s"
    [svc_no_user]="No such account: %s"
    [svc_no_bridge]="Bridge file not found: %s"
    [svc_write]="Writing systemd unit: %s"
    [svc_ok]="Service registered. Status: systemctl status %s"
    [svc_started]="Service started: %s (port %s)"
    [done]="First-boot setup complete."
    [reboot_hint]="If you changed the power mode for the first time, 'sudo reboot' to be safe."
)

POWER_ONLY=0 DO_SERVICE=0 DO_JTOP=1 SVC_USER="" SVC_PORT=8765
SVC_NAME="ddc-point-bridge"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --power-only) POWER_ONLY=1; shift ;;
            --service)    DO_SERVICE=1; shift ;;
            --user)       SVC_USER="${2:-}"; shift 2 ;;
            --port)       SVC_PORT="${2:-8765}"; shift 2 ;;
            --no-jtop)    DO_JTOP=0; shift ;;
            --yes)        ASSUME_YES=1; export ASSUME_YES; shift ;;
            -h|--help)    msg usage "$0"; exit 0 ;;
            *) die err_cmd "$1" ;;
        esac
    done
}

check_jetson() {
    local compat=/proc/device-tree/compatible
    if [[ ! -r "$compat" ]] || ! tr '\0' '\n' < "$compat" | grep -qi 'nvidia,tegra\|nvidia,jetson\|nvidia,p3768\|nvidia,orin'; then
        die not_jetson "$(uname -m)"
    fi
    local model="?"
    [[ -r /proc/device-tree/model ]] && model="$(tr -d '\0' < /proc/device-tree/model)"
    log_info model "$model"

    if [[ -r /etc/nv_tegra_release ]]; then
        log_info l4t "$(head -1 /etc/nv_tegra_release)"
    else
        log_warn no_l4t
    fi
}

set_power_mode() {
    command -v nvpmodel >/dev/null 2>&1 || die no_nvpmodel
    log_info pm_set
    # 0 = MAXN SUPER (JetPack 6.2+). 이미 0이어도 재실행 무해(멱등).
    nvpmodel -m 0
    log_info pm_now "$(nvpmodel -q 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
    log_info pm_ok

    if command -v jetson_clocks >/dev/null 2>&1; then
        log_info fan_set
        jetson_clocks --fan 2>/dev/null || jetson_clocks || true
    else
        log_warn fan_skip
    fi
}

install_jtop() {
    [[ $DO_JTOP -eq 1 ]] || { log_info jtop_skip; return; }
    if command -v jtop >/dev/null 2>&1; then
        log_info jtop_ok; return
    fi
    log_info jtop_inst
    if command -v pip3 >/dev/null 2>&1 && pip3 install -U jetson-stats >/dev/null 2>&1; then
        log_info jtop_ok
    else
        log_warn jtop_fail
    fi
}

register_service() {
    [[ $DO_SERVICE -eq 1 ]] || return 0
    [[ -z "$SVC_USER" ]] && SVC_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
    id "$SVC_USER" >/dev/null 2>&1 || die svc_no_user "$SVC_USER"
    log_info svc_user "$SVC_USER"

    local bridge="$REPO_DIR/tools/point_bridge.py"
    [[ -f "$bridge" ]] || die svc_no_bridge "$bridge"

    local py; py="$(command -v python3)"
    local unit="/etc/systemd/system/${SVC_NAME}.service"
    log_info svc_write "$unit"
    cat > "$unit" <<EOF
[Unit]
Description=DDC HMI point bridge (TCP device <-> WebSocket screen)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
WorkingDirectory=$REPO_DIR
ExecStart=$py $bridge --port $SVC_PORT
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SVC_NAME" >/dev/null 2>&1
    systemctl restart "$SVC_NAME"
    log_info svc_started "$SVC_NAME" "$SVC_PORT"
    log_info svc_ok "$SVC_NAME"
}

main() {
    parse_args "$@"
    require_root
    check_jetson
    set_power_mode
    [[ $POWER_ONLY -eq 1 ]] && { log_info "done"; exit 0; }
    install_jtop
    register_service
    log_info "done"
    log_info reboot_hint
}

main "$@"
