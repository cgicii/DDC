#!/usr/bin/env bash
# Jetson 설치 스크립트 공통 모듈 — 로그 / 다국어 메시지 / 확인 프롬프트.
#
# 다른 프로젝트로 옮길 때는 이 파일만 복사해서 source 하면 된다.
#
# 다국어:
#   DDC_LANG=ko (기본) | en
#   각 스크립트가 MSG_ko / MSG_en 연관 배열을 선언하고 msg KEY [printf 인자...] 로 쓴다.
#   찾는 순서: 스크립트 선택언어 → 공통 선택언어 → 스크립트 ko → 공통 ko → 키 이름.
#   언어를 추가하려면 MSG_<언어> / COMMON_MSG_<언어> 배열만 추가하면 된다.

DDC_LANG="${DDC_LANG:-ko}"

# shellcheck disable=SC2034  # msg() 가 간접(nameref) 참조
declare -gA COMMON_MSG_ko=(
    [tag_info]="정보"
    [tag_warn]="주의"
    [tag_err]="오류"
    [err_root]="root 권한이 필요합니다. sudo 로 실행하세요."
    [err_cmd]="필수 명령이 없습니다: %s"
)
# shellcheck disable=SC2034
declare -gA COMMON_MSG_en=(
    [tag_info]="INFO"
    [tag_warn]="WARN"
    [tag_err]="ERROR"
    [err_root]="Root privileges required. Run with sudo."
    [err_cmd]="Required command not found: %s"
)

_msg_lookup() {  # _msg_lookup 배열이름 키 → 있으면 출력하고 0
    declare -p "$1" >/dev/null 2>&1 || return 1
    local -n _t="$1"
    [[ -n "${_t[$2]:-}" ]] || return 1
    printf '%s' "${_t[$2]}"
}

msg() {
    local key="$1"; shift
    local text tbl
    for tbl in "MSG_${DDC_LANG}" "COMMON_MSG_${DDC_LANG}" MSG_ko COMMON_MSG_ko; do
        if text="$(_msg_lookup "$tbl" "$key")"; then
            # shellcheck disable=SC2059  # 메시지 테이블이 형식 문자열이다
            # '--' 로 옵션 파싱을 끊는다. 메시지가 '--sha256...' 처럼 시작해도 안전.
            printf -- "$text" "$@"
            return
        fi
    done
    printf '%s' "$key"
}

if [[ -t 1 ]]; then
    _C_R=$'\e[31m'; _C_G=$'\e[32m'; _C_Y=$'\e[33m'; _C_0=$'\e[0m'
else
    _C_R=""; _C_G=""; _C_Y=""; _C_0=""
fi

log_info() { printf '%s[%s]%s %s\n' "$_C_G" "$(msg tag_info)" "$_C_0" "$(msg "$@")"; }
log_warn() { printf '%s[%s]%s %s\n' "$_C_Y" "$(msg tag_warn)" "$_C_0" "$(msg "$@")" >&2; }
log_err()  { printf '%s[%s]%s %s\n' "$_C_R" "$(msg tag_err)"  "$_C_0" "$(msg "$@")" >&2; }
die()      { log_err "$@"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die err_root
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die err_cmd "$c"
    done
}

# 사람이 정확한 문자열을 입력해야만 통과. 자동화 시 ASSUME_YES=1.
confirm_exact() {
    local expected="$1" prompt="$2" ans
    [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
    read -r -p "$prompt" ans
    [[ "$ans" == "$expected" ]]
}
