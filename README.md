# drivelog

comma 디바이스 드라이브로그 보관용 저장소. 데이터는 차량별 브랜치에 담는다.

- `ccnc-drivelog` — CCNC 차량 (C4-CE1N 기기)
- `wk2-drivelog` — WK2 차량

## 담기는 것

- 파일 형식: `{dongle}_{route}--{seg}--rlog.zst`, `drivelog/` 아래 평평하게 둔다
- qlog 는 rlog 의 축약본이라 저장하지 않는다
- 보관 정책: 최근에 올린 route 일부만 유지 (용량 한도 관리)

브랜치 루트에는 원장 두 개가 함께 있다. 둘 다 원격에만 두는 상태 저장소다.

- `order.txt` — route 를 올린 순서. `prune` 이 "무엇이 오래된 것인가" 를 판단하는 기준
- `pruned.txt` — 덜어낸 파일 목록. 기기에 원본이 남아 있어도 다시 올리지 않기 위한 것

## 도구

업로드 도구는 `drivelog.sh` 하나다. Git Bash 나 WSL 에서 돌아가며 Python 은 필요 없다.

```bash
bash drivelog.sh status --profile ccnc   # 원격/기기 현황
bash drivelog.sh list   --profile ccnc   # 아직 안 올라간 것 (route 별)
bash drivelog.sh pick   --profile ccnc   # 목록에서 번호로 골라 올린다
bash drivelog.sh upload --profile ccnc   # 안 올라간 것 전부 올린다
bash drivelog.sh --help                  # 전체 서브커맨드
```

이 도구는 저장소를 로컬에 클론해 두지 않는다. 실행할 때마다 메타데이터만 받는
작업용 클론을 만들고 끝나면 지운다. 브랜치에 수 GB 가 있어도 로컬에는 수백 KB 만
오간다. 업로드 PC 가 집과 회사를 오가도 동기화할 것이 없다.

설정은 `drivelog.conf.example` 을 `drivelog.conf` 로 복사해 채운다.
PC 마다 다르므로 저장소에는 올리지 않는다.

## 문서

- `TOOLING.md` — 사용법, 설계 근거, 구현상의 함정
- `HANDOFF.md` — 현재 상태와 남은 과제. 다른 PC 나 새 세션에서 이어받을 때 먼저 읽는다
