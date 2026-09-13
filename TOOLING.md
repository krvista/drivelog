# drivelog 업로드 도구

comma 디바이스의 `rlog.zst` 를 이 리포지토리의 데이터 브랜치로 직접 올린다.

- `ccnc-drivelog` : CCNC 차량
- `wk2-drivelog`  : WK2 차량

업로드 PC 가 집과 회사를 오가도 로컬에 아무것도 쌓이지 않도록 설계했다.

다른 PC 나 새 세션에서 이어받는 경우 `HANDOFF.md` 를 먼저 읽을 것.
현재 상태와 아직 안 끝난 과제가 거기 있다.

## 왜 로컬 동기화가 필요 없는가

일반적인 방법은 리포지토리를 클론해 두고 파일을 넣고 커밋하는 것이다.
그러면 PC 마다 수 GB 짜리 사본이 생기고, 두 PC 사이에 pull 을 안 하면
상태가 어긋난다. 이 도구는 그 구조 자체를 없앤다.

핵심은 네 가지다.

1. **작업용 클론은 일회용이다.** 실행할 때마다 임시 디렉터리에 만들고 끝나면 지운다.
   PC 에 리포지토리 사본이 남지 않으므로 "이 PC 는 최신인가" 라는 질문 자체가 없어진다.

2. **기존 데이터의 blob 은 받지 않는다.** `--filter=blob:limit=64k --depth 1` 로
   커밋 하나와 트리, 그리고 64KB 미만의 작은 파일만 받는다. 브랜치에 5 GB 가 쌓여 있어도
   작업 클론은 수백 KB 다.

3. **워킹트리도 인덱스도 만들지 않는다.** `git add` / `git write-tree` 대신
   `git mktree --missing` 으로 트리를 직접 쓰고 `git commit-tree` 로 커밋을 만든다.
   (이유는 아래 "함정" 참고.)

4. **상태는 원격에만 있다.** "무엇이 이미 올라갔는가" 는 원격 브랜치의 파일 목록과
   `pruned.txt` 로 결정된다. 로컬 상태 파일이 없으므로 집 PC 와 회사 PC 의 상태가
   어긋날 수 없다. 어느 PC 에서 실행해도 같은 답이 나오고, 중간에 끊겨도
   다시 실행하면 남은 것부터 이어서 올린다.

## 준비

Git Bash 나 WSL 어느 쪽에서든 실행된다. Python 은 필요 없다.

1. `drivelog.conf` 에서 이 PC 가 실제로 닿는 디바이스 주소를 채운다.
2. GitHub 자격증명이 통하는지 확인한다 (`git ls-remote <REMOTE_URL>`).
   HTTPS 와 SSH 중 어느 쪽을 쓸지는 PC 마다 다르다. 아래 절 참고.
3. 디바이스는 openpilot 설정에서 SSH 를 켜고 GitHub 사용자명을 등록해 둔다.

### WSL 에서 실행하는 경우

Windows Git Bash 는 자격 증명 관리자를 자동으로 쓰지만 **WSL 은 그렇지 않다.**
그대로 실행하면 `could not read Username for 'https://github.com'` 로 막힌다.
아래를 한 번만 실행하면 Windows 쪽에 이미 저장된 자격증명을 그대로 재사용한다.
새로 로그인하거나 토큰을 따로 만들 필요는 없다.

```bash
git config --global credential.helper \
    "/mnt/c/Program\ Files/Git/mingw64/bin/git-credential-manager.exe"

git config --global user.name  "krvista"
git config --global user.email "krvista@gmail.com"
```

경로의 `Program\ Files` 는 공백 앞의 역슬래시까지 그대로 넣어야 한다.
WSL 은 별도의 `~/.gitconfig` 를 쓰므로 커밋 신원도 따로 설정해야 한다.

### HTTPS 와 SSH — PC 마다 다르다

`REMOTE_URL` 은 `drivelog.conf` 에서 정하므로 PC 별로 다르게 둘 수 있다.

- **회사 PC**: HTTPS + Windows 자격 증명 관리자.
  `REMOTE_URL="https://github.com/krvista/drivelog.git"`
- **집 PC**: SSH. 공개키가 GitHub 계정에 등록돼 있어 자격증명 설정이 필요 없다.
  `REMOTE_URL="git@github.com:krvista/drivelog.git"`

어느 쪽이든 아래가 물어보지 않고 통과하면 준비된 것이다.

```bash
git ls-remote <REMOTE_URL>
```

집 PC 는 추가로 `~/.ssh/config` 에서 github.com 을 `ssh.github.com:443` 으로 보낸다.
포트 22 로 대용량 push 가 반복해서 끊겨 우회한 것이며, SSH URL 을 쓰면 자동 적용된다.

### 디바이스 SSH 키

comma 기기는 **GitHub 계정에 등록된 공개키**를 받아와 SSH 인증에 쓴다.
따라서 업로드 PC 의 키가 GitHub 계정에 등록돼 있어야 기기에 접속할 수 있다.

```bash
ssh-keygen -lf ~/.ssh/id_ed25519.pub          # 이 PC 의 키
curl -s https://github.com/krvista.keys | ssh-keygen -lf -   # GitHub 에 등록된 키
```

이 PC 의 지문이 목록에 없으면 공개키를 GitHub 계정 SSH keys 에 추가하고,
openpilot 설정에서 GitHub 사용자명을 **다시 입력**해 기기 쪽 키 목록을 갱신한다.
기기는 username 을 입력한 그 시점에 한 번만 키를 받아오므로, 나중에 추가한 키는
갱신하지 않으면 기기가 모른다.

갱신하면 계정에 등록된 키가 전부 함께 들어오므로 다른 PC 의 키가 밀려나지 않는다.
**현재 계정에는 집 PC 와 회사 PC 의 키가 각각 등록돼 있고 둘 다 사용 중이다.
어느 쪽도 지우면 안 된다** (`HANDOFF.md` 참고).

`status` 는 "기기에 안 닿는다" 와 "닿지만 키가 거부됐다" 를 구분해서 알려준다.
대응이 완전히 다르기 때문이다.

### 차를 잘못 지정하는 사고 막기

차가 두 대인데 스크립트는 하나이므로, 프로필을 잘못 주면 CCNC 데이터가
wk2 브랜치로 들어갈 수 있다. `drivelog.conf` 의 `PROFILE_DONGLE` 을 채워 두면
기기의 실제 dongle 과 대조해서 다를 경우 업로드를 거부한다.

회사 네트워크의 `192.168.1.31` 은 **C4-CE1N 기기**이고 `ccnc` 프로필에 해당한다.
집 네트워크에서는 IP 가 다르므로 `drivelog.conf` 를 고치거나 `--host` 를 쓴다.
`ccnc` 의 `PROFILE_DONGLE` 은 `5494f8f29b7fd585` 로 채워져 있다
(브랜치에 이미 올라간 파일들의 dongle 이며 같은 기기에서 온 것이다).

`wk2` 는 아직 기기에 접속한 적이 없어 주소와 dongle 이 모두 비어 있다.
처음 접속에 성공하면 `status` 가 실제 dongle 을 알려주므로 그 값을 넣어두면 된다.

## 사용법

```bash
# 지금 무엇이 올라가 있고 기기에 무엇이 남았는지
./drivelog.sh status --profile ccnc

# 목록을 보고 번호로 골라 올린다 (대화형, 가장 자주 쓰는 방식)
./drivelog.sh pick --profile ccnc

# 아직 안 올라간 것을 route 별로 묶어서 보여준다 (개수와 용량 포함)
./drivelog.sh list --profile ccnc

# 기기에서 받아 바로 업로드 (아직 안 올라간 것만)
./drivelog.sh upload --profile ccnc

# route 를 골라서 업로드. 이름 일부만 줘도 되고 쉼표로 여러 개도 된다
./drivelog.sh upload --profile ccnc --route 00000005
./drivelog.sh upload --profile ccnc --route 00000005,00000006

# 우선 몇 개만 시험
./drivelog.sh upload --profile ccnc --limit 3

# 무엇을 올릴지 목록만 확인
./drivelog.sh upload --profile ccnc --dry-run

# 이미 PC 에 받아둔 폴더에서 업로드
./drivelog.sh upload --profile wk2 --from-dir /d/rlog_backup

# 설정을 고치지 않고 기기 주소만 바꿔서 실행
./drivelog.sh status --profile wk2 --host 192.168.1.31

# 스크립트 같은 일반 파일을 브랜치 루트에 올림
./drivelog.sh put --profile ccnc drivelog.sh TOOLING.md
```

집에서든 회사에서든 같은 명령을 그대로 쓴다. 프로필만 맞추면 된다.

### pick — 대화형 선택 (권장)

평소에는 이것만 쓰면 된다. 기기의 route 를 업로드 상태와 함께 보여주고 번호로 고르게 한다.

```
  #   route                      미업로드 받을크기  상태
  --- -------------------------- -------- ----------  --------------------
  1   00000008--a1cb8f84fb            3/3    38.4 MB  전체 미업로드
  2   00000007--6d269e0a5d            1/4    12.8 MB  일부 업로드 (3/4)
  3   00000006--f11a24e738              -          -  업로드 완료

올릴 route 번호 (예: 1,3-5 / all / q):
```

`1,3-5` 처럼 쉼표와 범위를 섞어 쓸 수 있고 공백 구분도 된다. `all` 은 미업로드분 전부,
`q` 는 취소다. 이미 전부 올라간 route 를 고르면 건너뛰고 그 사실을 알려준다.
범위 밖 번호나 문자가 섞여 있으면 무시하고 무엇을 무시했는지 표시한다.

고른 것을 `--route` 로 넘겨 `upload` 를 그대로 호출하므로 동작은 아래 `upload` 와 같다.
`./drivelog.sh i` 로 줄여 쓸 수 있다.

목록은 route 번호가 큰 것부터 보여준다. 다만 재빌드로 카운터가 되감기면
이 순서가 시간순과 다를 수 있다 (아래 "업로드 순서 원장" 참고).

### list / upload — 비대화형

`list` 는 무엇을 올릴지 고르는 용도다. 기기의 세그먼트 중 아직 브랜치에 없는 것만
route 단위로 묶어 개수와 총 용량을 보여준다. 거기서 route 이름을 골라 `--route` 로 넘긴다.
크게 한 번에 올리기 부담스러우면 `--limit N` 으로 앞에서부터 N 개만 올릴 수도 있다.
어느 쪽이든 중간에 끊겨도 이미 push 된 배치는 남고 다시 실행하면 이어서 간다.

## 두 PC 가 동시에 올릴 때

서로 다른 파일을 올리므로 충돌은 항상 병합 가능하다. push 가 거부되면
원격 tip 을 다시 읽고 그 위에 다시 쌓아 재시도한다 (최대 10회, 백오프 포함).
실제 경합 테스트에서 한쪽이 4회 재시도 후 양쪽 모두 성공했고, 기존 데이터는 그대로였다.

한 번 push 는 한 커밋이고 기본 12개 파일 단위다 (`BATCH_FILES`). 중간에 끊겨도
이미 push 된 배치는 원격에 남고, 다시 실행하면 그 다음부터 이어간다.

회선에 따라 이 값을 낮춰야 할 수 있다. 집 PC 는 GitHub 으로 대용량 push 가
20~40초 지점에서 반복해서 끊겨 `BATCH_FILES=4` (약 45 MB) 로 낮췄다.
회선 자체는 정상이고(다른 서버로는 200 MB 가 18초에 완주) 저장소 크기와도 무관하다
(빈 저장소로도 10 MB 부터 실패). GitHub 쪽 제한으로 보인다.

## 용량 정리

```bash
./drivelog.sh prune --profile ccnc --keep 5        # 계획만 출력
./drivelog.sh prune --profile ccnc --keep 5 --yes  # 실제로 덜어냄
```

가장 최근에 **업로드한** route 몇 개만 남기고 나머지를 브랜치에서 덜어낸다.
route 이름이 아니라 `order.txt` 의 업로드 순서로 판단한다 (아래 절 참고).
덜어낸 파일 이름은 브랜치 루트의 `pruned.txt` 에 누적되고, 이후 `upload` 는
기기에 원본이 남아 있어도 그 파일들을 다시 올리지 않는다.

기본은 계획만 출력한다. 삭제 대상과 유지 대상을 모두 보여주므로 확인한 뒤
`--yes` 를 붙이면 된다.

**주의: 이것으로 GitHub 이 실제로 쓰는 저장 용량은 줄지 않는다.** 파일은 브랜치 tip 에서
빠질 뿐 히스토리에는 남는다. 클론하는 쪽의 체크아웃 용량만 줄어든다.
저장 용량을 되찾으려면 히스토리를 다시 써야 하는데, 그러려면 기존 blob 을 전부
로컬에 가지고 있어야 한다. blob 없는 클론에서는 불가능하다. 그 작업은
대역폭이 넉넉한 클라우드 쪽에서 브랜치를 통째로 받아 하는 편이 맞다.

`ccnc-drivelog` 는 개당 약 11 MB 인 파일이 수백 개로 5 GB 를 넘겼다.
GitHub 이 권장하는 리포지토리 한도를 이미 넘겼으므로 정리 계획이 필요하다.
정확한 현재 수치는 `status` 로 확인할 것 (문서 숫자는 낡는다).

## 업로드 순서 원장 (prune 의 정렬 기준)

`prune` 이 "무엇이 오래된 것인가" 를 판단하는 근거다.
2026-09-07 밤에 설계를 바꿨다. 그전에는 route 이름 문자열 순으로 판단했다.

### 왜 이름도 시각도 못 쓰는가

- **route 이름**: 기기를 다시 빌드하면 카운터가 `00000000` 부터 다시 시작한다.
  2026-09-06 밤 실제로 발생했다. 브랜치에는 `00000061` 까지 있는데 새 데이터가
  `00000005` 였다. 이름순으로 정리하면 가장 최신 주행이 먼저 지워진다.
- **기기 시각**: 주차장에서만 움직이면 GPS 를 못 잡아 기기 시각이 어긋난다.
  실제로 `11-26` 같은 엉뚱한 날짜가 찍힌 route 가 있었다.
- **둘을 조합하는 휴리스틱도 안 된다.** "이름이 되감겼으면 날짜를 믿고, 날짜가
  이상하면 이름을 믿는다" 는 규칙은 두 가지가 동시에 깨지면 무너진다.
  재빌드 직후 지하주차장 주행이 정확히 그 경우이고, 실제로 그 상황이었다.
  추정으로 날짜를 보정해 저장하는 것도 위험하다. 추정값이 원본처럼 남아
  나중에 되돌릴 근거가 사라진다.

### 그래서 업로드 순서를 쓴다

기기 이름도 기기 시각도 보지 않는다. **우리가 언제 올렸는지**만 본다.
출퇴근길에 모아서 올리므로 업로드 순서가 곧 시간 순서이고, 재빌드에도
시계 오차에도 흔들리지 않는다.

- 브랜치 루트의 `order.txt` 에 route 를 업로드된 순서대로 기록한다.
- `upload` 이 데이터 파일과 **같은 커밋**에 원장을 갱신한다. 중간에 끊겨도
  "올라갔는데 원장에 없는" 상태가 생기지 않는다.
- 두 PC 가 동시에 올려도 먼저 push 한 쪽의 순서가 보존되고 뒤에 덧붙는다.
  push 재시도 때마다 새 tip 의 `order.txt` 를 다시 읽어 합치기 때문이다.
- 원장에 없는 route 는 가장 오래된 것으로 취급한다 (구 도구로 올린 것).

원격에만 있으므로 집/회사 어느 PC 에서 실행해도 같은 답이 나온다.

### 기존 데이터의 순서 복원 (1회)

구 도구로 올린 파일들은 원장에 없다. 그 순서는 추정하지 않는다.
git 히스토리에 각 파일이 어느 커밋에서 처음 추가됐는지 남아 있고
그것이 곧 업로드 시점이다. `init-order` 가 그것을 복원한다.

```bash
./drivelog.sh init-order --profile ccnc --dry-run   # 복원될 순서 확인
./drivelog.sh init-order --profile ccnc             # 실제 생성
```

이때만 히스토리 전체가 필요하다. `--filter=blob:none` 이므로 데이터 blob 은
받지 않는다 (커밋과 트리만, 수 MB 수준).

`order.txt` 가 없으면 `prune` 은 이름순으로 되돌아가며 실행 시 경고를 띄운다.
**정리하기 전에 `init-order` 를 먼저 돌릴 것.**

## 함정 세 가지 (직접 부딪혀 확인한 것)

**`git ls-tree -l` 을 쓰면 안 된다.** 파일 크기를 알려고 부분 클론이 promisor 원격에서
blob 을 통째로 지연 fetch 한다. 조사 중에 이것 때문에 600 MB 를 받았다.
스크립트는 `GIT_NO_LAZY_FETCH=1` 을 켜서 이런 사고가 조용히 일어나는 대신
바로 실패하도록 해 둔다.

**`git write-tree` 를 쓰면 안 된다.** 인덱스의 모든 blob 이 실제로 있는지 검증하는데,
부분 클론에는 기존 파일 blob 이 없으므로 전부 받으려 든다. 그래서 인덱스를 아예 쓰지 않고
`git mktree --missing` 으로 트리를 직접 만든다.

**push 는 `--no-thin` 으로 한다.** thin pack 은 원격에 있는 기존 blob 을 델타 기준으로
쓰려고 해서 역시 다운로드를 유발한다.

곁가지로, `commit-tree` 가 빈 문자열을 돌려준 상태로 push 하면 `:refs/heads/브랜치` 형태가 되어
**원격 브랜치가 삭제된다.** 테스트 중 실제로 겪었다. 지금은 빈 SHA 를 만나면 즉시 중단한다.

## 리포지토리의 `.gitignore` 와의 관계

루트 `.gitignore` 는 `*.zst` 를 무시한다. 이 도구는 인덱스를 거치지 않고 트리를 직접
만들기 때문에 `.gitignore` 의 영향을 받지 않는다. 예전 스크립트처럼 `git add -f` 를
쓸 필요가 없다.
