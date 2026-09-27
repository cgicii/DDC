#!/usr/bin/env bash
# Jetson (및 일반 리눅스) 루트 파일시스템의 사용자 비밀번호 초기화 도구
#
# 비번을 잊어 로그인할 수 없을 때, 재설치하지 않고 초기화한다.
# 부팅된 시스템이 아니라 "마운트된 루트 파일시스템"을 직접 손대므로
# 다음 두 상황 모두에서 쓸 수 있다.
#
#   - Windows 11 WSL2 에서 카드를 마운트한 경우
#       wsl --mount \\.\PHYSICALDRIVE2 --partition 1 --type ext4
#       → /mnt/wsl/PHYSICALDRIVE2p1 을 --root 로 지정
#   - 다른 리눅스 PC 에서 카드 리더로 마운트한 경우
#       sudo mount /dev/sdX1 /mnt/card → /mnt/card 를 --root 로 지정
#   - Jetson 자체 복구(single) 셸: --root / (루트가 rw 로 마운트돼 있어야 함)
#
# 안전장치
#   - 대상이 진짜 루트 파일시스템인지(etc/shadow, etc/passwd 존재) 확인
#   - 사용자가 실제로 있는지 확인
#   - 수정 전 shadow 를 타임스탬프 백업
#   - 기본은 "비번 없음"이 아니라 새 비번 설정 권장. --blank 는 명시해야만.
#
# 사용법
#   sudo ./reset_password.sh --root /mnt/wsl/PHYSICALDRIVE2p1 --list-users
#   sudo ./reset_password.sh --root /mnt/card --user nvidia --set '새비번'
#   sudo ./reset_password.sh --root /mnt/card --user nvidia --blank   # 콘솔 무암호
#   sudo ./reset_password.sh --root /mnt/card --user nvidia --unlock  # 잠금(!)만 해제
#
# 종료: 0 성공 / 1 오류 / 2 사용법

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# shellcheck disable=SC2034  # msg() 가 간접 참조
declare -A MSG_ko=(
    [usage]="사용법: sudo %s --root <루트마운트> [옵션]
      --root <경로>     대상 루트 파일시스템 마운트 지점 (필수)
      --user <계정>     초기화할 사용자
      --set <새비번>    새 비밀번호 설정 (권장)
      --blank           비밀번호 제거 (콘솔에서 무암호 로그인)
      --unlock          계정 잠금(!)만 해제, 해시는 유지
      --list-users      로그인 가능한 사용자 목록만 출력
      --yes             확인 생략
"
    [err_need_root_opt]="--root 는 필수입니다."
    [err_not_rootfs]="루트 파일시스템이 아닙니다: %s (etc/shadow 없음)"
    [err_need_user]="--user 를 지정하세요 (--list-users 로 목록 확인)."
    [err_no_user]="사용자를 찾을 수 없습니다: %s"
    [err_action]="--set / --blank / --unlock 중 하나를 지정하세요."
    [err_no_hash]="해시 생성 도구가 없습니다 (openssl 또는 python3 필요)."
    [users_head]="로그인 가능한 사용자 (셸이 nologin/false 가 아닌 계정):"
    [target]="대상 루트: %s"
    [backup]="백업 생성: %s"
    [cur]="현재 %s 의 shadow 상태: %s"
    [do_set]="%s 의 비밀번호를 새 값으로 설정합니다."
    [do_blank]="%s 의 비밀번호를 제거합니다(무암호). 첫 로그인 후 바로 새로 설정하세요."
    [do_unlock]="%s 의 계정 잠금을 해제합니다."
    [confirm]="계속하려면 사용자명(%s)을 입력하세요: "
    [abort]="확인 불일치로 중단합니다."
    [ok]="완료: %s. 카드를 Jetson 에 꽂고 부팅해 로그인하세요."
    [ok_blank]="완료: %s 무암호. 부팅 후 즉시 'passwd' 로 새 비번을 설정하세요."
    [warn_ssh]="참고: 무암호 계정은 SSH 로그인이 막힐 수 있습니다. 콘솔(모니터)에서 로그인하세요."
    [locked]="잠김(!)"
    [empty]="비어있음"
    [set_hash]="해시 설정됨"
)
# shellcheck disable=SC2034
declare -A MSG_en=(
    [usage]="Usage: sudo %s --root <rootfs-mount> [options]
      --root <path>     Target rootfs mount point (required)
      --user <name>     User to reset
      --set <newpass>   Set a new password (recommended)
      --blank           Remove password (passwordless console login)
      --unlock          Only clear account lock (!), keep the hash
      --list-users      Print login-capable users and exit
      --yes             Skip confirmation
"
    [err_need_root_opt]="--root is required."
    [err_not_rootfs]="Not a rootfs: %s (no etc/shadow)"
    [err_need_user]="Specify --user (see --list-users)."
    [err_no_user]="User not found: %s"
    [err_action]="Specify one of --set / --blank / --unlock."
    [err_no_hash]="No hashing tool (need openssl or python3)."
    [users_head]="Login-capable users (shell not nologin/false):"
    [target]="Target root: %s"
    [backup]="Backup created: %s"
    [cur]="Current shadow state of %s: %s"
    [do_set]="Setting a new password for %s."
    [do_blank]="Removing the password for %s (passwordless). Set a new one right after first login."
    [do_unlock]="Unlocking account %s."
    [confirm]="Type the username (%s) to continue: "
    [abort]="Confirmation mismatch. Aborting."
    [ok]="Done: %s. Insert the card into the Jetson and log in."
    [ok_blank]="Done: %s passwordless. Run 'passwd' immediately after boot."
    [warn_ssh]="Note: passwordless accounts may be blocked over SSH. Log in on the console."
    [locked]="locked (!)"
    [empty]="empty"
    [set_hash]="hash set"
)

ROOT="" USER_NAME="" NEWPASS="" ACTION="" LIST=0

parse_args() {
    [[ $# -eq 0 ]] && { msg usage "$0"; exit 2; }
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)       ROOT="${2:-}"; shift 2 ;;
            --user)       USER_NAME="${2:-}"; shift 2 ;;
            --set)        NEWPASS="${2:-}"; ACTION="set"; shift 2 ;;
            --blank)      ACTION="blank"; shift ;;
            --unlock)     ACTION="unlock"; shift ;;
            --list-users) LIST=1; shift ;;
            --yes)        ASSUME_YES=1; export ASSUME_YES; shift ;;
            -h|--help)    msg usage "$0"; exit 0 ;;
            *) die err_cmd "$1" ;;
        esac
    done
    [[ -n "$ROOT" ]] || { log_err err_need_root_opt; exit 2; }
}

SHADOW="" PASSWD=""
check_root_fs() {
    ROOT="${ROOT%/}"; [[ -z "$ROOT" ]] && ROOT="/"
    SHADOW="$ROOT/etc/shadow"; PASSWD="$ROOT/etc/passwd"
    [[ -f "$SHADOW" && -f "$PASSWD" ]] || die err_not_rootfs "$ROOT"
    log_info target "$ROOT"
}

list_users() {
    msg users_head; echo
    # UID>=1000 또는 root, 그리고 셸이 nologin/false 가 아닌 계정
    awk -F: '($3==0 || $3>=1000) && $7!~/(nologin|false)$/ {printf "  %s (uid=%s, shell=%s)\n",$1,$3,$7}' "$PASSWD"
    echo
}

user_exists() { awk -F: -v u="$1" '$1==u{f=1} END{exit !f}' "$PASSWD"; }

shadow_state() {  # 현재 비번 필드 상태를 사람이 읽게
    local f; f="$(awk -F: -v u="$USER_NAME" '$1==u{print $2}' "$SHADOW")"
    case "$f" in
        ""|"!"|"*")            msg "$( [[ "$f" == "" ]] && echo empty || echo locked )" ;;
        "!"*|"*"*)             printf '%s' "$(msg locked)" ;;
        *)                     msg set_hash ;;
    esac
}

make_hash() {  # SHA-512 crypt 해시 생성
    local p="$1"
    if command -v openssl >/dev/null 2>&1; then
        openssl passwd -6 "$p"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))' "$p"
    else
        return 1
    fi
}

# shadow 의 사용자 행 2번째 필드(비번)를 새 값으로 교체. 안전하게 임시파일→이동.
set_field() {
    local newfield="$1" tmp
    tmp="$(mktemp)"
    USER_NAME="$USER_NAME" NF="$newfield" awk -F: 'BEGIN{OFS=":"}
        $1==ENVIRON["USER_NAME"]{$2=ENVIRON["NF"]} {print}' "$SHADOW" > "$tmp"
    # 권한/소유자 보존
    chmod --reference="$SHADOW" "$tmp" 2>/dev/null || chmod 640 "$tmp"
    chown --reference="$SHADOW" "$tmp" 2>/dev/null || true
    cat "$tmp" > "$SHADOW"        # inode 유지(마운트 rootfs 안전)
    rm -f "$tmp"
}

backup_shadow() {
    local bak
    bak="$SHADOW.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$SHADOW" "$bak"
    log_info backup "$bak"
}

main() {
    parse_args "$@"
    require_root
    check_root_fs

    if [[ $LIST -eq 1 ]]; then list_users; exit 0; fi
    [[ -n "$USER_NAME" ]] || { log_err err_need_user; list_users; exit 2; }
    user_exists "$USER_NAME" || die err_no_user "$USER_NAME"
    [[ -n "$ACTION" ]] || { log_err err_action; exit 2; }

    log_info cur "$USER_NAME" "$(shadow_state)"

    case "$ACTION" in
        set)   log_info do_set "$USER_NAME" ;;
        blank) log_warn do_blank "$USER_NAME" ;;
        unlock)log_info do_unlock "$USER_NAME" ;;
    esac
    confirm_exact "$USER_NAME" "$(msg confirm "$USER_NAME")" || die abort

    backup_shadow
    case "$ACTION" in
        set)
            local h; h="$(make_hash "$NEWPASS")" || die err_no_hash
            set_field "$h"
            log_info ok "$USER_NAME" ;;
        blank)
            set_field ""
            log_info ok_blank "$USER_NAME"
            log_warn warn_ssh ;;
        unlock)
            # 앞의 ! 또는 * 잠금 표시만 제거
            local cur; cur="$(awk -F: -v u="$USER_NAME" '$1==u{print $2}' "$SHADOW")"
            set_field "${cur#[\!\*]}"
            log_info ok "$USER_NAME" ;;
    esac
    sync
}

main "$@"
