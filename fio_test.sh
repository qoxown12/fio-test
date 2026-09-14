#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${FIO_CONFIG_FILE:-${SCRIPT_DIR}/config.env}"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
    log "오류: $*"
    exit 1
}

usage() {
    cat <<'EOF'
사용법:
  ./fio_test.sh
  ./fio_test.sh --rw=write --bs=128k --numjobs=16 --iodepth=64
  ./fio_test.sh --matrix [fio 변경 옵션]

설명:
  옵션이 없으면 config.env의 TEST_MODE와 기본값을 사용합니다.
  fio 변경 옵션을 주면 단일 테스트로 실행하며 config.env의 같은 값을 덮어씁니다.
  --matrix는 config.env의 FIO_TEST_CASES 전체를 항목별로 동기 실행합니다.
  모든 VM의 테스트 파일 준비가 끝난 뒤 공통 예약 시각에 측정을 시작합니다.

허용 옵션:
  --directory=PATH  --name=NAME       --gtod_reduce=N
  --randrepeat=N    --ioengine=ENGINE --direct=N
  --rw=TYPE         --bs=SIZE         --size=SIZE
  --numjobs=N       --iodepth=N       --runtime=N
  --time_based      --group_reporting --norandommap
EOF
}

[[ -r "$CONFIG_FILE" ]] || die "설정 파일을 읽을 수 없습니다: $CONFIG_FILE"
# config.env는 이 도구의 일부이며 신뢰할 수 있는 셸 설정 파일이어야 합니다.
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${REMOTE_USER:=root}"
: "${REMOTE_PASSWORD:=}"
: "${REMOTE_SSH_PORT:=22}"
: "${SSH_CONNECT_TIMEOUT:=10}"
: "${SSH_HOST_KEY_CHECKING:=accept-new}"
: "${FIO_SYNC_START_DELAY:=10}"
: "${FIO_MAX_CLOCK_SKEW:=2}"
: "${VM_LIST_FILE:=${SCRIPT_DIR}/vm_list.txt}"
: "${MASTER_RESULT_DIR:=${SCRIPT_DIR}/results}"
: "${REMOTE_RESULT_DIR:=/tmp/fio-test-results}"
: "${KEEP_REMOTE_RESULTS:=yes}"
: "${TEST_MODE:=single}"
: "${FIO_DIRECTORY:=/root/fio}"
: "${FIO_NAME:=fio_test}"
: "${FIO_GTOD_REDUCE:=1}"
: "${FIO_RANDREPEAT:=1}"
: "${FIO_IOENGINE:=libaio}"
: "${FIO_DIRECT:=1}"
: "${FIO_RW:=randread}"
: "${FIO_BS:=4k}"
: "${FIO_SIZE:=1G}"
: "${FIO_NUMJOBS:=16}"
: "${FIO_IODEPTH:=64}"
: "${FIO_RUNTIME:=180}"
: "${FIO_TIME_BASED:=yes}"
: "${FIO_GROUP_REPORTING:=yes}"
: "${FIO_NORANDOMMAP:=yes}"

if ! declare -p FIO_TEST_CASES >/dev/null 2>&1; then
    FIO_TEST_CASES=(
        "randread:4k"
        "randwrite:4k"
        "randread:8k"
        "randwrite:8k"
        "read:128k"
        "write:128k"
    )
fi

is_yes() {
    case "${1,,}" in
        yes|true|1|on) return 0 ;;
        no|false|0|off) return 1 ;;
        *) die "yes/no 형식이어야 하는 값입니다: $1" ;;
    esac
}

validate_bool() {
    case "${2,,}" in
        yes|true|1|on|no|false|0|off) ;;
        *) die "$1 값은 yes/no 형식이어야 합니다: $2" ;;
    esac
}

validate_rw() {
    case "$1" in
        randread|randwrite|read|write) ;;
        *) die "지원하지 않는 rw 값입니다: $1 (randread, randwrite, read, write만 허용)" ;;
    esac
}

validate_size() {
    [[ "$2" =~ ^[0-9]+([kKmMgGtTpP]([bB])?)?$ ]] ||
        die "$1 값의 형식이 잘못되었습니다: $2"
}

validate_uint() {
    [[ "$2" =~ ^[0-9]+$ ]] || die "$1 값은 0 이상의 정수여야 합니다: $2"
}

validate_positive_uint() {
    [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 값은 1 이상의 정수여야 합니다: $2"
}

validate_safe_path() {
    [[ "$2" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
        die "$1은 공백 없는 절대 경로여야 합니다: $2"
}

validate_token() {
    [[ "$2" =~ ^[A-Za-z0-9._+-]+$ ]] || die "$1 값에 허용되지 않은 문자가 있습니다: $2"
}

validate_config() {
    validate_token REMOTE_USER "$REMOTE_USER"
    validate_positive_uint REMOTE_SSH_PORT "$REMOTE_SSH_PORT"
    validate_positive_uint SSH_CONNECT_TIMEOUT "$SSH_CONNECT_TIMEOUT"
    case "$SSH_HOST_KEY_CHECKING" in
        yes|no|accept-new) ;;
        *) die "SSH_HOST_KEY_CHECKING은 yes, no, accept-new 중 하나여야 합니다." ;;
    esac
    validate_positive_uint FIO_SYNC_START_DELAY "$FIO_SYNC_START_DELAY"
    validate_uint FIO_MAX_CLOCK_SKEW "$FIO_MAX_CLOCK_SKEW"

    validate_safe_path FIO_DIRECTORY "$FIO_DIRECTORY"
    validate_safe_path REMOTE_RESULT_DIR "$REMOTE_RESULT_DIR"
    validate_token FIO_NAME "$FIO_NAME"
    validate_token FIO_IOENGINE "$FIO_IOENGINE"
    validate_rw "$FIO_RW"
    validate_size FIO_BS "$FIO_BS"
    validate_size FIO_SIZE "$FIO_SIZE"
    validate_uint FIO_GTOD_REDUCE "$FIO_GTOD_REDUCE"
    validate_uint FIO_RANDREPEAT "$FIO_RANDREPEAT"
    validate_uint FIO_DIRECT "$FIO_DIRECT"
    validate_positive_uint FIO_NUMJOBS "$FIO_NUMJOBS"
    validate_positive_uint FIO_IODEPTH "$FIO_IODEPTH"
    validate_positive_uint FIO_RUNTIME "$FIO_RUNTIME"
    validate_bool FIO_TIME_BASED "$FIO_TIME_BASED"
    validate_bool FIO_GROUP_REPORTING "$FIO_GROUP_REPORTING"
    validate_bool FIO_NORANDOMMAP "$FIO_NORANDOMMAP"
    validate_bool KEEP_REMOTE_RESULTS "$KEEP_REMOTE_RESULTS"

    case "$TEST_MODE" in
        single|matrix) ;;
        *) die "TEST_MODE는 single 또는 matrix여야 합니다: $TEST_MODE" ;;
    esac
}

validate_config

declare -a CLI_FIO_ARGS=()
requested_mode="$TEST_MODE"
cli_has_fio_options=no
matrix_requested_on_cli=no
cli_has_rw_or_bs=no
cli_rw="$FIO_RW"
cli_bs="$FIO_BS"

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            usage
            exit 0
            ;;
        --matrix)
            requested_mode=matrix
            matrix_requested_on_cli=yes
            ;;
        --single)
            requested_mode=single
            ;;
        --rw=*)
            cli_rw="${arg#*=}"
            validate_rw "$cli_rw"
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            cli_has_rw_or_bs=yes
            ;;
        --bs=*)
            cli_bs="${arg#*=}"
            validate_size bs "$cli_bs"
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            cli_has_rw_or_bs=yes
            ;;
        --directory=*)
            validate_safe_path directory "${arg#*=}"
            FIO_DIRECTORY="${arg#*=}"
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            ;;
        --name=*)
            validate_token name "${arg#*=}"
            FIO_NAME="${arg#*=}"
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            ;;
        --ioengine=*)
            validate_token ioengine "${arg#*=}"
            FIO_IOENGINE="${arg#*=}"
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            ;;
        --gtod_reduce=*)
            validate_uint gtod_reduce "${arg#*=}"
            FIO_GTOD_REDUCE="${arg#*=}"
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            ;;
        --randrepeat=*)
            validate_uint randrepeat "${arg#*=}"
            FIO_RANDREPEAT="${arg#*=}"
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            ;;
        --direct=*)
            validate_uint direct "${arg#*=}"
            FIO_DIRECT="${arg#*=}"
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            ;;
        --numjobs=*)
            validate_positive_uint numjobs "${arg#*=}"
            FIO_NUMJOBS="${arg#*=}"
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            ;;
        --iodepth=*)
            validate_positive_uint iodepth "${arg#*=}"
            FIO_IODEPTH="${arg#*=}"
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            ;;
        --runtime=*)
            validate_positive_uint runtime "${arg#*=}"
            FIO_RUNTIME="${arg#*=}"
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            ;;
        --size=*)
            validate_size size "${arg#*=}"
            FIO_SIZE="${arg#*=}"
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            ;;
        --time_based)
            FIO_TIME_BASED=yes
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            ;;
        --group_reporting)
            FIO_GROUP_REPORTING=yes
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            ;;
        --norandommap)
            FIO_NORANDOMMAP=yes
            CLI_FIO_ARGS+=("$arg")
            cli_has_fio_options=yes
            ;;
        *)
            die "지원하지 않는 옵션입니다: $arg (도움말: ./fio_test.sh --help)"
            ;;
    esac
done

# 일반 fio 옵션만 전달한 경우에는 해당 설정으로 단일 테스트를 수행한다.
if [[ "$cli_has_fio_options" == yes && "$matrix_requested_on_cli" == no ]]; then
    requested_mode=single
fi
if [[ "$requested_mode" == matrix && "$cli_has_rw_or_bs" == yes ]]; then
    die "matrix 모드에서는 --rw/--bs를 함께 사용할 수 없습니다. FIO_TEST_CASES에서 항목을 변경하세요."
fi

declare -a TEST_CASES=()
if [[ "$requested_mode" == matrix ]]; then
    [[ ${#FIO_TEST_CASES[@]} -gt 0 ]] || die "FIO_TEST_CASES가 비어 있습니다."
    for test_case in "${FIO_TEST_CASES[@]}"; do
        IFS=: read -r case_rw case_bs extra <<< "$test_case"
        [[ -n "$case_rw" && -n "$case_bs" && -z "${extra:-}" ]] ||
            die "FIO_TEST_CASES 항목은 rw:bs 형식이어야 합니다: $test_case"
        validate_rw "$case_rw"
        validate_size bs "$case_bs"
        TEST_CASES+=("${case_rw}:${case_bs}")
    done
else
    TEST_CASES+=("${cli_rw}:${cli_bs}")
fi

for required_command in ssh hostname date mkdir mv rm; do
    command -v "$required_command" >/dev/null 2>&1 ||
        die "마스터에 필요한 명령이 없습니다: $required_command"
done
if [[ -n "$REMOTE_PASSWORD" ]]; then
    command -v sshpass >/dev/null 2>&1 ||
        die "REMOTE_PASSWORD 사용 시 마스터에 sshpass가 설치되어 있어야 합니다."
fi

if [[ "$VM_LIST_FILE" != /* ]]; then
    VM_LIST_FILE="${SCRIPT_DIR}/${VM_LIST_FILE#./}"
fi
[[ -r "$VM_LIST_FILE" ]] || die "VM 목록 파일을 읽을 수 없습니다: $VM_LIST_FILE"

declare -a VMS=()
declare -A SEEN_VMS=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[A-Za-z0-9._:-]+$ ]] || die "VM 주소 형식이 잘못되었습니다: $line"
    if [[ -z "${SEEN_VMS[$line]:-}" ]]; then
        VMS+=("$line")
        SEEN_VMS[$line]=1
    fi
done < "$VM_LIST_FILE"
[[ ${#VMS[@]} -gt 0 ]] || die "vm_list.txt에 실행할 VM 주소가 없습니다."

if [[ "$MASTER_RESULT_DIR" != /* ]]; then
    MASTER_RESULT_DIR="${SCRIPT_DIR}/${MASTER_RESULT_DIR#./}"
fi

RUN_TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
if [[ "$requested_mode" == matrix ]]; then
    RUN_FOLDER="matrix_${#TEST_CASES[@]}cases_${RUN_TIMESTAMP}"
else
    IFS=: read -r run_folder_rw run_folder_bs <<< "${TEST_CASES[0]}"
    RUN_FOLDER="rw-${run_folder_rw}_bs-${run_folder_bs}_${RUN_TIMESTAMP}"
fi
RUN_DIR="${MASTER_RESULT_DIR}/${RUN_FOLDER}"
mkdir -p "$RUN_DIR"
HOST_INFO_DIR="${RUN_DIR}/.hosts"
mkdir -p "$HOST_INFO_DIR"

SSH_OPTIONS=(
    -p "$REMOTE_SSH_PORT"
    -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
    -o "StrictHostKeyChecking=${SSH_HOST_KEY_CHECKING}"
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
    -o LogLevel=ERROR
)

ssh_exec() {
    local vm="$1"
    local remote_command="$2"
    if [[ -n "$REMOTE_PASSWORD" ]]; then
        SSHPASS="$REMOTE_PASSWORD" sshpass -e ssh "${SSH_OPTIONS[@]}" \
            "${REMOTE_USER}@${vm}" "$remote_command"
    else
        ssh -o BatchMode=yes "${SSH_OPTIONS[@]}" \
            "${REMOTE_USER}@${vm}" "$remote_command"
    fi
}

log_run_error() {
    local vm="$1"
    local message="$2"
    local occurred_at
    occurred_at="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [%s] %s\n' "$occurred_at" "$vm" "$message" >&2
    printf '[%s] [%s] %s\n' "$occurred_at" "$vm" "$message" >> "${RUN_DIR}/errors.log"
}

log_preflight_failure() {
    local vm="$1"
    local exit_code="$2"

    if [[ -n "$REMOTE_PASSWORD" && "$exit_code" -eq 5 ]]; then
        log_run_error "$vm" "SSH 인증 실패: config.env의 REMOTE_USER 또는 REMOTE_PASSWORD가 원격 VM의 계정 정보와 일치하지 않습니다."
        log_run_error "$vm" "config.env의 REMOTE_USER/REMOTE_PASSWORD 값을 확인한 뒤 다시 실행하세요. (sshpass 종료 코드: 5)"
        return
    fi

    case "$exit_code" in
        6)
            log_run_error "$vm" "SSH 호스트 키 확인 실패: 원격 VM의 호스트 키 등록 상태를 확인하세요."
            ;;
        10)
            log_run_error "$vm" "운영체제 확인 실패: 테스트 대상은 Rocky Linux VM이어야 합니다."
            ;;
        11)
            log_run_error "$vm" "fio 확인 실패: 원격 VM에 fio가 설치되어 있지 않습니다."
            ;;
        255)
            log_run_error "$vm" "SSH 연결 실패: IP, SSH 포트, sshd 실행 상태, 방화벽을 확인하세요."
            ;;
        *)
            log_run_error "$vm" "원격 사전 조건 확인 실패 (종료 코드: $exit_code)"
            ;;
    esac
}

sanitize_filename() {
    local value="$1"
    value="${value//[^A-Za-z0-9._-]/_}"
    printf '%s' "$value"
}

workload_kind() {
    case "$1" in
        randread|randwrite) printf 'random' ;;
        read|write) printf 'sequential' ;;
    esac
}

io_direction() {
    case "$1" in
        randread|read) printf 'read' ;;
        randwrite|write) printf 'write' ;;
    esac
}

host_info_file() {
    local vm="$1"
    printf '%s/%s.hostname' "$HOST_INFO_DIR" "$(sanitize_filename "$vm")"
}

build_prepare_command() {
    local remote_prepare_file="$1"
    local -a args=(
        "--directory=${FIO_DIRECTORY}"
        "--name=${FIO_NAME}"
        "--ioengine=${FIO_IOENGINE}"
        "--direct=${FIO_DIRECT}"
        "--rw=write"
        "--bs=${FIO_BS}"
        "--size=${FIO_SIZE}"
        "--numjobs=${FIO_NUMJOBS}"
        "--create_only=1"
        "--output=${remote_prepare_file}"
    )
    local command_text='set -eu; umask 077; fio'

    # 모든 값은 앞 단계에서 공백/셸 메타문자가 없는 형식으로 검증된다.
    local fio_arg
    for fio_arg in "${args[@]}"; do
        command_text+=" ${fio_arg}"
    done
    command_text+="; rm -f -- ${remote_prepare_file}"
    printf '%s' "$command_text"
}

prepare_vm() {
    local vm="$1"
    local preflight preflight_output remote_hostname remote_epoch safe_vm
    local clock_before clock_after min_epoch max_epoch ssh_status
    local host_file remote_prepare_file prepare_command prepare_output output_line

    preflight='set -eu; test -r /etc/os-release; . /etc/os-release; if [ "${ID:-}" != "rocky" ]; then echo "Rocky Linux VM이 아닙니다: ${ID:-unknown}" >&2; exit 10; fi; command -v fio >/dev/null 2>&1 || { echo "fio가 설치되어 있지 않습니다." >&2; exit 11; }'
    preflight+="; mkdir -p ${FIO_DIRECTORY} ${REMOTE_RESULT_DIR}; test -w ${FIO_DIRECTORY}; test -w ${REMOTE_RESULT_DIR}; hostname; date +%s"

    log "[$vm] 접속 및 사전 조건 확인"
    clock_before="$(date +%s)"
    if preflight_output="$(ssh_exec "$vm" "$preflight")"; then
        :
    else
        ssh_status=$?
        log_preflight_failure "$vm" "$ssh_status"
        return 1
    fi
    clock_after="$(date +%s)"

    remote_hostname="${preflight_output%%$'\n'*}"
    remote_epoch="${preflight_output##*$'\n'}"
    if [[ -z "$remote_hostname" || ! "$remote_epoch" =~ ^[0-9]+$ ]]; then
        log_run_error "$vm" "원격 호스트명 또는 시스템 시각을 확인하지 못했습니다."
        return 1
    fi

    min_epoch=$((clock_before - FIO_MAX_CLOCK_SKEW))
    max_epoch=$((clock_after + FIO_MAX_CLOCK_SKEW))
    if (( remote_epoch < min_epoch || remote_epoch > max_epoch )); then
        log_run_error "$vm" "시스템 시각 차이가 허용 범위(${FIO_MAX_CLOCK_SKEW}초)를 초과했습니다. chronyd 동기화 상태를 확인하세요."
        log_run_error "$vm" "마스터 확인 구간=${clock_before}-${clock_after}, 원격 시각=${remote_epoch}"
        return 1
    fi

    safe_vm="$(sanitize_filename "$vm")"
    host_file="$(host_info_file "$vm")"
    remote_prepare_file="${REMOTE_RESULT_DIR}/prepare_${safe_vm}_${RUN_TIMESTAMP}.log"
    prepare_command="$(build_prepare_command "$remote_prepare_file")"

    log "[$vm] 테스트 파일 준비 시작: ${FIO_NUMJOBS}개 x ${FIO_SIZE}"
    if prepare_output="$(ssh_exec "$vm" "$prepare_command" 2>&1)"; then
        printf '%s\n' "$remote_hostname" > "$host_file"
        log "[$vm] 테스트 파일 준비 완료"
        return 0
    else
        ssh_status=$?
    fi

    log_run_error "$vm" "테스트 파일 준비 실패: fio 측정을 시작하지 않습니다. (종료 코드: $ssh_status)"
    if [[ -n "$prepare_output" ]]; then
        while IFS= read -r output_line; do
            log_run_error "$vm" "준비 출력: $output_line"
        done <<< "$prepare_output"
    fi
    return 1
}

build_fio_command() {
    local rw="$1"
    local bs="$2"
    local remote_file="$3"
    local start_epoch="$4"
    local -a args=(
        "--directory=${FIO_DIRECTORY}"
        "--name=${FIO_NAME}"
        "--gtod_reduce=${FIO_GTOD_REDUCE}"
        "--randrepeat=${FIO_RANDREPEAT}"
        "--ioengine=${FIO_IOENGINE}"
        "--direct=${FIO_DIRECT}"
        "--rw=${rw}"
        "--bs=${bs}"
        "--size=${FIO_SIZE}"
        "--numjobs=${FIO_NUMJOBS}"
        "--iodepth=${FIO_IODEPTH}"
        "--runtime=${FIO_RUNTIME}"
    )
    local command_text

    is_yes "$FIO_TIME_BASED" && args+=("--time_based")
    is_yes "$FIO_GROUP_REPORTING" && args+=("--group_reporting")
    is_yes "$FIO_NORANDOMMAP" && args+=("--norandommap")
    args+=("--output=${remote_file}")

    command_text="set -eu; umask 077; current_epoch=\$(date +%s); if [ \"\$current_epoch\" -gt ${start_epoch} ]; then echo '동기 시작 예약 시각을 놓쳤습니다.' >&2; exit 20; fi; if [ \"\$current_epoch\" -lt ${start_epoch} ]; then sleep \$(( ${start_epoch} - current_epoch )); fi; exec fio"
    local fio_arg
    for fio_arg in "${args[@]}"; do
        command_text+=" ${fio_arg}"
    done
    printf '%s' "$command_text"
}

run_vm_case() {
    local vm="$1"
    local rw="$2"
    local bs="$3"
    local start_epoch="$4"
    local remote_hostname safe_hostname safe_vm kind direction base_name
    local remote_file local_file temp_file fio_command ssh_status host_file

    host_file="$(host_info_file "$vm")"
    if [[ ! -r "$host_file" ]]; then
        log_run_error "$vm" "준비 완료 정보를 찾을 수 없어 fio 측정을 시작하지 않습니다."
        return 1
    fi
    IFS= read -r remote_hostname < "$host_file"
    safe_hostname="$(sanitize_filename "$remote_hostname")"
    safe_vm="$(sanitize_filename "$vm")"
    kind="$(workload_kind "$rw")"
    direction="$(io_direction "$rw")"
    base_name="${safe_hostname}_${safe_vm}_${kind}_${direction}_${bs}_${RUN_TIMESTAMP}.log"
    remote_file="${REMOTE_RESULT_DIR}/${base_name}"
    local_file="${RUN_DIR}/${base_name}"
    temp_file="${local_file}.part.$$"
    fio_command="$(build_fio_command "$rw" "$bs" "$remote_file" "$start_epoch")"

    log "[$vm] fio 동기 시작 대기: rw=$rw, bs=$bs, epoch=$start_epoch"
    if ssh_exec "$vm" "$fio_command"; then
        :
    else
        ssh_status=$?
        if (( ssh_status == 20 )); then
            log_run_error "$vm" "동기 시작 예약 시각을 놓쳐 fio를 실행하지 않았습니다. FIO_SYNC_START_DELAY를 늘리세요."
        else
            log_run_error "$vm" "fio 실패: rw=$rw, bs=$bs (종료 코드: $ssh_status)"
        fi
        return 1
    fi

    if ssh_exec "$vm" "cat -- ${remote_file}" > "$temp_file"; then
        mv -f -- "$temp_file" "$local_file"
        log "[$vm] 결과 저장: $local_file"
    else
        rm -f -- "$temp_file"
        log_run_error "$vm" "결과 복제 실패: $remote_file"
        return 1
    fi

    if ! is_yes "$KEEP_REMOTE_RESULTS"; then
        if ! ssh_exec "$vm" "rm -f -- ${remote_file}"; then
            log_run_error "$vm" "원격 결과 파일 정리 실패: $remote_file"
        fi
    fi

    return 0
}

{
    printf 'run_timestamp=%s\n' "$RUN_TIMESTAMP"
    printf 'run_folder=%s\n' "$RUN_FOLDER"
    printf 'master_hostname=%s\n' "$(hostname)"
    printf 'test_mode=%s\n' "$requested_mode"
    printf 'vm_count=%s\n' "${#VMS[@]}"
    printf 'fio_size=%s\n' "$FIO_SIZE"
    printf 'fio_numjobs=%s\n' "$FIO_NUMJOBS"
    printf 'fio_iodepth=%s\n' "$FIO_IODEPTH"
    printf 'fio_runtime=%s\n' "$FIO_RUNTIME"
    printf 'fio_sync_start_delay=%s\n' "$FIO_SYNC_START_DELAY"
    printf 'fio_max_clock_skew=%s\n' "$FIO_MAX_CLOCK_SKEW"
    printf 'test_cases=%s\n' "${TEST_CASES[*]}"
    printf 'cli_fio_args=%s\n' "${CLI_FIO_ARGS[*]:-}"
} > "${RUN_DIR}/run.info"

log "마스터 결과 경로: $RUN_DIR"
log "총 ${#VMS[@]}대 VM의 사전 점검과 테스트 파일 준비를 시작합니다."

declare -a PIDS=()
for vm in "${VMS[@]}"; do
    prepare_vm "$vm" &
    PIDS+=("$!")
done

prepare_status=0
for index in "${!PIDS[@]}"; do
    if ! wait "${PIDS[$index]}"; then
        log "[${VMS[$index]}] 테스트 파일 준비에 실패했습니다."
        prepare_status=1
    fi
done

if (( prepare_status != 0 )); then
    log "일부 VM의 준비가 완료되지 않아 어떤 VM에서도 fio 성능 측정을 시작하지 않습니다."
    log "오류 내용과 준비 상태는 다음 경로에 있습니다: $RUN_DIR"
    exit 1
fi

log "모든 VM의 테스트 파일 준비가 완료되었습니다."

overall_status=0
case_number=0
for test_case in "${TEST_CASES[@]}"; do
    case_number=$((case_number + 1))
    IFS=: read -r rw bs <<< "$test_case"
    start_epoch=$(($(date +%s) + FIO_SYNC_START_DELAY))
    start_text="$(date -d "@${start_epoch}" '+%Y-%m-%d %H:%M:%S')"
    printf 'case_%s=%s,start_epoch=%s\n' "$case_number" "$test_case" "$start_epoch" >> "${RUN_DIR}/run.info"
    log "[${case_number}/${#TEST_CASES[@]}] 모든 VM의 fio 시작 예약: rw=$rw, bs=$bs, 시각=$start_text"

    PIDS=()
    for vm in "${VMS[@]}"; do
        run_vm_case "$vm" "$rw" "$bs" "$start_epoch" &
        PIDS+=("$!")
    done

    case_status=0
    for index in "${!PIDS[@]}"; do
        if ! wait "${PIDS[$index]}"; then
            log "[${VMS[$index]}] rw=$rw, bs=$bs 테스트가 실패했습니다."
            case_status=1
        fi
    done

    if (( case_status != 0 )); then
        overall_status=1
        log "현재 항목에서 실패가 발생하여 다음 matrix 항목은 실행하지 않습니다."
        break
    fi

    log "[${case_number}/${#TEST_CASES[@]}] 모든 VM의 테스트와 결과 수집 완료: rw=$rw, bs=$bs"
done

if (( overall_status == 0 )); then
    log "모든 VM의 테스트와 결과 수집이 완료되었습니다: $RUN_DIR"
else
    log "일부 VM에서 실패했습니다. errors.log와 성공한 결과(있는 경우)는 다음 경로에 있습니다: $RUN_DIR"
fi

exit "$overall_status"
