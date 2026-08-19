# Ubuntu `/data` HDD -> NVMe 마이그레이션: 문제 발생 시 참고

<!-- Updated: 2026-08-18 -->

## 목적

이 문서는 [실행용 런북](./ubuntu-data-nvme-migration-runbook.md)의 정상 경로에 포함하지
않은 조건부 점검과 복구 절차를 모은 부록이다. 정상 출력이 나온다면 이 문서를 처음부터
끝까지 실행할 필요가 없다.

다음 상황에서 해당 절만 확인한다.

- `/data`가 busy이거나 최종 dry-run에서 차이가 계속 발생한다.
- Docker volume이 `local`이 아니거나 bind mount가 `/data` 밖에 있다.
- Docker가 classic `overlay2`가 아닌 containerd image store를 사용한다.
- Mattermost PostgreSQL에 사용자 tablespace가 있다.
- DB dump를 더 강하게 검증해야 한다.
- 원본과 대상 전체 checksum 검사가 필요하다.
- Docker가 `/data` mount 없이 시작하지 못하도록 영구 보호하고 싶다.
- 전환 실패로 기존 HDD 롤백이 필요하다.

## 1. `/data`가 busy이거나 계속 변경되는 경우

정지 상태 최종 복사 직전에 다음 두 명령을 확인한다.

```bash
findmnt -Rno TARGET,SOURCE,FSTYPE /data
sudo fuser -vm /data
```

`findmnt`에는 `/data` 자체만 남아야 한다. Docker overlay, NFS, FUSE 또는 다른
child mount가 남으면 `rsync -x`가 해당 mount의 내용을 건너뛴다.

`fuser`에 Docker, DB, application, backup, sync 또는 Git writer가 보이면 해당
프로세스를 정상 종료한다. 원인을 모른 채 kill하거나 `umount -l`을 사용하지 않는다.

host service나 예약 작업이 `/data`를 다시 쓰는 것이 의심될 때만 다음 범위로 확인한다.

```bash
systemctl list-units --type=service --state=running --no-pager
systemctl list-timers --all --no-pager
crontab -l
sudo crontab -l
```

- backup, sync, Jenkins, certbot, 자체 batch 중 실제로 `/data`를 쓰는 항목만 중지한다.
- 모든 timer를 일괄 disable하지 않는다.
- 원래 enabled/active 상태를 기록하고 이전 완료 후 같은 상태로 복원한다.
- 운영 중인 335GB HDD에 광범위한 `find`, `du` 또는 `lsof +D /data`를 반복하지 않는다.

writer를 제거한 뒤 실행용 런북의 최종 `rsync`를 다시 실행한다.

## 2. 외부 Docker volume과 `/data` 밖 bind mount

실제 container mount와 volume driver를 확인한다.

```bash
docker ps -aq | xargs -r docker inspect \
  --format '{{.Name}} {{range .Mounts}}{{.Type}}:{{.Source}}->{{.Destination}} {{end}}'
docker volume ls --format '{{.Driver}}\t{{.Name}}'
docker volume ls -q | xargs -r docker volume inspect \
  --format '{{.Name}} driver={{.Driver}} mountpoint={{.Mountpoint}}'
docker plugin ls
```

판단 기준:

- `local` named volume의 mountpoint가 `/data/docker/volumes` 아래라면 `/data`
  복사에 포함된다.
- `/data/...` bind mount는 `/data` 복사에 포함된다.
- `/data` 밖 bind mount는 기존 위치에 남으며 이번 이전 대상이 아니다.
- 외부 volume driver의 데이터는 driver별 저장 위치와 backup/restore 계약을 확인해야
  한다. `/data` 복사에 자동 포함된다고 가정하지 않는다.
- `/data` 아래에 별도 filesystem이 child mount되어 있으면 `rsync -x`가 건너뛴다.
  별도 filesystem을 원래 위치에 유지할지 따로 이전할지 먼저 결정한다.

Mattermost 첨부파일이 local filesystem이 아니라 object storage라면 해당 object storage는
이번 block-device 이전과 무관하다. 반대로 local filesystem이면 실제 mount source가
`/data` 안에 있는지 확인한다.

## 3. Docker containerd image store

Docker Engine 29의 신규 설치는 containerd image store를 사용할 수 있다. Compose
버전만으로는 저장 방식을 판단할 수 없다.

```bash
docker info --format 'Root={{.DockerRootDir}} Driver={{.Driver}}'
docker info --format '{{json .DriverStatus}}'
docker info | sed -n '/Storage Driver/,+12p'

if sudo test -f /etc/containerd/config.toml; then
  sudo grep -nE '^[[:space:]]*(root|state)[[:space:]]*=' \
    /etc/containerd/config.toml
fi
```

`Root=/data/docker Driver=overlay2`이고 `/data/docker/overlay2`가 실제로 사용되는
classic 구성이라면 실행용 런북 외의 containerd 복사는 필요하지 않다.

containerd snapshotter가 사용되면 image layer와 snapshot이 기본적으로
`/var/lib/containerd`에 있을 수 있다. 이 경우:

- `/data`만 새 NVMe로 옮겨도 `/var/lib/containerd`는 OS SSD에 그대로 남는다.
- 모든 Docker I/O를 새 NVMe로 옮기는 것이 목적이라면 containerd root 변경을 별도
  유지보수 작업으로 설계한다.
- `/var/lib/containerd`를 추측으로 `/data`에 복사하거나 symbolic link로 바꾸지 않는다.
- Docker와 containerd 버전 업그레이드 또는 storage driver 변경을 이번 작업과 섞지 않는다.

## 4. PostgreSQL 사용자 tablespace와 다른 DB 종류

Mattermost PostgreSQL의 tablespace를 확인한다.

```bash
docker exec <MATTERMOST_DB_CONTAINER> sh -c \
  'PG_DUMP_USER="${POSTGRES_USER:-postgres}";
   exec psql -w -U "$PG_DUMP_USER" -d postgres -Atqc \
   "SELECT spcname, pg_tablespace_location(oid)
      FROM pg_tablespace
     ORDER BY spcname"'
```

`pg_default`와 `pg_global` 외 tablespace가 별도 host path를 사용하면 그 경로를
Docker mount 목록과 대조한다.

- 경로가 `/data` 안이면 cold copy에 포함되는지 child mount 여부까지 확인한다.
- 경로가 `/data` 밖이면 기존 위치에 남기거나 별도 이전한다.
- tablespace 위치를 확인하지 못했다면 PostgreSQL을 새 위치에서 시작하기 전에
  원인을 해결한다.

Mattermost가 MySQL/MariaDB라면 `pg_dumpall`을 사용하지 않는다. 실제 DB 이미지와
인증 방식에 맞는 `mysqldump` 또는 `mariadb-dump`를 사용한다.

## 5. DB dump 강화 검증

실행용 런북의 `gzip -t`는 압축 파일 손상 여부를 확인하지만 SQL을 실제로 복원할 수
있다는 뜻은 아니다.

### 5.1 checksum 파일

백업 파일을 외장 디스크나 다른 서버로 옮길 때 checksum을 한 번 생성할 수 있다.

```bash
cd /mnt/data-ssd-stage/.migration-backup
sha256sum <DUMP_FILE.sql.gz> > <DUMP_FILE.sql.gz>.sha256
sha256sum -c <DUMP_FILE.sql.gz>.sha256
```

동일 파일을 같은 장치에서 단계마다 반복 검사할 필요는 없다.

### 5.2 실제 복원 시험

가장 강한 검증은 운영 DB와 격리된 동일 major version instance에 복원하는 것이다.
운영 container나 운영 volume을 복원 시험 대상으로 사용하지 않는다.

- MySQL은 dump의 schema, routine, event와 주요 table row를 확인한다.
- PostgreSQL은 database, role, ownership와 extension 오류를 확인한다.
- 임시 instance가 운영 port, network 또는 volume을 공유하지 않게 한다.

### 5.3 MySQL `--single-transaction` 한계

`--single-transaction`은 InnoDB table의 online 일관성에 적합하다. application
schema에 다른 engine이 있는지 필요한 경우에만 확인한다.

```bash
docker exec <STOCK_MYSQL_CONTAINER> sh -c \
  'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
    --batch --skip-column-names --execute="$1"' sh \
  "SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE
     FROM information_schema.TABLES
    WHERE TABLE_SCHEMA NOT IN
          ('information_schema','mysql','performance_schema','sys')
      AND ENGINE IS NOT NULL
      AND ENGINE <> 'InnoDB'
    ORDER BY TABLE_SCHEMA, TABLE_NAME"
```

출력이 있으면 application writer를 먼저 멈추고 최종 논리 백업을 다시 만드는 편이
안전하다. filesystem 권위 사본은 모든 DB가 정상 종료된 뒤 수행한 cold copy다.

## 6. 선택적인 전체 checksum 검증

다음 조건일 때만 고려한다.

- 원본 HDD SMART가 정상이다.
- 추가로 몇 시간 동안 원본과 대상을 전부 읽어도 된다.
- metadata 비교보다 강한 bit 단위 검증이 필요하다.

Docker와 모든 writer가 계속 정지된 상태에서 실행한다.

```bash
CHECKSUM_REPORT="$HOME/rsync-checksum-dry-run-$(date +%Y%m%d-%H%M%S).txt"

if sudo rsync -aHAXSxnc --numeric-ids --delete --itemize-changes \
  --exclude=/lost+found \
  --exclude=/.migration-backup/ \
  /data/ /mnt/data-ssd-stage/ > "$CHECKSUM_REPORT"; then
  if test -s "$CHECKSUM_REPORT"; then
    cat "$CHECKSUM_REPORT"
    echo 'Stop: checksum differences were found'
    false
  else
    echo 'Checksum dry-run completed with no differences'
  fi
else
  echo 'Stop: checksum dry-run failed'
  false
fi
```

보고서가 비어 있어야 한다. 차이가 있으면 mount를 전환하지 말고 writer와 이전
`rsync` 결과를 확인한다.

HDD에 pending/uncorrectable sector나 반복 I/O 오류가 있다면 전체 checksum으로 디스크를
반복해서 읽지 않는다. 그 경우 일반 마이그레이션이 아니라 복구 우선 계획이 필요하다.

## 7. 선택적인 Docker mount 보호

`/data` mount가 실패했을 때 Docker가 OS filesystem의 빈 `/data/docker`를 사용하지
못하게 하는 영구 hardening이다. fstab이 fail-closed로 정상 등록된 현재 이전의 필수
단계는 아니지만, 적용하려면 한 번만 설정한다.

기존 unit과 drop-in을 먼저 확인하고 백업한다.

```bash
systemctl cat docker.service

if sudo test -d /etc/systemd/system/docker.service.d; then
  sudo cp -a /etc/systemd/system/docker.service.d \
    "/etc/systemd/system/docker.service.d.pre-data-nvme-$(date +%Y%m%d-%H%M%S)"
fi

sudo systemctl edit docker.service
```

다음을 입력한다.

```ini
[Unit]
RequiresMountsFor=/data
ConditionPathIsMountPoint=/data
ConditionPathIsReadWrite=/data
```

설정을 반영하고 확인한다.

```bash
sudo systemctl daemon-reload
sudo systemd-analyze verify docker.service
systemctl show docker.service \
  -p DropInPaths -p RequiresMountsFor -p Conditions
```

condition이 실패하면 Docker는 failed가 아니라 skipped/inactive로 보일 수 있다.
부팅 후에는 `systemctl is-active docker.service`와 `docker info`를 모두 확인한다.
같은 보호 설정을 이전 과정에서 반복 적용할 필요는 없다.

## 8. 롤백

### 8.1 먼저 결정할 사항

신규 NVMe 전환 후 새 DB row, Mattermost 메시지나 첨부파일이 생성됐다면 기존 HDD는
오래된 사본이다. 단순 UUID 롤백은 전환 이후 데이터를 유실한다.

다음 중 하나가 준비됐을 때만 기존 HDD로 되돌린다.

- 전환 이후 신규 쓰기가 전혀 없다.
- 신규 NVMe의 최신 DB 논리 백업을 기존 HDD 환경에 복원한다.
- 모든 서비스를 멈추고 신규 NVMe에서 HDD로 역방향 최종 동기화한다.

역방향 `rsync --delete`는 대상 HDD의 내용을 변경하므로 source와 destination을
별도로 재검토하지 않고 실행하지 않는다.

### 8.2 쓰기가 없을 때의 기본 롤백 순서

1. Stock batch, Stock back, Mattermost app 등 writer를 정상 정지한다.
2. 모든 container를 정상 정지하고 `docker ps`가 비었는지 확인한다.
3. `docker.service`, `docker.socket`과 `containerd.service`를 정지한다.
4. `findmnt -R /data`와 `fuser -vm /data`로 writer가 없음을 확인한다.
5. 신규 NVMe `/data`를 unmount한다.
6. `/etc/fstab`의 `/data` UUID만 기존 HDD UUID로 복원한다.
7. `sudo findmnt --verify --verbose`와 `sudo systemctl daemon-reload`를 실행한다.
8. `sudo mount /data` 후 SOURCE가 기존 HDD인지 확인한다.
9. Docker를 시작하고 DB/cache, application, Stock batch 순으로 시작한다.
10. 실행용 런북의 DB, Stock, Mattermost 검증을 반복한다.

fstab 백업을 파일 전체로 무조건 덮어쓰지 않는다. 이전 후 다른 mount 설정이
추가됐다면 `/data` 행만 비교해서 복원한다.

## 9. 상황별 판단표

| 상황 | 판단 |
|---|---|
| 신규 NVMe가 보이지 않음 | 전원을 끄고 장착, standoff와 BIOS 인식 확인 |
| 기존 HDD가 보이지 않음 | M2M과 `SATA3_4/5` 공유 여부 및 케이블/전원 확인 |
| 기존 OS NVMe가 보이지 않음 | 작업 중단, 부팅 디스크와 M.2 장착 상태 확인 |
| HDD SMART 불량 | 일반 `rsync` 반복 금지, 복구 우선 계획 |
| `mkfs` 대상이 불명확함 | 즉시 중단, 모델과 serial 재확인 |
| DB dump 실패 | 인증과 DB 상태 해결 후 성공한 dump 생성 |
| `docker ps`에 실행 중 container가 남음 | 최종 복사 금지 |
| Docker unit/process가 active | 최종 복사 금지 |
| `/data` 아래 child mount가 남음 | mount 역할 확인 전 최종 복사 금지 |
| 최종 `rsync` 실패 | 원인 해결 후 같은 정지 상태 복사 재실행 |
| metadata dry-run 차이 | writer 확인 후 최종 `rsync` 재실행 |
| fstab 검증 실패 | 기존 `/data` unmount 금지 |
| 신규 `/data` mount 실패 | Docker 시작 금지, 기존 UUID로 mount 복구 |
| 기존 Docker container/volume이 안 보임 | application 시작 금지, mount와 data root 확인 |
| DB corruption 또는 version 오류 | application 시작 금지, 기존 HDD 보존 |

## 참고자료

- [Docker daemon data directory](https://docs.docker.com/engine/daemon/)
- [Docker OverlayFS storage driver](https://docs.docker.com/engine/storage/drivers/overlayfs-driver/)
- [Docker Compose stop/start behavior](https://docs.docker.com/compose/support-and-feedback/faq/)
- [Ubuntu 22.04 systemd.unit manual](https://manpages.ubuntu.com/manpages/jammy/man5/systemd.unit.5.html)
- [Ubuntu 22.04 rsync manual](https://manpages.ubuntu.com/manpages/jammy/man1/rsync.1.html)
- [MySQL mysqldump](https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html)
- [PostgreSQL pg_dumpall](https://www.postgresql.org/docs/current/app-pg-dumpall.html)
