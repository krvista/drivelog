# drivelog 업로드 도구

comma 디바이스의 `rlog.zst` 를 이 리포지토리의 데이터 브랜치로 직접 올린다.

- `ccnc-drivelog` : CCNC 차량
- `wk2-drivelog`  : WK2 차량

업로드 PC 가 집과 회사를 오가도 로컬에 아무것도 쌓이지 않도록 설계했다.

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
2. GitHub 자격증명이 통하는지 확인한다.
   `git ls-remote https://github.com/krvista/drivelog.git` 이 물어보지 않고 통과하면 준비 완료.
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

참고로 `git@github.com` SSH 경로는 이 계정에 공개키가 등록돼 있지 않아 지금은 쓸 수 없다
(`Permission denied (publickey)`). HTTPS + 자격 증명 관리자 조합을 쓴다.

### 디바이스 SSH 키

comma 기기는 **GitHub 계정에 등록된 공개키**를 받아와 SSH 인증에 쓴다.
따라서 업로드 PC 의 키가 GitHub 계정에 등록돼 있어야 기기에 접속할 수 있다.

```bash
ssh-keygen -lf ~/.ssh/id_ed25519.pub          # 이 PC 의 키
curl -s https://github.com/krvista.keys | ssh-keygen -lf -   # GitHub 에 등록된 키
```

두 지문이 다르면 이 PC 의 공개키를 GitHub 계정 SSH keys 에 추가하고,
openpilot 설정에서 GitHub 사용자명을 다시 입력해 기기 쪽 키 목록을 갱신한다.

2026-09-07 기준 이 PC 는 지문이 어긋나 있다. 기기(`192.168.1.31`)는 응답하지만
`Permission denied (publickey)` 로 막힌다. `status` 가 이 상황을 구분해서 알려준다.

### 차를 잘못 지정하는 사고 막기

차가 두 대인데 스크립트는 하나이므로, 프로필을 잘못 주면 CCNC 데이터가
wk2 브랜치로 들어갈 수 있다. `drivelog.conf` 의 `PROFILE_DONGLE` 을 채워 두면
기기의 실제 dongle 과 대조해서 다를 경우 업로드를 거부한다.

`192.168.1.31` 은 **C4-CE1N 기기**이고 `ccnc` 프로필에 해당한다.
`ccnc` 의 `PROFILE_DONGLE` 은 `5494f8f29b7fd585` 로 채워져 있다
(브랜치에 이미 올라간 525개 파일의 dongle 이며 같은 기기에서 온 것이다).

`wk2` 는 아직 기기에 접속한 적이 없어 주소와 dongle 이 모두 비어 있다.
처음 접속에 성공하면 `status` 가 실제 dongle 을 알려주므로 그 값을 넣어두면 된다.

## 사용법

```bash
# 지금 무엇이 올라가 있고 기기에 무엇이 남았는지
./drivelog.sh status --profile ccnc

# 기기에서 받아 바로 업로드 (아직 안 올라간 것만)
./drivelog.sh upload --profile ccnc

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

## 두 PC 가 동시에 올릴 때

서로 다른 파일을 올리므로 충돌은 항상 병합 가능하다. push 가 거부되면
원격 tip 을 다시 읽고 그 위에 다시 쌓아 재시도한다 (최대 10회, 백오프 포함).
실제 경합 테스트에서 한쪽이 4회 재시도 후 양쪽 모두 성공했고, 기존 데이터는 그대로였다.

한 번 push 는 한 커밋이고 기본 12개 파일 단위다. 중간에 끊겨도 이미 push 된
배치는 원격에 남고, 다시 실행하면 그 다음부터 이어간다.

## 용량 정리

```bash
./drivelog.sh prune --profile ccnc --keep 5        # 계획만 출력
./drivelog.sh prune --profile ccnc --keep 5 --yes  # 실제로 덜어냄
```

최신 route 몇 개만 남기고 나머지를 브랜치에서 덜어낸다. 덜어낸 파일 이름은
브랜치 루트의 `pruned.txt` 에 누적되고, 이후 `upload` 는 기기에 원본이 남아 있어도
그 파일들을 다시 올리지 않는다.

**주의: 이것으로 GitHub 이 실제로 쓰는 저장 용량은 줄지 않는다.** 파일은 브랜치 tip 에서
빠질 뿐 히스토리에는 남는다. 클론하는 쪽의 체크아웃 용량만 줄어든다.
저장 용량을 되찾으려면 히스토리를 다시 써야 하는데, 그러려면 기존 blob 을 전부
로컬에 가지고 있어야 한다. blob 없는 클론에서는 불가능하다. 그 작업은
대역폭이 넉넉한 클라우드 쪽에서 브랜치를 통째로 받아 하는 편이 맞다.

현재 `ccnc-drivelog` 는 파일 525개, 개당 약 11 MB 로 약 5.7 GB 다.
GitHub 이 권장하는 리포지토리 한도(5 GB)를 이미 넘겼으므로 정리 계획이 필요하다.

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
