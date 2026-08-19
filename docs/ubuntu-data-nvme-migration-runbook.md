# Ubuntu `/data` HDD -> NVMe 마이그레이션 런북

<!-- Updated: 2026-08-18 -->

## 목적

Ubuntu 서버의 기존 HDD에 마운트된 `/data` 전체를 새 1TB NVMe SSD로 이전한다.
Docker의 data root가 `/data/docker`이므로 새 SSD도 같은 `/data` 경로에 마운트한다.
Docker 설정과 Compose volume 경로는 바꾸지 않는다.

이 문서는 정상적인 이전 절차만 다룬다. 출력이 예상과 다르거나 특수 저장소 구성이
발견되면 [문제 발생 시 참고 부록](./ubuntu-data-nvme-migration-troubleshooting.md)을
확인한다.

## 확인된 서버 기준

| 항목 | 값 |
|---|---|
| OS | Ubuntu 22.04.3 LTS |
| Kernel | `6.8.0-136-generic` |
| Mainboard | GIGABYTE Z390 AORUS ELITE |
| OS disk | `/dev/nvme0n1`, `INTEL SSDPEKKF256G8L`, 256GB |
| 기존 data disk | `ST1000DM003-1CH162`, serial `Z1D5E942` |
| 기존 data filesystem | HDD 전체의 ext4, `/data` |
| 기존 `/data` 사용량 | 약 335GB |
| Docker data root | `/data/docker` |
| Docker 저장 구조 | 현재 관찰된 구조는 classic `overlay2` |
| 신규 disk | 장착 전인 1TB M.2 NVMe |
| TRIM | `fstrim.timer` enabled/active |

장착 후 장치명은 바뀔 수 있다. 이 표의 모델과 serial을 기준으로 다시 식별한다.

## 실행 전 원칙

1. `<NEW_NVME_DEVICE>`, `<NEW_NVME_PARTITION>`, UUID와 container 이름은
   자리표시자다. 실제 출력으로 교체하기 전에는 명령을 실행하지 않는다.
2. 다음 두 디스크에는 `parted`나 `mkfs`를 실행하지 않는다.
   - OS NVMe: `INTEL SSDPEKKF256G8L`
   - 기존 HDD: `ST1000DM003-1CH162`, serial `Z1D5E942`
3. `docker compose down -v`, `docker volume rm`, `docker system prune`,
   `rm -rf`와 `mkfs -F`는 사용하지 않는다.
4. 최종 복사는 모든 container와 Docker를 멈춘 상태에서 수행한다.
5. 기존 HDD는 이전 성공 후에도 최소 1~2주 포맷하지 않는다.
6. 이 문서는 한 번에 실행하는 script가 아니다. 각 단계의 확인 결과를 보고 다음
   단계로 진행한다.

모든 `bash` 코드 블록은 Ubuntu의 Bash에서 한 블록씩 실행하는 형식이다.

작업 시작 전에 다음 값을 메모한다.

| 값 | 실제 확인값 |
|---|---|
| 기존 HDD device/by-id | |
| 기존 HDD filesystem UUID | |
| 신규 NVMe device/by-id | |
| 신규 NVMe partition | |
| 신규 NVMe filesystem UUID | |
| Stock MySQL container | |
| Stock Redis container | |
| Stock back container | |
| Stock batch container | |
| Mattermost DB 종류 | |
| Mattermost DB container | |
| Mattermost app container | |

## 1. 새 NVMe 장착 및 식별

### 1.1 장착 전 상태 확인

`/data`가 기존 HDD에서 마운트되고 `/etc/fstab`에도 등록되어 있는지 확인한다.

```bash
findmnt -no SOURCE,UUID,FSTYPE,OPTIONS /data
findmnt --fstab --target /data
docker info --format 'Root={{.DockerRootDir}} Driver={{.Driver}}'
docker compose ls --all
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
lsblk -e 7 -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL,TRAN
```

예상 Docker 값은 `Root=/data/docker Driver=overlay2`다. 값이 다르면 현재
런북을 그대로 적용하지 말고 부록의 Docker 저장소 경계를 확인한다.

실행 중인 장시간 배치, DB 백업 또는 배포가 없을 때 정상 종료한다.

```bash
cd ~
sudo shutdown -h now
```

팬과 LED가 멈춘 뒤 전원 케이블을 분리하고 전원 버튼을 약 5초 눌러 잔류 전원을
방전한다. 기존 OS NVMe와 HDD는 제거하지 않고 빈 M.2 슬롯에 신규 NVMe를 장착한다.

Z390 AORUS ELITE에서 M2M 슬롯에 PCIe NVMe를 설치하면 `SATA3_4`와
`SATA3_5`가 비활성화된다. 부팅 후 기존 HDD가 보이지 않으면 고장으로 단정하지 말고
서버를 다시 완전히 끈 뒤 HDD SATA 케이블을 공유되지 않는 포트로 옮긴다.
BIOS의 RAID/AHCI와 UEFI 설정은 바꾸지 않는다.

### 1.2 부팅 후 세 디스크 식별

```bash
lsblk -e 7 -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL,TRAN
sudo fdisk -l
sudo nvme list
ls -l /dev/disk/by-id/
findmnt -no SOURCE,UUID,FSTYPE,OPTIONS /data
```

`nvme`, `smartctl`, `parted` 또는 `rsync`가 없다면 필요한 도구만 설치한다.
이 작업과 OS 전체 업그레이드는 함께 하지 않는다.

```bash
sudo apt update
sudo apt install nvme-cli smartmontools parted rsync
```

다음을 모두 확인해야 한다.

- 기존 OS NVMe `INTEL SSDPEKKF256G8L`이 보인다.
- 기존 HDD 모델과 serial `ST1000DM003-1CH162_Z1D5E942`가 보인다.
- 새 1TB NVMe를 구매한 모델과 serial로 구분할 수 있다.
- `/data`가 여전히 기존 HDD에서 마운트된다.

기존 HDD와 새 NVMe의 기본 상태도 확인한다.

```bash
sudo smartctl -H -A <OLD_HDD_DEVICE>
sudo smartctl -x <NEW_NVME_DEVICE>
```

HDD health 실패, pending/uncorrectable sector, NVMe critical warning 또는 반복적인
I/O 오류가 있으면 일반 `rsync`를 시작하지 않고 부록을 확인한다.

## 2. GPT 파티션과 ext4 생성

> 이 단계부터 선택한 신규 NVMe의 기존 내용이 삭제된다.

신규 NVMe와 하위 파티션이 마운트되지 않았는지 먼저 확인한다.

```bash
lsblk -nrpo NAME,TYPE,FSTYPE,MOUNTPOINTS <NEW_NVME_DEVICE>
```

신규 NVMe임이 모델과 serial로 확정된 경우에만 실행한다.

```bash
sudo parted --script <NEW_NVME_DEVICE> mklabel gpt
sudo parted --script --align optimal <NEW_NVME_DEVICE> mkpart data-ssd ext4 1MiB 100%
sudo partprobe <NEW_NVME_DEVICE>
sudo udevadm settle
sudo parted <NEW_NVME_DEVICE> align-check optimal 1
```

`1 aligned`가 나와야 한다. 생성된 파티션이 신규 NVMe의 자식인지 확인한다.

```bash
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
```

신규 파티션을 ext4로 포맷한다.

```bash
sudo mkfs.ext4 -L data-ssd -m 1 <NEW_NVME_PARTITION>
sudo blkid <NEW_NVME_PARTITION>
```

출력된 filesystem UUID를 작업 메모에 기록한다.

## 3. 새 NVMe 임시 마운트

```bash
findmnt -S <NEW_NVME_PARTITION>
sudo mkdir -p /mnt/data-ssd-stage
sudo mount <NEW_NVME_PARTITION> /mnt/data-ssd-stage
findmnt -T /mnt/data-ssd-stage
df -hT /mnt/data-ssd-stage
sudo find /mnt/data-ssd-stage -mindepth 1 -maxdepth 1 -not -name lost+found -print
```

확인 조건:

- 첫 `findmnt` 명령은 출력이 없어야 한다. 자동 mount되어 있으면 실제 장치를
  확인한 뒤 먼저 unmount한다.
- SOURCE가 신규 NVMe 파티션이다.
- FSTYPE이 ext4이고 read-write다.
- 마지막 `find` 명령의 출력이 없다.

예상하지 않은 파일이 있으면 복사하지 않는다.

## 4. DB 논리 백업과 설정 백업

### 4.1 현재 상태 기록

`/etc/fstab`과 기존 mount UUID를 보존한다.

```bash
findmnt -no SOURCE,UUID,FSTYPE,OPTIONS /data
sudo blkid <OLD_HDD_DEVICE>
sudo cp -a /etc/fstab "/etc/fstab.pre-data-nvme-$(date +%Y%m%d-%H%M%S)"
```

원래 실행 중인 container와 실제 mount를 기록한다.

```bash
docker info --format 'Root={{.DockerRootDir}} Driver={{.Driver}}' \
  > ~/docker-storage-pre-data-nvme.txt
docker ps --format '{{.Names}}' | LC_ALL=C sort \
  > ~/docker-running-pre-data-nvme.txt
docker ps -a --no-trunc \
  > ~/docker-containers-pre-data-nvme.txt
docker compose ls --all \
  > ~/docker-compose-pre-data-nvme.txt
docker ps -aq | xargs -r docker inspect \
  --format '{{.Name}} {{range .Mounts}}{{.Type}}:{{.Source}}->{{.Destination}} {{end}}' \
  > ~/docker-mounts-pre-data-nvme.txt
```

### 4.2 백업 디렉터리 생성

```bash
if sudo test -e /data/.migration-backup; then
  echo 'Stop: source /data/.migration-backup already exists'
  false
fi

sudo install -d -m 0700 -o "$(id -u)" -g "$(id -g)" \
  /mnt/data-ssd-stage/.migration-backup
```

이 디렉터리는 뒤의 `rsync`에서 제외한다. 같은 신규 NVMe 안의 논리 백업은
추가 복구 수단일 뿐 외장 디스크나 원격 백업을 대신하지 않는다.

### 4.3 Stock MySQL 백업

다음 예시는 container 안에 `MYSQL_ROOT_PASSWORD`가 설정된 현재 인증 방식을
사용한다. secret file이나 별도 backup 계정을 사용한다면 실제 운영 인증 방식에 맞춘다.
비밀번호를 명령행에 직접 적지 않는다.

```bash
(
set -euo pipefail
umask 077
STOCK_MYSQL_DUMP_PATH="/mnt/data-ssd-stage/.migration-backup/stock-mysql-pre-nvme-$(date +%Y%m%d-%H%M%S).sql.gz"

docker exec <STOCK_MYSQL_CONTAINER> sh -c \
  'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" \
    --all-databases --single-transaction --quick --hex-blob \
    --routines --events --triggers --set-gtid-purged=OFF' \
  | gzip -1 > "$STOCK_MYSQL_DUMP_PATH"

test -s "$STOCK_MYSQL_DUMP_PATH"
gzip -t "$STOCK_MYSQL_DUMP_PATH"
ls -lh "$STOCK_MYSQL_DUMP_PATH"
)
```

### 4.4 Mattermost PostgreSQL 백업

Mattermost DB가 PostgreSQL일 때 다음 형식을 사용한다.

```bash
(
set -euo pipefail
umask 077
MATTERMOST_PG_DUMP_PATH="/mnt/data-ssd-stage/.migration-backup/mattermost-postgres-pre-nvme-$(date +%Y%m%d-%H%M%S).sql.gz"

docker exec <MATTERMOST_DB_CONTAINER> sh -c \
  'PG_DUMP_USER="${POSTGRES_USER:-postgres}";
   exec pg_dumpall -w -U "$PG_DUMP_USER"' \
  | gzip -1 > "$MATTERMOST_PG_DUMP_PATH"

test -s "$MATTERMOST_PG_DUMP_PATH"
gzip -t "$MATTERMOST_PG_DUMP_PATH"
ls -lh "$MATTERMOST_PG_DUMP_PATH"
)
```

dump가 실패하면 인증 방식을 확인하고 성공한 백업을 만들기 전에는 진행하지 않는다.
Mattermost가 PostgreSQL이 아니거나 더 강한 dump 검증이 필요하면 부록을 확인한다.

## 5. 선택 사항: 온라인 1차 rsync

서비스 중단 시간을 줄여야 할 때만 실행한다. 실행 중인 DB와 Docker 파일은 이 시점에
일관된 최종본이 아니며, 6~7단계의 정지 상태 최종 복사를 반드시 수행해야 한다.
HDD 부하가 커질 수 있으므로 서비스 지연을 감수할 수 없는 시간에는 실행하지 않는다.

```bash
sudo rsync -aHAXSx --numeric-ids --info=progress2 \
  --exclude=/lost+found \
  --exclude=/.migration-backup/ \
  /data/ /mnt/data-ssd-stage/
```

전체 서비스 중단 시간을 허용할 수 있으면 이 단계를 건너뛰고 7단계에서 한 번만
정지 상태로 복사하는 편이 더 단순하다.

## 6. 모든 container와 Docker 정상 종료

`/data` 밖으로 이동한 뒤 Stock batch와 application writer를 먼저 멈추고 나머지
container를 정상 종료한다. 실제 container 이름은 4단계에서 기록한 값을 사용한다.
다른 application/worker container가 있으면 첫 명령에 함께 넣고 DB/cache보다 먼저
멈춘다.

```bash
cd ~
docker stop -t 300 <STOCK_BATCH_CONTAINER> <STOCK_BACK_CONTAINER> <MATTERMOST_APP_CONTAINER>
docker ps -q | xargs -r docker stop -t 300
docker ps
```

마지막 `docker ps`의 목록이 비어야 한다. DB container의 최근 로그에 정상 shutdown이
보이는지도 확인한다.

```bash
docker logs --since 10m --tail 200 <STOCK_MYSQL_CONTAINER>
docker logs --since 10m --tail 200 <MATTERMOST_DB_CONTAINER>
```

그다음 Docker 관련 unit을 멈춘다.

```bash
sudo systemctl stop docker.service docker.socket containerd.service
systemctl is-active docker.service docker.socket containerd.service
pgrep -a dockerd
pgrep -a containerd
findmnt -Rno TARGET,SOURCE,FSTYPE /data
sudo fuser -vm /data
```

확인 조건:

- 세 unit이 `inactive`다.
- `dockerd`와 `containerd` process 출력이 없다.
- `/data` 아래에 Docker overlay나 다른 child mount가 없다.
- `/data`에 쓰는 user-space process가 없다.

조건을 만족하지 않으면 최종 복사를 시작하지 않고 부록의 “`/data`가 busy인 경우”를
확인한다.

## 7. 정지 상태 최종 rsync

원본과 목적지를 다시 확인한다.

```bash
findmnt -T /data
findmnt -T /mnt/data-ssd-stage
df -hT /data /mnt/data-ssd-stage
```

- `/data` SOURCE는 기존 HDD여야 한다.
- `/mnt/data-ssd-stage` SOURCE는 신규 NVMe 파티션이어야 한다.
- 신규 NVMe의 여유 공간이 충분해야 한다.

최종 복사를 실행한다. `--delete`는 온라인 1차 복사 후 원본에서 삭제된 파일을
목적지에서도 제거한다. 제외된 `.migration-backup`과 `lost+found`는 삭제하지 않는다.

```bash
sudo rsync -aHAXSx --numeric-ids --delete --info=progress2 \
  --exclude=/lost+found \
  --exclude=/.migration-backup/ \
  /data/ /mnt/data-ssd-stage/
sync
```

`rsync`가 0이 아니면 mount를 전환하지 않는다. 같은 명령을 다시 실행해 오류 없이
끝난 뒤 metadata 기준 dry-run을 수행한다.

```bash
sudo rsync -aHAXSxn --numeric-ids --delete --itemize-changes \
  --exclude=/lost+found \
  --exclude=/.migration-backup/ \
  /data/ /mnt/data-ssd-stage/
```

출력이 없어야 한다. 이 검증은 전체 파일 내용을 다시 읽는 checksum 검사가 아니다.
전체 checksum이 필요한 조건과 명령은 부록에 둔다.

## 8. `/data`의 fstab UUID 교체

신규 NVMe UUID를 다시 확인한다.

```bash
sudo blkid <NEW_NVME_PARTITION>
findmnt -T /mnt/data-ssd-stage
```

`/etc/fstab`을 편집하고 기존 `/data` 행의 source UUID만 신규 UUID로 바꾼다.
기존 행을 남겨둔 채 두 번째 `/data` 행을 추가하지 않는다.

```bash
sudoedit /etc/fstab
```

형식은 다음과 같다.

```fstab
UUID=<NEW_NVME_FILESYSTEM_UUID> /data ext4 defaults 0 2
```

`nofail`과 continuous `discard`는 추가하지 않는다. 현재 활성화된
`fstrim.timer`가 주기적인 TRIM을 담당한다.

fstab을 검증한 후에만 mount를 전환한다.

```bash
sudo findmnt --verify --verbose
sudo systemctl daemon-reload
sudo umount /mnt/data-ssd-stage
sudo umount /data
sudo mount /data
```

`umount`가 busy로 실패하면 `umount -l`을 사용하지 않는다. Docker나 writer가 남았는지
확인한다. 신규 `/data` mount가 실패하면 Docker를 시작하지 않고 fstab 백업과 기존
HDD UUID를 사용해 원래 mount를 복구한다. 상세 순서는 부록에 있다.

## 9. 새 `/data` 확인 후 Docker와 서비스 시작

Docker를 시작하기 전에 mount를 먼저 검증한다.

```bash
findmnt -no SOURCE,UUID,FSTYPE,OPTIONS /data
findmnt -T /data/docker
df -hT /data
sudo ls -ld /data/docker /data/docker/overlay2 /data/docker/volumes
```

SOURCE와 UUID가 신규 NVMe여야 한다. 확인 후 Docker를 시작한다.

```bash
sudo systemctl start containerd.service docker.service
docker info --format 'Root={{.DockerRootDir}} Driver={{.Driver}}'
docker ps -a --format 'table {{.Names}}\t{{.State}}\t{{.Status}}'
docker volume ls
```

Docker root가 계속 `/data/docker`이고 기존 container와 volume이 보여야 한다.
restart policy로 자동 시작되지 않았다면 DB와 cache를 먼저 시작하고 준비된 다음
application을 시작한다.

```bash
docker start <STOCK_MYSQL_CONTAINER> <STOCK_REDIS_CONTAINER> <MATTERMOST_DB_CONTAINER>
docker start <STOCK_BACK_CONTAINER> <MATTERMOST_APP_CONTAINER>
docker start <STOCK_BATCH_CONTAINER>
```

그 밖에 4단계에서 원래 실행 중으로 기록한 container도 기존 dependency 순서대로
복원한다.

## 10. DB, Stock, Mattermost 검증

container 상태와 핵심 로그를 확인한다.

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
docker logs --since 10m --tail 500 <STOCK_MYSQL_CONTAINER>
docker logs --since 10m --tail 500 <MATTERMOST_DB_CONTAINER>
docker logs --since 10m --tail 500 <STOCK_BACK_CONTAINER>
docker logs --since 10m --tail 500 <STOCK_BATCH_CONTAINER>
docker logs --since 10m --tail 500 <MATTERMOST_APP_CONTAINER>
```

다음 오류가 없어야 한다.

- DB corruption 또는 recovery 실패
- permission denied
- read-only filesystem
- InnoDB redo, PostgreSQL WAL 또는 tablespace 오류
- container의 반복 restart 또는 unhealthy 상태

현재 운영 인증 방식으로 DB와 cache를 확인한다.

```bash
docker exec <STOCK_MYSQL_CONTAINER> sh -c \
  'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES;"'
docker exec <MATTERMOST_DB_CONTAINER> sh -c \
  'exec pg_isready -U "${POSTGRES_USER:-postgres}"'
docker exec <STOCK_REDIS_CONTAINER> redis-cli ping
```

추가로 다음 실제 기능을 확인한다.

- Stock back API와 Stock batch system status가 응답한다.
- `STOCK_SERVICE`와 `STOCK_BATCH_METADATA` schema 및 주요 table이 보인다.
- Mattermost 로그인, 메시지 조회/작성과 기존 첨부파일 조회가 된다.
- 4단계에서 기록한 원래 실행 container가 모두 복원되었다.

원래 실행 목록과 현재 실행 목록도 이름 기준으로 비교한다.

```bash
docker ps --format '{{.Names}}' | LC_ALL=C sort \
  > ~/docker-running-post-data-nvme.txt
comm -23 ~/docker-running-pre-data-nvme.txt \
  ~/docker-running-post-data-nvme.txt
```

`comm` 출력이 있으면 이전에 실행 중이었지만 아직 복원되지 않은 container다.

Stock batch의 `order-book-execution` SQL timeout은 별도 문제다. NVMe 이전으로 I/O
대기시간이 줄 수는 있지만 비효율적인 SQL, index 부족 또는 lock 경합까지 해결되었다고
판정하지 않는다.

## 11. 재부팅 검증

서비스가 안정된 다음 한 번 재부팅한다.

```bash
sudo reboot
```

재부팅 후 확인한다.

```bash
findmnt -no SOURCE,UUID,FSTYPE,OPTIONS /data
findmnt -T /data/docker
docker info --format 'Root={{.DockerRootDir}} Driver={{.Driver}}'
docker ps -a --format 'table {{.Names}}\t{{.State}}\t{{.Status}}'
systemctl is-enabled fstrim.timer
systemctl is-active fstrim.timer
```

`/data`가 신규 NVMe UUID로 자동 마운트되고 Docker root가 `/data/docker`여야 한다.
누락된 container가 있다면 DB/cache부터 기존 순서로 시작한다. 10단계의 로그, DB,
Stock과 Mattermost 기능 검증을 다시 수행한다.

## 12. 기존 HDD 보관

기존 HDD는 최소 1~2주 포맷하지 않는다. 자동 mount되어 있지 않은지 확인한다.

```bash
findmnt -S UUID=<OLD_HDD_FILESYSTEM_UUID>
```

내용 확인이 필요하면 `/data`가 아닌 별도 경로에 읽기 전용으로 마운트한다.

```bash
sudo mkdir -p /mnt/data-hdd-old
sudo mount -o ro,noload UUID=<OLD_HDD_FILESYSTEM_UUID> /mnt/data-hdd-old
findmnt -T /mnt/data-hdd-old
sudo umount /mnt/data-hdd-old
```

신규 NVMe 전환 후 DB나 첨부파일에 새 쓰기가 발생하면 기존 HDD는 오래된 사본이다.
그 상태에서 단순히 HDD로 되돌리면 전환 이후 데이터가 유실된다. 롤백이 필요하면
[부록의 롤백 절차](./ubuntu-data-nvme-migration-troubleshooting.md#8-롤백)를 따른다.

## 정상 완료 기준

- 신규 NVMe가 UUID 기준으로 `/data`에 마운트된다.
- 재부팅 후에도 같은 mount가 유지된다.
- Docker root가 `/data/docker`이고 기존 container와 volume이 보인다.
- Stock MySQL, Redis, Stock back, Stock batch, Mattermost DB/app이 정상이다.
- Mattermost 기존 메시지와 첨부파일이 조회된다.
- 기존 HDD가 변경되지 않은 상태로 보관된다.

## 참고자료

- [GIGABYTE Z390 AORUS ELITE manual](https://download.gigabyte.com/FileList/Manual/mb_manual_z390-aorus-elite_v3_e.pdf)
- [Docker daemon data directory](https://docs.docker.com/engine/daemon/)
- [Docker OverlayFS storage driver](https://docs.docker.com/engine/storage/drivers/overlayfs-driver/)
- [Ubuntu 22.04 rsync manual](https://manpages.ubuntu.com/manpages/jammy/man1/rsync.1.html)
- [Ubuntu 22.04 fstab manual](https://manpages.ubuntu.com/manpages/jammy/man5/fstab.5.html)
- [MySQL mysqldump](https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html)
- [PostgreSQL pg_dumpall](https://www.postgresql.org/docs/current/app-pg-dumpall.html)
- [Ubuntu fstrim manual](https://manpages.ubuntu.com/manpages/jammy/en/man8/fstrim.8.html)
