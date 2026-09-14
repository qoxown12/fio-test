# 원격 VM FIO 테스트 도구

마스터 VM 한 대에서 `vm_list.txt`의 Rocky Linux VM들을 준비한 뒤 공통 예약 시각에 fio를 동기 실행하고, 각 결과를 마스터의 지정 경로로 수집하는 Bash 도구입니다.

## 파일 구성

- `fio_test.sh`: 병렬 원격 실행 및 결과 수집 스크립트
- `config.env`: 공통 SSH 정보, fio 기본값, 테스트 매트릭스
- `vm_list.txt`: 테스트 대상 VM IP/호스트명 목록
- `results/`: 실행 시 자동 생성되는 마스터 결과 폴더

## 전제 조건

마스터와 원격 VM은 다음 조건을 만족해야 합니다.

- Rocky Linux
- 모든 VM에서 동일한 SSH 사용자/암호 사용
- 원격 VM의 SSH 서버 실행 및 마스터에서 SSH 접속 가능
- `fio`, OpenSSH 관련 패키지 설치 완료
- 암호 인증을 사용할 경우 마스터에 `sshpass` 설치 완료
- 마스터와 원격 VM의 시스템 시각 동기화
- 설정한 `FIO_DIRECTORY`에 쓰기 권한 보유
- 테스트 데이터용 여유 공간 확보

### Rocky Linux 패키지 설치

마스터와 원격 VM이 동일한 템플릿이라면 아래 패키지를 모든 VM에 똑같이 설치하는 것이 가장 간단합니다. 이 구성에는 마스터용 `openssh-clients`, `sshpass`와 원격 VM용 `fio`, `openssh-server`, 동기 시작에 필요한 `chrony`가 포함됩니다.

Rocky Linux 9 이상:

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --set-enabled crb
sudo dnf install -y epel-release
sudo dnf install -y fio openssh-clients openssh-server sshpass python3 xfsprogs parted chrony
sudo systemctl enable --now sshd
sudo systemctl enable --now chronyd
```

Rocky Linux 8:

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --set-enabled powertools
sudo dnf install -y epel-release
sudo dnf install -y fio openssh-clients openssh-server sshpass python3 xfsprogs parted chrony
sudo systemctl enable --now sshd
sudo systemctl enable --now chronyd
```

이미 필요한 저장소가 활성화되어 있다면 다음 한 줄만 실행해도 됩니다.

```bash
sudo dnf install -y fio openssh-clients openssh-server sshpass python3 xfsprogs parted chrony
```

설치 확인:

```bash
fio --version
ssh -V
sshpass -V
python3 --version
mkfs.xfs -V
parted --version
systemctl is-active sshd
systemctl is-active chronyd
chronyc tracking
```

SSH 키 인증을 사용할 경우 `REMOTE_PASSWORD`를 빈 값으로 설정하며, 이때 마스터의 `sshpass`는 필수가 아닙니다. 방화벽이나 클라우드 보안 그룹에서도 마스터 VM에서 원격 VM의 SSH 포트(기본값 22)로 접근할 수 있어야 합니다.

동일 epoch에 측정을 시작하므로 마스터와 원격 VM 모두 `chronyd`가 정상 동작해야 합니다. `chronyc tracking`에서 동기화 상태를 확인하십시오. 시스템 시각 차이가 `FIO_MAX_CLOCK_SKEW`를 초과하면 스크립트는 결과 왜곡을 막기 위해 파일 준비 또는 측정을 시작하지 않습니다.

기본 설정은 `size=1G`, `numjobs=16`이므로 VM 한 대에서 최대 약 16GiB의 테스트 파일 공간이 필요할 수 있습니다. `iodepth=64`는 각 job에 적용되므로 VM당 동시 I/O 요청 상한은 `16 × 64 = 1,024`입니다. 고부하 설정이므로 운영 데이터가 없는 별도 테스트 디스크에서만 실행하십시오.

### 전용 데이터 디스크 마운트 권장 구성

fio 테스트는 운영체제의 루트 디스크가 아닌 별도의 테스트용 가상 디스크에서 실행하는 것을 권장합니다. 단순히 `/root/fio`를 `/data/fio`로 이름만 바꾸는 것으로는 충분하지 않으며, `/data`가 실제로 다른 블록 디바이스에 마운트되어 있어야 합니다.

아래에서는 새 빈 디스크가 `/dev/sdb`로 연결되었다고 가정합니다. 환경에 따라 `/dev/vdb`, `/dev/sdc`, `/dev/nvme1n1` 등으로 다를 수 있습니다.

> **데이터 삭제 주의:** `parted`와 `mkfs.xfs`는 선택한 디스크의 기존 데이터를 삭제합니다. `/dev/sdb`를 그대로 복사해 실행하지 말고, 각 VM에서 실제 데이터 디스크 이름을 확인하십시오. 루트 디스크, 사용 중인 디스크, 기존 파일시스템에는 실행하면 안 됩니다.

#### 1. 루트 디스크와 새 데이터 디스크 식별

```bash
findmnt -n -o SOURCE /
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
sudo wipefs -n /dev/sdb
```

`wipefs -n`은 서명을 삭제하지 않고 확인만 합니다. `/dev/sdb` 또는 그 하위 파티션에 `FSTYPE`이나 `MOUNTPOINT`가 표시되거나, 용도를 모르는 데이터가 있으면 중단하십시오. `lsblk` 트리에서 루트(`/`)를 포함한 디스크가 `/dev/sdb`가 아닌지도 반드시 확인합니다.

#### 2. GPT 파티션과 XFS 파일시스템 생성

다음 단계부터는 `/dev/sdb`의 기존 데이터를 삭제합니다.

```bash
sudo parted --script /dev/sdb mklabel gpt
sudo parted --script --align optimal /dev/sdb mkpart primary xfs 0% 100%
sudo partprobe /dev/sdb
sudo udevadm settle
lsblk -f /dev/sdb
```

일반적인 SCSI/SATA 디스크의 첫 파티션은 `/dev/sdb1`입니다. VirtIO 디스크는 `/dev/vdb1`, NVMe 디스크는 `/dev/nvme1n1p1`과 같은 이름이므로 `lsblk` 결과에 맞춰 이후 명령을 변경합니다.

```bash
sudo mkfs.xfs -L fio-data /dev/sdb1
```

`mkfs.xfs`의 기본 생성 옵션은 일반적인 환경에 적합하므로 RAID 스트라이프 구조를 정확히 알지 못한다면 임의의 `su`, `sw` 튜닝을 추가하지 않습니다. 기존 파일시스템을 강제로 덮어쓰는 `-f` 옵션도 사용하지 않습니다.

#### 3. `/data`에 마운트

```bash
sudo mkdir -p /data
sudo mount -o noatime /dev/sdb1 /data
sudo mkdir -p /data/fio
sudo chown root:root /data/fio
sudo chmod 700 /data/fio
```

`noatime`은 fio 전용 파일을 읽을 때 접근 시각 메타데이터 쓰기를 만들지 않습니다. `direct=1`은 기존 `config.env` 기본값이므로 페이지 캐시를 우회합니다.

#### 4. UUID로 영구 마운트 설정

장치 이름(`/dev/sdb1`)은 재부팅 후 달라질 수 있으므로 `/etc/fstab`에는 UUID를 사용합니다. 다음 항목은 한 번만 추가해야 하며, 먼저 백업합니다.

```bash
sudo cp -a /etc/fstab "/etc/fstab.backup.$(date +%Y%m%d_%H%M%S)"
DATA_UUID="$(sudo blkid -s UUID -o value /dev/sdb1)"
test -n "$DATA_UUID" || { echo "UUID 조회 실패" >&2; exit 1; }
printf 'UUID=%s /data xfs defaults,noatime 0 0\n' "$DATA_UUID" | sudo tee -a /etc/fstab
sudo findmnt --verify --verbose
```

등록한 설정이 실제로 다시 마운트되는지 검증합니다. 이 단계는 fio를 실행하기 전에 수행해야 합니다.

```bash
sudo umount /data
sudo systemctl daemon-reload
sudo mount /data
findmnt -T /data/fio
df -hT /data/fio
```

`findmnt -T /data/fio`의 `SOURCE`가 루트(`/`)의 `SOURCE`와 달라야 합니다.

```bash
findmnt -n -o SOURCE /
findmnt -n -o SOURCE -T /data/fio
```

마운트에 실패한 상태로 `/data/fio`에서 테스트하면 루트 디스크의 일반 디렉터리에 파일이 생성될 수 있으므로 실행 전마다 `findmnt -T /data/fio`를 확인하십시오.

#### 5. fio 경로와 초기 부하 설정

각 원격 VM의 데이터 디스크 구성이 끝나면 마스터의 `config.env`에서 다음 값을 사용합니다. 현재 제공되는 `config.env`에도 이 값이 기본으로 반영되어 있습니다.

```bash
FIO_DIRECTORY='/data/fio'
FIO_NUMJOBS=16
FIO_IODEPTH=64
```

먼저 60초 동안 낮은 부하로 확인합니다.

```bash
./fio_test.sh --rw=write --bs=128k --numjobs=1 --iodepth=16 --runtime=60
```

위 명령은 데이터 디스크와 VM의 안정성을 먼저 확인하기 위한 저부하 시험입니다. 기본값 `numjobs=16`, `iodepth=64`는 fio job 16개가 각각 최대 64개의 I/O를 대기시키는 고부하 설정입니다. 별도 데이터 디스크에서도 soft lockup이나 I/O 오류가 발생하면 `numjobs`를 8, 4, 2 순서로 낮추고 `iodepth`도 32 또는 16으로 낮춥니다.

#### 성능 측정 시 권장 사항

- 데이터 디스크는 가능하면 SSD/NVMe 기반의 고성능 볼륨을 사용하고, 프로비저닝된 IOPS와 대역폭 한도를 확인합니다.
- 루트 디스크와 분리된 가상 디스크 및 컨트롤러를 사용합니다. 별도 디스크여도 같은 저속 스토리지 풀을 공유하면 최대 성능은 제한될 수 있습니다.
- XFS 기본 생성 옵션을 우선 사용하고, fio 전용 마운트에는 `noatime`을 적용합니다.
- `discard`를 실시간 마운트 옵션으로 넣지 않습니다. 스토리지가 TRIM을 지원하면 벤치마크 시간 밖에 `fstrim`을 실행하거나 `fstrim.timer`를 사용합니다.
- 여러 VM을 동시에 실행하면 공유 스토리지의 경합 성능을 측정하게 됩니다. VM 한 대의 최대 성능이 목적이라면 VM별로 순차 실행하여 비교합니다.
- 스냅샷 체인이 길거나 스토리지 백엔드에서 마이그레이션·백업 작업이 진행 중인 시간은 피합니다.

TRIM을 지원하는 디스크라면 다음처럼 주기 작업을 활성화할 수 있습니다.

```bash
sudo systemctl enable --now fstrim.timer
```

참고 문서:

- [Red Hat: XFS 파일시스템 생성](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_file_systems/assembly_creating-an-xfs-file-system_managing-file-systems)
- [Red Hat: UUID를 이용한 영구 마운트](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_file_systems/assembly_persistently-mounting-file-systems_managing-file-systems)
- [Red Hat: 파일시스템 I/O 성능과 noatime·discard](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/monitoring_and_managing_system_status_and_performance/factors-affecting-i-o-and-file-system-performance_monitoring-and-managing-system-status-and-performance)

## 설정

1. `config.env`에 공통 계정을 입력합니다.

   ```bash
   REMOTE_USER='root'
   REMOTE_PASSWORD='실제_암호'
   ```

   기본 fio 경로와 병렬 부하는 다음과 같습니다. `/data`가 별도 데이터 디스크로 정상 마운트된 후에만 실행하십시오.

   ```bash
   FIO_DIRECTORY='/data/fio'
   FIO_NUMJOBS=16
   FIO_IODEPTH=64
   ```

   동기 시작 제어값은 다음과 같습니다.

   ```bash
   FIO_SYNC_START_DELAY=10
   FIO_MAX_CLOCK_SKEW=2
   ```

   파일 준비가 모두 끝난 뒤 10초 후의 공통 epoch를 시작 시각으로 예약합니다. VM 수가 많거나 SSH 연결이 느려 예약 시각을 놓친다는 오류가 나오면 `FIO_SYNC_START_DELAY`를 늘립니다.

2. 암호가 다른 사용자에게 노출되지 않게 파일 권한을 제한합니다.

   ```bash
   chmod 600 config.env
   ```

3. `vm_list.txt`에 VM 주소를 한 줄에 하나씩 입력합니다.

   ```text
   192.168.10.101
   192.168.10.102
   ```

4. 필요하면 `MASTER_RESULT_DIR`을 원하는 마스터 경로로 변경합니다. 상대 경로는 이 도구가 있는 폴더 기준입니다.

5. CSV 보고서 파일명을 바꾸려면 `REPORT_FILENAME`을 수정합니다. 경로가 아닌 파일명만 입력합니다.

   ```bash
   REPORT_FILENAME='fio_summary.csv'
   ```

## 실행 방법

기본값인 랜덤 읽기 4K 테스트를 모든 VM에서 동기 실행합니다.

```bash
./fio_test.sh
```

설정 파일을 고쳐 단일 테스트를 실행할 수 있습니다.

```bash
FIO_RW='write'
FIO_BS='128k'
FIO_NUMJOBS=16
FIO_IODEPTH=64
```

또는 실행할 때 달라지는 값만 넘길 수 있습니다. 명령행 값이 `config.env`의 값을 덮어씁니다.

```bash
./fio_test.sh --rw=write --bs=128k --numjobs=16 --iodepth=64
```

6종 테스트를 전부 실행하려면 다음과 같이 실행합니다.

```bash
./fio_test.sh --matrix
```

또는 `config.env`에서 `TEST_MODE='matrix'`로 바꿔도 됩니다. 매트릭스는 다음 순서로 실행됩니다.

1. 랜덤 읽기 4K
2. 랜덤 읽기 8K
3. 순차 읽기 128K
4. 랜덤 쓰기 4K
5. 랜덤 쓰기 8K
6. 순차 쓰기 128K

`FIO_TEST_CASES` 배열의 위쪽 항목부터 실제로 실행됩니다. 기존 데이터가 준비된 파일에서는 읽기 계열을 먼저 수행하여 쓰기 작업이 이후 읽기 결과에 미치는 영향을 줄입니다. 읽기 계열 안에서는 랜덤 읽기를 먼저 실행하고 순차 읽기를 마지막에 실행합니다. 순차 읽기는 파일의 넓은 영역을 읽어 스토리지 또는 하이퍼바이저 캐시를 채울 수 있으므로, 순차 읽기 뒤에 랜덤 읽기를 실행하는 것보다 이 순서가 유리합니다.

`direct=1`은 VM 운영체제의 페이지 캐시를 우회하지만 스토리지 백엔드 캐시까지 제거하지는 않습니다. 테스트 순서에 따른 영향을 더 줄여야 한다면 테스트 사이에 충분한 안정화 시간을 두거나 순서를 반대로 한 추가 측정과 비교하십시오. `--create_only=1`은 파일 공간만 준비하므로 완전히 새로운 파일에서 최초 읽기 성능을 측정할 때는 측정과 별도로 전체 순차 쓰기 초기화를 한 번 수행하는 것이 좋습니다.

스크립트는 먼저 모든 VM에서 `FIO_SIZE × FIO_NUMJOBS` 크기의 테스트 파일을 준비합니다. 한 대라도 준비에 실패하면 어느 VM에서도 성능 측정을 시작하지 않습니다. 준비가 모두 끝나면 첫 번째 항목을 공통 예약 시각에 시작합니다.

Matrix 모드는 항목마다 모든 VM을 같은 예약 시각에 시작하고, 모든 VM의 테스트와 결과 수집이 완료된 뒤 다음 항목으로 넘어갑니다. 따라서 빠른 VM이 다음 항목을 먼저 시작하지 않습니다. 전체 매트릭스의 순수 측정 시간은 `테스트 항목 수 × FIO_RUNTIME`이며 여기에 최초 파일 준비 시간, 항목별 동기 시작 대기 시간, 결과 수집 시간이 추가됩니다.

다른 설정 파일을 사용하려면 환경 변수로 경로를 지정합니다.

```bash
FIO_CONFIG_FILE=/secure/path/config.env ./fio_test.sh
```

지원하는 명령행 옵션은 `./fio_test.sh --help`에서 확인할 수 있습니다.

## 결과

한 번 실행할 때마다 단일 테스트는 `rw-RW값_bs-BS값_실행시각`, 전체 매트릭스는 `matrix_항목수cases_실행시각` 정보를 포함한 폴더가 생성됩니다.

```text
results/rw-randread_bs-4k_20260914_143000/
├── run.info
└── vm01_192.168.10.101_random_read_4k_20260914_143000.log
```

예를 들어 다음 명령의 결과 폴더는 `results/rw-write_bs-128k_실행시각/`으로 만들어집니다.

```bash
./fio_test.sh --rw=write --bs=128k --numjobs=16 --iodepth=64
```

전체 매트릭스 실행 결과는 다음과 같이 구분됩니다.

```text
results/matrix_6cases_20260914_143000/
```

파일명 형식은 다음과 같습니다.

```text
hostname_ip_random|sequential_read|write_blocksize_마스터실행시각.log
```

4K와 8K 결과의 덮어쓰기를 막기 위해 요청한 호스트명, IP, 랜덤/순차, 읽기/쓰기, 실행 시각에 블록 크기를 함께 넣습니다. `run.info`에는 암호를 제외한 실행 시각과 주요 공통 설정이 기록됩니다.

fio 결과는 먼저 원격 VM의 `REMOTE_RESULT_DIR`에 저장된 다음 마스터로 복제됩니다. `KEEP_REMOTE_RESULTS='no'`로 설정하면 마스터 복제 성공 후 원격의 결과 로그만 삭제합니다. fio가 만든 테스트 데이터 파일은 자동 삭제하지 않습니다.

스크립트 종료 코드는 모든 VM이 성공하면 `0`, 하나라도 실패하면 `1`입니다. 준비 단계에서 한 VM이라도 실패하면 전체 측정을 시작하지 않습니다. 측정 중 한 VM이 실패하면 이미 시작한 동일 항목의 다른 VM은 완료 및 결과 수집까지 진행하지만, 이후 Matrix 항목은 실행하지 않습니다.

## CSV 요약 보고서 생성

`fio_test.sh`를 수정하지 않고 별도 `report` 프로그램으로 완료된 결과 폴더를 분석할 수 있습니다.

결과 폴더를 지정하면 해당 폴더 하나만 처리합니다.

```bash
./report ./results/rw-write_bs-128k_20260914_123520
```

기본 출력 파일은 지정한 결과 폴더 아래에 생성되며, 파일명은 `config.env`의 `REPORT_FILENAME`으로 설정합니다.

```bash
REPORT_FILENAME='fio_summary.csv'
```

```text
CSV 생성 완료: /opt/fio-test/results/rw-write_bs-128k_20260914_123520/fio_summary.csv
가상머신: 2대, 테스트 항목: 1개
```

결과 폴더를 지정하지 않으면 `results/` 바로 아래의 모든 실행 폴더를 강제로 순회하고, 각 폴더에 `config.env`의 `REPORT_FILENAME` 값으로 CSV를 생성합니다. 기본 파일명은 `fio_summary.csv`입니다.

```bash
./report
```

```text
전체 결과 폴더 처리 시작: /opt/fio-test/results (3개)
CSV 생성 완료: /opt/fio-test/results/rw-write_bs-128k_.../fio_summary.csv
...
전체 처리 완료: CSV 생성 2개, 건너뜀 1개
```

fio 결과 로그가 없는 실패 폴더는 경고와 함께 건너뛰고 나머지 폴더 처리를 계속합니다. 전체 처리에서는 CSV가 각 실행 폴더에 저장되므로 `-o` 옵션을 사용할 수 없습니다.

CSV는 다음과 같이 VM마다 IOPS와 대역폭 행을 생성합니다.

```csv
가상머신,항목,순차 쓰기 성능 (128K)
localhost.localdomain_10.10.254.244,IOPS,84
localhost.localdomain_10.10.254.244,대역폭,10.6MiB/s
localhost.localdomain_10.10.254.245,IOPS,89
localhost.localdomain_10.10.254.245,대역폭,11.2MiB/s
평균,IOPS,86.5
평균,대역폭,10.9MiB/s
합계,IOPS,173
합계,대역폭,21.8MiB/s
```

CSV 마지막에는 테스트 항목별 VM 평균과 합계가 각각 IOPS와 대역폭으로 추가됩니다. IOPS는 `k`, `M` 등의 배율을 실제 숫자로 환산하고, 대역폭은 `KiB/s`, `MiB/s`, `GiB/s` 등을 바이트/초로 통일한 뒤 계산하므로 VM마다 표시 단위가 달라도 정상적으로 합산됩니다. 합계 대역폭은 같은 시각에 실행된 모든 VM의 집계 처리량을 의미합니다. 특정 VM의 결과가 누락된 항목은 해당 열에 존재하는 정상 결과만으로 평균과 합계를 계산합니다.

Matrix 결과 폴더를 지정하면 폴더에서 발견한 랜덤/순차, 읽기/쓰기, 블록 크기별 테스트를 자동으로 각각의 열로 구성합니다. 특정 경로에 저장하려면 `-o`를 사용합니다.

```bash
./report ./results/matrix_6cases_20260914_143000 -o ./matrix_summary.csv
```

CSV는 Excel에서도 한글이 깨지지 않도록 UTF-8 BOM 형식으로 저장됩니다. `report`는 Python 3.6 이상에서 동작하며 외부 Python 패키지는 필요하지 않습니다. 분석할 수 없는 로그가 있으면 해당 파일명을 경고로 출력하고 나머지 정상 결과로 보고서를 생성합니다.

## 오류 확인

`config.env`의 SSH 사용자 또는 암호가 원격 VM의 계정 정보와 일치하지 않으면 다음과 같이 출력됩니다.

```text
[VM_IP] SSH 인증 실패: config.env의 REMOTE_USER 또는 REMOTE_PASSWORD가 원격 VM의 계정 정보와 일치하지 않습니다.
[VM_IP] config.env의 REMOTE_USER/REMOTE_PASSWORD 값을 확인한 뒤 다시 실행하세요. (sshpass 종료 코드: 5)
```

이 오류는 터미널과 해당 실행 결과 폴더의 `errors.log`에 기록됩니다. `config.env`의 값을 수정한 다음 다시 실행합니다.

```bash
REMOTE_USER='root'
REMOTE_PASSWORD='원격_VM의_실제_암호'
```

`Permission denied` 없이 직접 접속되는지 먼저 확인하려면 다음 명령을 사용할 수 있습니다. 암호가 명령행이나 셸 기록에 직접 남지 않도록 `sshpass -e`를 사용합니다.

```bash
set +x
source ./config.env
export SSHPASS="$REMOTE_PASSWORD"
sshpass -e ssh -p "$REMOTE_SSH_PORT" "$REMOTE_USER@VM_IP" 'hostname; fio --version'
unset SSHPASS
```

## 주의 사항

- `config.env`는 Bash로 읽는 신뢰된 설정 파일입니다. 신뢰할 수 없는 내용을 넣지 마십시오.
- 기본 `SSH_HOST_KEY_CHECKING='accept-new'`는 최초 접속 키를 등록하고 이후 변경된 키를 거부합니다. 중요한 환경에서는 미리 `known_hosts`를 구성하고 `yes`를 사용하십시오.
- 성능 테스트 중에는 디스크 I/O 부하가 매우 높아집니다. 운영 VM이나 운영 데이터 경로에서는 실행하지 마십시오.
