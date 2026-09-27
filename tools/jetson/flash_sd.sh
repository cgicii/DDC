#!/usr/bin/env bash
# Jetson Orin Nano 개발자 키트용 microSD 카드 기록 스크립트 (Linux 호스트용)
#
# NVIDIA가 배포하는 SD 카드 이미지(.zip / .img / .img.xz)를 microSD에 기록하고
# 기록 결과를 원본과 바이트 단위로 대조 검증한다.
# Windows/macOS 호스트는 NVIDIA 공식 안내대로 Balena Etcher 를 사용한다.
#
# 안전장치 (산업 현장에서 PC 디스크를 날리는 사고 방지)
#   - 루트(/), /boot, /home, 스왑 등 시스템이 쓰는 디스크는 무조건 거부
#   - 이동식(USB/SD 리더)이 아닌 디스크는 --allow-non-removable 없이는 거부
#   - 이미지보다 작은 카드 거부
#   - 장치 이름을 그대로 다시 입력해야 기록 시작
#
# 사용법
#   sudo ./flash_sd.sh --list
#   sudo ./flash_sd.sh -i jp62-r1-orin-nano-sd-card-image.zip -d /dev/sdX
#   sudo ./flash_sd.sh -i image.zip -d /dev/sdX --sha256 <다운로드 페이지의 해시>
#
# 종료 코드: 0 성공 / 1 오류 / 2 사용법 오류 / 3 검증 실패

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# shellcheck disable=SC2034  # MSG_ko/MSG_en 은 lib/common.sh 의 msg() 가 간접 참조
declare -A MSG_ko=(
    [usage]="사용법: %s -i <이미지> -d <장치> [--sha256 <해시>] [--no-verify] [--yes] [--allow-non-removable]
       %s --list

  -i, --image             SD 카드 이미지 (.zip / .img / .img.xz)
  -d, --device            대상 장치 (예: /dev/sdb, /dev/mmcblk0) — 파티션(/dev/sdb1) 아님
      --sha256            다운로드 파일의 SHA-256 (지정 시 기록 전 대조)
      --no-verify         기록 후 대조 검증 생략 (권장하지 않음)
      --yes               확인 입력 생략 (자동화용)
      --allow-non-removable  이동식이 아닌 디스크도 허용 (USB-SATA 어댑터 등)
      --list              기록 가능한 이동식 디스크 목록
  환경변수 DDC_LANG=en 이면 영문 메시지
"
    [list_head]="이동식 디스크 목록 (RM=1 또는 USB/MMC):"
    [list_none]="이동식 디스크가 없습니다. SD 카드 리더를 연결했는지 확인하세요."
    [err_arg]="알 수 없는 인자: %s"
    [err_need]="-i 와 -d 는 필수입니다."
    [err_img]="이미지 파일이 없습니다: %s"
    [err_ext]="지원하지 않는 이미지 형식입니다: %s (.zip / .img / .img.xz)"
    [err_zip_n]="zip 안에 .img 파일이 정확히 1개여야 합니다 (발견: %s개)."
    [err_blk]="블록 장치가 아닙니다: %s"
    [err_part]="파티션이 아니라 디스크 전체를 지정하세요: %s (TYPE=%s)"
    [err_sys]="시스템 디스크입니다. 기록을 거부합니다: %s (%s 에 마운트됨)"
    [err_rm]="이동식 디스크가 아닙니다: %s — 확실하면 --allow-non-removable"
    [err_size]="카드 용량 부족: 카드 %s 바이트 < 이미지 %s 바이트"
    [err_sha]="SHA-256 불일치 — 다운로드가 손상되었습니다.
  기대값: %s
  실제값: %s"
    [err_umount]="마운트 해제 실패: %s"
    [err_write]="기록 실패 (카드 불량, 리더 접촉, 쓰기 방지 스위치 확인)"
    [err_verify]="검증 실패: 카드 내용이 이미지와 다릅니다. 카드를 교체하고 다시 기록하세요.
  %s"
    [err_confirm]="확인 문자열이 일치하지 않아 중단합니다."
    [sha_run]="SHA-256 계산 중 (수 분 소요)..."
    [sha_ok]="SHA-256 일치"
    [sha_skip]="--sha256 미지정: 다운로드 무결성 확인을 생략합니다."
    [target]="대상: %s  모델=%s  용량=%s 바이트  전송=%s"
    [image]="이미지: %s  (압축해제 크기 %s 바이트)"
    [warn_all]="%s 의 모든 데이터가 삭제됩니다."
    [prompt]="계속하려면 장치 이름(%s)을 그대로 입력하세요: "
    [umount]="마운트 해제: %s"
    [wipe]="기존 파티션 서명 제거 (끝부분 백업 GPT 포함)"
    [write]="기록 중... (64GB급 카드 기준 10~30분)"
    [write_ok]="기록 완료"
    [verify]="검증 중: 카드를 다시 읽어 이미지와 바이트 대조..."
    [verify_ok]="검증 통과: %s"
    [verify_skip]="--no-verify: 검증을 생략했습니다."
    [done]="완료. 카드를 빼서 Jetson 모듈 아래 microSD 슬롯에 꽂으세요."
    [nosize]="압축해제 크기를 미리 알 수 없어 용량 사전검사를 생략합니다."
)
# shellcheck disable=SC2034
declare -A MSG_en=(
    [usage]="Usage: %s -i <image> -d <device> [--sha256 <hash>] [--no-verify] [--yes] [--allow-non-removable]
       %s --list

  -i, --image             SD card image (.zip / .img / .img.xz)
  -d, --device            Target disk (e.g. /dev/sdb, /dev/mmcblk0) — not a partition
      --sha256            SHA-256 of the downloaded file (checked before writing)
      --no-verify         Skip read-back verification (not recommended)
      --yes               Skip confirmation (automation)
      --allow-non-removable  Allow non-removable disks (USB-SATA adapters etc.)
      --list              List removable disks
"
    [list_head]="Removable disks (RM=1 or USB/MMC):"
    [list_none]="No removable disk found. Is the SD card reader connected?"
    [err_arg]="Unknown argument: %s"
    [err_need]="-i and -d are required."
    [err_img]="Image not found: %s"
    [err_ext]="Unsupported image format: %s (.zip / .img / .img.xz)"
    [err_zip_n]="The zip must contain exactly one .img (found: %s)."
    [err_blk]="Not a block device: %s"
    [err_part]="Specify the whole disk, not a partition: %s (TYPE=%s)"
    [err_sys]="System disk, refusing to write: %s (mounted at %s)"
    [err_rm]="Not a removable disk: %s — use --allow-non-removable if sure"
    [err_size]="Card too small: card %s bytes < image %s bytes"
    [err_sha]="SHA-256 mismatch — download is corrupted.
  expected: %s
  actual:   %s"
    [err_umount]="Failed to unmount: %s"
    [err_write]="Write failed (check card, reader contact, write-protect switch)"
    [err_verify]="Verification failed: card differs from image. Replace the card and retry.
  %s"
    [err_confirm]="Confirmation did not match. Aborting."
    [sha_run]="Computing SHA-256 (takes minutes)..."
    [sha_ok]="SHA-256 matches"
    [sha_skip]="No --sha256 given: skipping download integrity check."
    [target]="Target: %s  model=%s  size=%s bytes  tran=%s"
    [image]="Image: %s  (uncompressed %s bytes)"
    [warn_all]="ALL data on %s will be erased."
    [prompt]="Type the device name (%s) to continue: "
    [umount]="Unmounting: %s"
    [wipe]="Wiping old partition signatures (including backup GPT at the end)"
    [write]="Writing... (10-30 min for a 64GB-class card)"
    [write_ok]="Write complete"
    [verify]="Verifying: reading the card back and comparing with the image..."
    [verify_ok]="Verification passed: %s"
    [verify_skip]="--no-verify: verification skipped."
    [done]="Done. Insert the card into the microSD slot under the Jetson module."
    [nosize]="Uncompressed size unknown in advance; skipping capacity pre-check."
)

IMAGE="" DEVICE="" SHA256="" VERIFY=1 ALLOW_NONRM=0
ZIP_ENTRY=""

usage() { msg usage "$0" "$0"; }

list_disks() {
    msg list_head; echo
    local found=0 name rm tran
    while read -r name rm tran; do
        if [[ "$rm" == "1" || "$tran" == "usb" || "$tran" == "mmc" || "$name" == /dev/mmcblk* ]]; then
            lsblk -dno NAME,SIZE,MODEL,TRAN,RM -p "$name"
            found=1
        fi
    done < <(lsblk -dnpo NAME,RM,TRAN -e 7,11)
    [[ $found -eq 1 ]] || msg list_none; echo
}

parse_args() {
    [[ $# -eq 0 ]] && { usage; exit 2; }
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--image)  IMAGE="${2:-}"; shift 2 ;;
            -d|--device) DEVICE="${2:-}"; shift 2 ;;
            --sha256)    SHA256="${2,,}"; shift 2 ;;
            --no-verify) VERIFY=0; shift ;;
            --yes)       ASSUME_YES=1; export ASSUME_YES; shift ;;
            --allow-non-removable) ALLOW_NONRM=1; shift ;;
            --list)      list_disks; exit 0 ;;
            -h|--help)   usage; exit 0 ;;
            *) log_err err_arg "$1"; usage; exit 2 ;;
        esac
    done
    [[ -n "$IMAGE" && -n "$DEVICE" ]] || { log_err err_need; usage; exit 2; }
}

# 이미지 형식 판별 + 압축해제 크기(모르면 빈 값)
IMG_KIND="" IMG_SIZE=""
inspect_image() {
    [[ -f "$IMAGE" ]] || die err_img "$IMAGE"
    case "${IMAGE,,}" in
        *.zip)
            require_cmd unzip
            IMG_KIND=zip
            local entries n
            entries="$(unzip -Z1 "$IMAGE" | grep -i '\.img$' || true)"
            n=0; [[ -n "$entries" ]] && n="$(wc -l <<<"$entries")"
            [[ "$n" -eq 1 ]] || die err_zip_n "$n"
            ZIP_ENTRY="$entries"
            IMG_SIZE="$(unzip -Zl "$IMAGE" "$ZIP_ENTRY" | awk 'NR==1{print $4}')" ;;
        *.img.xz|*.xz)
            require_cmd xz
            IMG_KIND=xz
            IMG_SIZE="$(xz --robot --list "$IMAGE" | awk '$1=="totals"{print $5}')" ;;
        *.img)
            IMG_KIND=img
            IMG_SIZE="$(stat -c %s "$IMAGE")" ;;
        *) die err_ext "$IMAGE" ;;
    esac
    [[ "$IMG_SIZE" =~ ^[0-9]+$ ]] || IMG_SIZE=""
}

# 원본 이미지를 stdout 으로 흘린다 (기록/검증 공용)
image_stream() {
    case "$IMG_KIND" in
        zip) unzip -p "$IMAGE" "$ZIP_ENTRY" ;;
        xz)  xz -dc "$IMAGE" ;;
        img) cat "$IMAGE" ;;
    esac
}

SYSTEM_MOUNTS=" / /boot /boot/efi /usr /var /home /opt /srv [SWAP] "

check_device() {
    [[ -b "$DEVICE" ]] || die err_blk "$DEVICE"
    DEVICE="$(readlink -f "$DEVICE")"
    local type rm tran
    type="$(lsblk -dno TYPE "$DEVICE")"
    [[ "$type" == "disk" || "$type" == "loop" ]] || die err_part "$DEVICE" "$type"

    local name mp
    while read -r name mp; do
        [[ -z "$mp" ]] && continue
        if [[ "$SYSTEM_MOUNTS" == *" $mp "* ]]; then
            die err_sys "$DEVICE" "$mp"
        fi
    done < <(lsblk -lnpo NAME,MOUNTPOINT "$DEVICE")

    rm="$(lsblk -dno RM "$DEVICE" | tr -d ' ')"
    tran="$(lsblk -dno TRAN "$DEVICE" | tr -d ' ')"
    if [[ "$rm" != "1" && "$tran" != "usb" && "$tran" != "mmc" \
          && "$DEVICE" != /dev/mmcblk* && $ALLOW_NONRM -eq 0 ]]; then
        die err_rm "$DEVICE"
    fi

    DEV_SIZE="$(lsblk -bdno SIZE "$DEVICE" | tr -d ' ')"
    log_info target "$DEVICE" "$(lsblk -dno MODEL "$DEVICE" | xargs)" "$DEV_SIZE" "${tran:--}"
    if [[ -n "$IMG_SIZE" ]]; then
        [[ "$DEV_SIZE" -ge "$IMG_SIZE" ]] || die err_size "$DEV_SIZE" "$IMG_SIZE"
    else
        log_warn nosize
    fi
}

check_sha() {
    if [[ -z "$SHA256" ]]; then log_warn sha_skip; return; fi
    log_info sha_run
    local actual
    actual="$(sha256sum "$IMAGE" | awk '{print $1}')"
    [[ "$actual" == "$SHA256" ]] || die err_sha "$SHA256" "$actual"
    log_info sha_ok
}

unmount_all() {
    local name mp
    while read -r name mp; do
        [[ -z "$mp" ]] && continue
        log_info umount "$name"
        umount "$name" || die err_umount "$name"
    done < <(lsblk -lnpo NAME,MOUNTPOINT "$DEVICE")
}

write_image() {
    log_info wipe
    wipefs -a -q "$DEVICE"
    log_info write
    if ! image_stream | dd of="$DEVICE" bs=4M iflag=fullblock oflag=direct conv=fsync status=progress; then
        die err_write
    fi
    sync
    log_info write_ok
}

verify_image() {
    if [[ $VERIFY -eq 0 ]]; then log_warn verify_skip; return; fi
    log_info verify
    # 페이지 캐시가 아닌 실제 카드 내용을 읽도록 캐시를 비운다
    blockdev --flushbufs "$DEVICE" || true
    echo 3 > /proc/sys/vm/drop_caches || true
    local out rc=0
    out="$(image_stream | LC_ALL=C cmp - "$DEVICE" 2>&1)" || rc=$?
    # 이미지가 카드보다 작으므로 "EOF on -" = 이미지 전 구간 일치
    if [[ $rc -eq 0 || "$out" == *"EOF on -"* ]]; then
        log_info verify_ok "${out:-identical}"
    else
        log_err err_verify "$out"
        exit 3
    fi
}

main() {
    parse_args "$@"
    require_root
    require_cmd lsblk dd cmp wipefs blockdev sha256sum stat awk
    inspect_image
    log_info image "$IMAGE" "${IMG_SIZE:-?}"
    check_device
    check_sha

    log_warn warn_all "$DEVICE"
    confirm_exact "$DEVICE" "$(msg prompt "$DEVICE")" || die err_confirm

    unmount_all
    write_image
    command -v partprobe >/dev/null 2>&1 && partprobe "$DEVICE" 2>/dev/null || true
    verify_image
    log_info "done"
}

main "$@"
