#!/usr/bin/env bash
# drivelog.sh - comma 디바이스의 rlog.zst 를 GitHub 브랜치로 직접 업로드한다.
#
# 설계 목표: 업로드 PC(집/회사)가 바뀌어도 로컬 동기화가 0 에 수렴할 것.
#   - 로컬에 리포지토리 사본을 남기지 않는다 (작업용 클론은 매번 만들고 지운다).
#   - 기존 데이터(수 GB)의 blob 은 절대 내려받지 않는다 (--filter=blob:limit=64k).
#     64KB 미만의 작은 파일(README, 삭제 이력)만 함께 받는다.
#   - 워킹트리를 만들지 않는다 (--no-checkout + git plumbing 으로 커밋 생성).
#   - "무엇이 이미 올라갔는가" 의 상태는 원격 트리 목록이 유일한 진실이다.
#     로컬 상태 파일이 없으므로 PC 간 상태 불일치가 원리적으로 발생하지 않는다.
#
# 사용법:
#   ./drivelog.sh status [--profile ccnc|wk2]
#   ./drivelog.sh list   [--profile ccnc|wk2]     # 미업로드분을 route 별로 보여준다
#   ./drivelog.sh pick   [--profile ccnc|wk2]     # 목록에서 번호로 골라 올린다 (대화형)
#   ./drivelog.sh upload [--profile ccnc|wk2] [--route R[,R2]] [--limit N] [--dry-run]
#   ./drivelog.sh upload --from-dir <디렉터리>    # 이미 받아둔 로컬 파일을 올린다
#   ./drivelog.sh put <파일>...                   # 임의 파일을 브랜치 루트에 올린다
#   ./drivelog.sh prune  [--keep N] [--yes]       # 오래된 route 를 브랜치에서 덜어낸다
#   ./drivelog.sh init-order [--dry-run] [--yes]  # 업로드 순서 원장을 히스토리에서 복원(1회)

set -euo pipefail

# 부분 클론에서 실수로 blob 을 통째 내려받는 사고를 막는다.
# (예: git ls-tree -l 은 크기를 알려고 blob 을 지연 fetch 한다.)
export GIT_NO_LAZY_FETCH=1
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/drivelog.conf"

# ---------- 기본값 ----------
REMOTE_URL="https://github.com/krvista/drivelog.git"
DEVICE_DATA_DIR="/data/media/0/realdata"
REPO_SUBDIR="drivelog"
BATCH_FILES=12
PUSH_RETRIES=10
PROFILE="ccnc"
FORCE_BRANCH=""
FORCE_HOST=""

# PROFILE_DONGLE 은 선택 사항이지만 채워 두는 편이 안전하다.
# 차가 두 대인데 스크립트가 하나이므로, 프로필을 잘못 지정하면
# CCNC 데이터가 wk2 브랜치로 들어가는 식의 사고가 난다.
# 값이 설정돼 있으면 기기의 실제 dongle 과 대조해 다르면 중단한다.
declare -A PROFILE_SSH PROFILE_BRANCH PROFILE_DONGLE
PROFILE_SSH[ccnc]="comma@192.168.1.135"
PROFILE_BRANCH[ccnc]="ccnc-drivelog"
PROFILE_SSH[wk2]=""
PROFILE_BRANCH[wk2]="wk2-drivelog"

if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi

# ---------- 로깅 ----------
log()  { printf '%s\n' "$*" >&2; }
step() { printf '\n== %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

human() {
  awk -v b="${1:-0}" 'BEGIN{ split("B KB MB GB TB", u, " "); i=1;
    while (b >= 1024 && i < 5) { b = b/1024; i++ } printf "%.1f %s", b, u[i] }'
}

# ---------- 인자 파싱 ----------
show_usage() { sed -n '12,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
case "${1:-}" in
  -h|--help|help) show_usage ;;
esac
CMD="${1:-status}"
shift || true
LIMIT=0
DRY_RUN=0
FROM_DIR=""
ROUTE_FILTER=""
KEEP_ROUTES=5
PRUNE_YES=0
PUT_PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)  PROFILE="$2"; shift 2 ;;
    --branch)   FORCE_BRANCH="$2"; shift 2 ;;
    --host)     FORCE_HOST="$2"; shift 2 ;;
    --limit)    LIMIT="$2"; shift 2 ;;
    --batch)    BATCH_FILES="$2"; shift 2 ;;
    --from-dir) FROM_DIR="$2"; shift 2 ;;
    --route)    ROUTE_FILTER="$2"; shift 2 ;;
    --keep)     KEEP_ROUTES="$2"; shift 2 ;;
    --yes)      PRUNE_YES=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  show_usage ;;
    -*)         die "알 수 없는 옵션: $1" ;;
    *)          PUT_PATHS+=("$1"); shift ;;
  esac
done

if [ -n "$FORCE_BRANCH" ]; then
  BRANCH="$FORCE_BRANCH"
else
  BRANCH="${PROFILE_BRANCH[$PROFILE]:-}"
fi
if [ -n "$FORCE_HOST" ]; then
  case "$FORCE_HOST" in
    *@*) SSH_TARGET="$FORCE_HOST" ;;
    *)   SSH_TARGET="comma@$FORCE_HOST" ;;
  esac
else
  SSH_TARGET="${PROFILE_SSH[$PROFILE]:-}"
fi
EXPECT_DONGLE="${PROFILE_DONGLE[$PROFILE]:-}"

# 기기의 dongle 이 이 프로필에 기대되는 값과 다르면 중단한다.
# 다른 차의 데이터를 엉뚱한 브랜치에 올리는 사고를 막기 위한 것이다.
check_dongle() {
  local got="$1"
  if [ -z "$EXPECT_DONGLE" ]; then
    log "  (프로필 '$PROFILE' 에 기대 dongle 이 설정돼 있지 않다."
    log "   drivelog.conf 에 PROFILE_DONGLE[$PROFILE]=\"$got\" 를 넣어두면"
    log "   다음부터 차를 잘못 지정하는 사고를 막을 수 있다.)"
    return 0
  fi
  if [ "$got" != "$EXPECT_DONGLE" ]; then
    log ""
    log "기기의 dongle 이 이 프로필과 맞지 않는다. 중단한다."
    log "  프로필 $PROFILE 기대값 : $EXPECT_DONGLE  -> $BRANCH"
    log "  실제 기기            : $got"
    log "다른 차의 기기이거나 프로필을 잘못 지정했을 수 있다."
    exit 1
  fi
}
[ -n "$BRANCH" ] || die "프로필 '$PROFILE' 에 대한 브랜치를 찾을 수 없다."

WORK=""
G=()
BASE=""

cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# GitHub 인증이 안 될 때 안내. WSL 에서 특히 자주 걸린다.
# Windows Git Bash 는 자격 증명 관리자를 자동으로 쓰지만 WSL 은 그렇지 않다.
auth_hint() {
  log "error: 클론 실패: $REMOTE_URL ($BRANCH)"
  log ""
  if grep -qi microsoft /proc/version 2>/dev/null; then
    log "WSL 에서는 Windows 자격 증명 관리자가 자동으로 연결되지 않는다."
    log "아래를 한 번 실행하면 Windows 쪽에 이미 저장된 자격증명을 그대로 쓴다:"
    log ""
    log '  git config --global credential.helper \\'
    log '      "/mnt/c/Program\\ Files/Git/mingw64/bin/git-credential-manager.exe"'
    log ""
    log "커밋 신원도 함께 설정해 둘 것:"
    log '  git config --global user.name  "krvista"'
    log '  git config --global user.email "krvista@gmail.com"'
  else
    log "다음이 물어보지 않고 통과하는지 확인할 것:"
    log "  git ls-remote $REMOTE_URL"
  fi
  exit 1
}

# ---------- 1. 메타데이터만 있는 일회용 클론 ----------
# 받아오는 것: 커밋 1개 + 트리 + 루트의 작은 파일들. 데이터 blob 은 0 바이트.
make_work_repo() {
  WORK="$(mktemp -d 2>/dev/null || mktemp -d -t drivelog)"
  git clone --quiet \
    --filter=blob:limit=64k --no-checkout --depth 1 \
    --single-branch --branch "$BRANCH" \
    "$REMOTE_URL" "$WORK/repo" \
    || auth_hint
  mkdir -p "$WORK/stage"
  G=(git -C "$WORK/repo")
}

# 원격 tip 을 다시 읽어온다 (다른 PC 가 그 사이 push 했을 수 있다).
refresh_tip() {
  "${G[@]}" fetch --quiet --depth 1 --filter=blob:limit=64k origin "$BRANCH"
  BASE="$("${G[@]}" rev-parse FETCH_HEAD)"
}

# 원격에 이미 올라간 파일 목록 = 유일한 상태 저장소.
# 주의: -l 을 붙이면 안 된다 (blob 을 지연 fetch 한다).
remote_files() {
  "${G[@]}" ls-tree -r --name-only "$BASE" -- "$REPO_SUBDIR" 2>/dev/null |
    sed "s#^${REPO_SUBDIR}/##" || true
}

count_lines() { grep -c . || true; }

# prune 으로 브랜치에서 덜어낸 파일 목록. 브랜치 루트의 pruned.txt 에 누적된다.
# 기기에 원본이 남아 있어도 이미 정리한 파일을 다시 올리지 않기 위한 것이다.
# 이것도 원격에만 있으므로 PC 를 옮겨도 그대로 따라온다.
PRUNED_FILE="pruned.txt"
pruned_list() {
  "${G[@]}" cat-file -p "$BASE:$PRUNED_FILE" 2>/dev/null || true
}

# ---------- 업로드 순서 원장 ----------
# prune 이 "무엇이 오래된 것인가" 를 판단하는 유일한 근거다.
#
# route 이름도 기기 시각도 믿을 수 없다:
#   - 기기를 다시 빌드하면 route 카운터가 00000000 부터 다시 시작한다.
#     (2026-09-06 실제 발생. 브랜치에 00000061 이 있는데 새 데이터가 00000005 다.)
#   - GPS 를 못 잡으면 기기 시각이 엉뚱해진다 (지하주차장 주행).
#   - 재빌드 직후 지하주차장 주행이면 둘 다 동시에 깨진다. 어떤 휴리스틱도 못 푼다.
#
# 반면 "우리가 언제 올렸는가" 는 우리가 안다. 출퇴근길에 모아서 올리므로
# 업로드 순서가 곧 시간 순서다. 재빌드에도 시계 오차에도 영향받지 않는다.
# 이 목록은 원격에만 있으므로 집/회사 PC 어디서 실행해도 같은 답이 나온다.
ORDER_FILE="order.txt"
order_list() {
  "${G[@]}" cat-file -p "$BASE:$ORDER_FILE" 2>/dev/null || true
}

# route 이름들을 stdin 으로 받아 "정렬키<TAB>route" 를 출력한다.
# 원장에 없는 route(구 도구로 올린 것)는 가장 오래된 것으로 취급한다.
route_sort_keys() {
  local rank_file="$1" r idx
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    idx="$(awk -v want="$r" '$2 == want { print $1; exit }' "$rank_file")"
    if [ -n "$idx" ]; then
      printf '1 %08d\t%s\n' "$idx" "$r"
    else
      printf '0 00000000\t%s\n' "$r"
    fi
  done
}

# 원장을 "순번 route" 형태로 펼친다 (route_sort_keys 조회용).
order_rank_file() {
  local out="$1"
  order_list | { grep . || true; } | nl -ba -w1 -s' ' > "$out"
}

# 원격 기준 "이미 처리된" 파일 이름 전체 (현재 보관 중 + 정리 완료)
# 주의: 빈 브랜치(아직 데이터가 없는 wk2 등)에서는 입력이 비어 grep 이 1 을 돌려준다.
# set -e 아래에서 그대로 두면 함수가 조용히 중단되므로 반드시 삼켜야 한다.
known_files() {
  { remote_files; pruned_list; } | { grep . || true; } | sort -u
}

# ---------- 2. 디바이스 인벤토리 ----------
# 실패 원인을 구분해서 알려준다. "안 닿는다" 와 "키가 거부됐다" 는
# 대응이 완전히 다른데 뭉뚱그리면 엉뚱한 곳을 뒤지게 된다.
#
# 주의: 명령 치환($(...)) 안에서 전역을 설정하면 서브셸이라 밖으로 전달되지 않는다.
# 그래서 결과를 반환하지 않고 DONGLE / DEVICE_ERR 전역에 직접 넣는다.
DEVICE_ERR=""
DONGLE=""
probe_device() {
  local out rc
  DEVICE_ERR=""
  DONGLE=""
  out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
        "$SSH_TARGET" 'cat /data/params/d/DongleId 2>/dev/null' 2>&1)" && rc=0 || rc=$?

  if [ "$rc" -eq 0 ]; then
    DONGLE="$(printf '%s' "$out" | tr -d '\r\n')"
    [ -n "$DONGLE" ] || { DEVICE_ERR="DongleId 를 읽지 못했다"; return 1; }
    return 0
  fi

  case "$out" in
    *"Permission denied (publickey)"*)
      DEVICE_ERR="키거부" ;;
    *"Connection refused"*)
      DEVICE_ERR="SSH 꺼짐" ;;
    *"Connection timed out"*|*"No route to host"*|*"Host is down"*)
      DEVICE_ERR="안닿음" ;;
    *)
      DEVICE_ERR="$(printf '%s' "$out" | tr -d '\r' | tail -1)" ;;
  esac
  return 1
}

# 위 실패 원인에 맞는 안내를 출력한다.
device_err_hint() {
  case "$DEVICE_ERR" in
    "키거부")
      log "디바이스      : $SSH_TARGET 응답하지만 공개키가 거부됐다"
      log ""
      log "  comma 기기는 GitHub 계정에 등록된 공개키로 SSH 를 인증한다."
      log "  이 PC 의 키가 GitHub 계정에 등록돼 있는지 확인할 것:"
      log ""
      log "    ssh-keygen -lf ~/.ssh/id_ed25519.pub"
      log "    curl -s https://github.com/krvista.keys | ssh-keygen -lf -"
      log ""
      log "  두 지문이 다르면 이 PC 의 공개키를 GitHub 계정에 추가한 뒤,"
      log "  openpilot 설정에서 GitHub 사용자명을 다시 입력해 키를 갱신해야 한다."
      ;;
    "SSH 꺼짐")
      log "디바이스      : $SSH_TARGET 응답하지만 SSH 가 꺼져 있다"
      log "  openpilot 설정에서 SSH 를 켤 것."
      ;;
    "안닿음")
      log "디바이스      : $SSH_TARGET 에 닿지 않는다 (지금은 다른 네트워크일 수 있다)"
      ;;
    *)
      log "디바이스      : $SSH_TARGET 접속 실패 - $DEVICE_ERR"
      ;;
  esac
}

# 세그먼트 디렉터리명을 리포지토리 파일명으로 바꾼다.
#   5494f8f29b7fd585|00000061--4fb2eee4c0--5
#   -> 5494f8f29b7fd585_00000061--4fb2eee4c0--5--rlog.zst
seg_to_name() {
  local seg="$1" dongle="$2"
  case "$seg" in
    *"|"*) printf '%s--rlog.zst' "${seg//|/_}" ;;
    *)     printf '%s_%s--rlog.zst' "$dongle" "$seg" ;;
  esac
}

device_segments() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" \
    "cd '$DEVICE_DATA_DIR' 2>/dev/null || exit 0; for d in */; do d=\${d%/}; if [ -f \"\$d/rlog.zst\" ]; then echo \"\$d\"; fi; done" \
    2>/dev/null | tr -d '\r'
}

# 세그먼트와 파일 크기를 한 번의 ssh 로 같이 가져온다. "<세그먼트> <바이트>" 형식.
device_segments_sized() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" \
    "cd '$DEVICE_DATA_DIR' 2>/dev/null || exit 0; for d in */; do d=\${d%/}; f=\"\$d/rlog.zst\"; if [ -f \"\$f\" ]; then echo \"\$d \$(stat -c %s \"\$f\" 2>/dev/null || echo 0)\"; fi; done" \
    2>/dev/null | tr -d '\r'
}

# 세그먼트 디렉터리명에서 route 부분만 떼어낸다.
#   5494f8f29b7fd585|00000061--4fb2eee4c0--5  ->  5494f8f29b7fd585|00000061--4fb2eee4c0
seg_route() { printf '%s' "${1%--*}"; }

# ---------- 3. plumbing 으로 커밋을 만들어 push ----------
# 인덱스도 워킹트리도 쓰지 않는다.
#
# 왜 git add / write-tree 를 쓰지 않는가:
#   git write-tree 는 인덱스의 모든 blob 이 실제로 있는지 검증한다. 부분 클론에서는
#   기존 파일 blob 이 없으므로 promisor 원격에서 통째로(수 GB) 지연 fetch 를 시도한다.
#   git mktree --missing 은 없는 객체를 참조하는 트리를 그대로 기록해 주므로
#   기존 데이터를 단 한 바이트도 내려받지 않는다.
# 같은 이유로 push 는 --no-thin 을 쓴다 (델타 기준용 기존 blob 을 요구하지 않도록).

# 스테이지 파일들을 blob 으로 기록하고 "<mode> blob <sha>\t<name>" 목록을 만든다.
stage_entries() {
  local list_file="$1" out="$2" name mode blob
  : > "$out"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    mode=100644
    case "$name" in *.sh) mode=100755 ;; esac
    blob="$("${G[@]}" hash-object -w --no-filters -- "$WORK/stage/$name")"
    [ -n "$blob" ] || die "blob 생성 실패: $name"
    printf '%s blob %s\t%s\n' "$mode" "$blob" "$name" >> "$out"
  done < "$list_file"
}

# 기존 트리 목록에서 새 이름과 겹치는 항목을 빼고, 새 항목을 더해 트리를 만든다.
merge_tree() {
  local existing="$1" additions="$2" merged="$WORK/merged.$$"
  local -A repl=()
  local line name
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    repl["${line#*$'\t'}"]=1
  done < "$additions"

  : > "$merged"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line#*$'\t'}"
    [ -n "${repl[$name]:-}" ] && continue
    printf '%s\n' "$line" >> "$merged"
  done < "$existing"
  cat "$additions" >> "$merged"

  "${G[@]}" mktree --missing < "$merged"
  rm -f "$merged"
}

#   $1 = 스테이지 디렉터리 안의 파일명 목록 파일
#   $2 = 커밋 메시지
#   $3 = 저장 경로 접두사 ("" 이면 브랜치 루트)
#   $4 = (선택) 이번 커밋에서 order.txt 에 덧붙일 route 이름 목록 파일
build_and_push() {
  local list_file="$1" msg="$2" prefix="$3" order_add="${4:-}"
  local attempt subtree root commit oblob

  stage_entries "$list_file" "$WORK/add.entries"

  # 두 PC 가 서로 다른 파일을 올리므로 충돌은 항상 병합 가능하다.
  # 진 쪽은 새 tip 위에 다시 쌓아 올리기만 하면 되므로 넉넉히 재시도한다.
  for ((attempt = 1; attempt <= PUSH_RETRIES; attempt++)); do
    # order.txt 는 재시도할 때마다 새 tip 기준으로 다시 만든다.
    # 그 사이 다른 PC 가 추가한 route 를 덮어쓰지 않기 위한 것이다.
    # 먼저 올린 쪽이 앞에 남으므로 결과 순서가 곧 실제 업로드 순서가 된다.
    if [ -n "$order_add" ]; then
      { order_list; cat "$order_add"; } | { grep . || true; } \
        | awk '!seen[$0]++' > "$WORK/order.new"
      oblob="$("${G[@]}" hash-object -w --no-filters -- "$WORK/order.new")"
      [ -n "$oblob" ] || die "order.txt 생성 실패"
    fi

    if [ -n "$prefix" ]; then
      "${G[@]}" ls-tree "$BASE:$prefix" > "$WORK/old.sub" 2>/dev/null || : > "$WORK/old.sub"
      subtree="$(merge_tree "$WORK/old.sub" "$WORK/add.entries")"
      [ -n "$subtree" ] || die "서브트리 생성 실패"
      printf '040000 tree %s\t%s\n' "$subtree" "$prefix" > "$WORK/add.root"
      if [ -n "$order_add" ]; then
        printf '100644 blob %s\t%s\n' "$oblob" "$ORDER_FILE" >> "$WORK/add.root"
      fi
      "${G[@]}" ls-tree "$BASE" > "$WORK/old.root"
      root="$(merge_tree "$WORK/old.root" "$WORK/add.root")"
    else
      "${G[@]}" ls-tree "$BASE" > "$WORK/old.root"
      root="$(merge_tree "$WORK/old.root" "$WORK/add.entries")"
    fi
    [ -n "$root" ] || die "루트 트리 생성 실패"

    commit="$("${G[@]}" commit-tree "$root" -p "$BASE" -m "$msg")"
    # 빈 SHA 로 push 하면 원격 브랜치가 삭제된다. 반드시 막는다.
    [ -n "$commit" ] || die "커밋 생성 실패 (빈 SHA)"

    if "${G[@]}" push --quiet --no-thin origin "$commit:refs/heads/$BRANCH" 2>"$WORK/push.err"; then
      BASE="$commit"
      return 0
    fi

    if grep -qiE 'non-fast-forward|fetch first|stale info|cannot lock ref|failed to lock' "$WORK/push.err"; then
      local wait_s=$(( (RANDOM % 3) + attempt ))
      [ "$wait_s" -gt 10 ] && wait_s=10
      log "  push 거부됨 (다른 PC 가 먼저 올린 듯). ${wait_s}초 후 tip 갱신 재시도 ${attempt}/${PUSH_RETRIES}"
      sleep "$wait_s"
      refresh_tip
      continue
    fi

    cat "$WORK/push.err" >&2
    return 1
  done

  log "  ${PUSH_RETRIES}회 재시도 후에도 push 실패"
  return 1
}

# ---------- 명령: status ----------
cmd_status() {
  step "프로필 $PROFILE  ->  브랜치 $BRANCH"
  make_work_repo
  refresh_tip

  local rf n_remote kf n_pruned
  rf="$(remote_files)"
  kf="$(known_files)"
  n_remote="$(printf '%s\n' "$rf" | count_lines)"
  n_pruned="$(pruned_list | count_lines)"

  log "원격 tip      : $(printf '%s' "$BASE" | cut -c1-8)  $("${G[@]}" log -1 --format=%s "$BASE")"
  log "원격 파일 수  : $n_remote"
  [ "$n_pruned" -gt 0 ] && log "정리 완료     : $n_pruned (pruned.txt, 다시 올리지 않는다)"
  if [ "$n_remote" -gt 0 ]; then
    # 이름 순일 뿐 시간 순이 아니다. 기기를 다시 빌드하면 route 카운터가
    # 0 부터 다시 시작하므로 "가장 오래됨/최근" 으로 읽으면 틀린다.
    log "이름순 처음   : $(printf '%s\n' "$rf" | sort | head -1)"
    log "이름순 끝     : $(printf '%s\n' "$rf" | sort | tail -1)"
  fi
  log "작업 클론 크기: $(du -sh "$WORK/repo" 2>/dev/null | cut -f1)  (데이터 blob 미포함)"

  if [ -z "$SSH_TARGET" ]; then
    log "디바이스      : 설정 없음 (drivelog.conf 에 PROFILE_SSH[$PROFILE] 지정)"
    return 0
  fi

  local dongle
  if ! probe_device; then
    device_err_hint
    return 0
  fi
  dongle="$DONGLE"
  log "디바이스      : $SSH_TARGET  dongle=$dongle"
  check_dongle "$dongle"

  local segs missing=0 s name n_seg
  segs="$(device_segments)"
  n_seg="$(printf '%s\n' "$segs" | count_lines)"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    name="$(seg_to_name "$s" "$dongle")"
    if ! printf '%s\n' "$kf" | grep -qxF "$name"; then
      missing=$((missing + 1))
    fi
  done <<< "$segs"
  log "디바이스 세그먼트: $n_seg"
  log "미업로드      : $missing"
}

# --route 로 넘어온 값 중 하나라도 route 이름에 들어 있으면 통과.
# 쉼표로 여러 개를 줄 수 있고, 전체 이름 대신 일부만 줘도 된다 (예: 00000061).
route_matches() {
  local route="$1" pat
  [ -n "$ROUTE_FILTER" ] || return 0
  local IFS=,
  for pat in $ROUTE_FILTER; do
    [ -n "$pat" ] || continue
    case "$route" in *"$pat"*) return 0 ;; esac
  done
  return 1
}

# ---------- 명령: list (아직 안 올라간 것을 route 별로 보여준다) ----------
cmd_list() {
  step "프로필 $PROFILE  ->  브랜치 $BRANCH"
  make_work_repo
  refresh_tip
  local kf; kf="$(known_files)"

  [ -n "$SSH_TARGET" ] || die "프로필 '$PROFILE' 에 SSH 대상이 없다."
  if ! probe_device; then device_err_hint; exit 1; fi
  log "디바이스 $SSH_TARGET  dongle=$DONGLE"
  log ""

  # 미업로드 세그먼트를 route 별로 모은다.
  local line seg sz name route
  : > "$WORK/missing"
  while read -r seg sz; do
    [ -n "$seg" ] || continue
    name="$(seg_to_name "$seg" "$DONGLE")"
    printf '%s\n' "$kf" | grep -qxF "$name" && continue
    printf '%s\t%s\t%s\n' "$(seg_route "$seg")" "$seg" "${sz:-0}" >> "$WORK/missing"
  done < <(device_segments_sized | sort)

  if [ ! -s "$WORK/missing" ]; then
    log "미업로드 세그먼트가 없다."
    return 0
  fi

  printf '  %-3s %-34s %5s %10s\n' "#" "route" "seg" "크기" >&2
  printf '  %-3s %-34s %5s %10s\n' "---" "----------------------------------" "-----" "----------" >&2

  local idx=0 tot_n=0 tot_b=0 first_route="" last_route=""
  while IFS= read -r route; do
    idx=$((idx + 1))
    [ -z "$first_route" ] && first_route="${route#*|}"
    last_route="${route#*|}"
    local n b
    n="$(awk -F'\t' -v r="$route" '$1==r' "$WORK/missing" | wc -l)"
    b="$(awk -F'\t' -v r="$route" '$1==r {s+=$3} END{print s+0}' "$WORK/missing")"
    tot_n=$((tot_n + n)); tot_b=$((tot_b + b))
    # route 이름에서 dongle 접두사는 빼고 보여준다 (모두 같아서 자리만 차지한다).
    printf '  %-3s %-34s %5s %10s\n' "$idx" "${route#*|}" "$n" "$(human "$b")" >&2
  done < <(cut -f1 "$WORK/missing" | sort -u)

  log ""
  log "합계: route $idx 개, 세그먼트 $tot_n 개, $(human "$tot_b")"
  log ""
  log "올릴 route 를 골라서 실행한다 (이름 일부만 줘도 된다, 쉼표로 여러 개):"
  log ""
  log "  ./drivelog.sh upload --profile $PROFILE --route ${first_route%%--*} --dry-run"
  log "  ./drivelog.sh upload --profile $PROFILE --route ${first_route%%--*}"
  if [ "$idx" -gt 1 ]; then
    log "  ./drivelog.sh upload --profile $PROFILE --route ${first_route%%--*},${last_route%%--*}"
  fi
  log ""
  log "일부만 시험하려면:  ./drivelog.sh upload --profile $PROFILE --limit 3"
  log "전부 올리려면:      ./drivelog.sh upload --profile $PROFILE"
}

# ---------- 명령: pick (대화형 선택 업로드) ----------
# 기기의 route 를 업로드 상태와 함께 보여주고 번호로 고르게 한다.
# 고른 것을 --route 로 넘겨 upload 를 그대로 호출하므로 동작은 upload 와 같다.

# "1,3-5 7" 같은 입력을 번호 목록으로 편다. 범위와 쉼표/공백을 섞어 쓸 수 있다.
parse_selection() {
  local input="$1" max="$2" tok a b i
  input="${input//,/ }"
  for tok in $input; do
    case "$tok" in
      *-*)
        a="${tok%%-*}"; b="${tok##*-}"
        case "$a$b" in *[!0-9]*) log "  무시: $tok"; continue ;; esac
        [ "$a" -le "$b" ] || { i="$a"; a="$b"; b="$i"; }
        for ((i = a; i <= b; i++)); do
          [ "$i" -ge 1 ] && [ "$i" -le "$max" ] && printf '%s\n' "$i"
        done
        ;;
      *[!0-9]*) log "  무시: $tok" ;;
      *)
        [ "$tok" -ge 1 ] && [ "$tok" -le "$max" ] && printf '%s\n' "$tok" \
          || log "  범위 밖: $tok"
        ;;
    esac
  done
}

cmd_pick() {
  step "프로필 $PROFILE  ->  브랜치 $BRANCH"
  make_work_repo
  refresh_tip
  local kf; kf="$(known_files)"

  [ -n "$SSH_TARGET" ] || die "프로필 '$PROFILE' 에 SSH 대상이 없다."
  if ! probe_device; then device_err_hint; exit 1; fi
  log "디바이스 $SSH_TARGET  dongle=$DONGLE"
  check_dongle "$DONGLE"

  # 기기의 모든 세그먼트를 route 별로 모으되, 각각이 이미 올라갔는지 표시한다.
  #   route <TAB> seg <TAB> size <TAB> 0(업로드됨)|1(미업로드)
  local seg sz name
  : > "$WORK/all.segs"
  while read -r seg sz; do
    [ -n "$seg" ] || continue
    name="$(seg_to_name "$seg" "$DONGLE")"
    if printf '%s\n' "$kf" | grep -qxF "$name"; then
      printf '%s\t%s\t%s\t0\n' "$(seg_route "$seg")" "$seg" "${sz:-0}" >> "$WORK/all.segs"
    else
      printf '%s\t%s\t%s\t1\n' "$(seg_route "$seg")" "$seg" "${sz:-0}" >> "$WORK/all.segs"
    fi
  done < <(device_segments_sized | sort)

  [ -s "$WORK/all.segs" ] || { log "기기에 세그먼트가 없다."; return 0; }

  # route 번호가 큰 것부터 보여준다 (대개 최근 주행이다).
  # 다만 재빌드로 카운터가 되감기면 이 순서가 시간순과 다를 수 있다.
  local routes; routes="$(cut -f1 "$WORK/all.segs" | sort -ru)"

  log ""
  printf '  %-3s %-26s %8s %10s  %s\n' "#" "route" "미업로드" "받을크기" "상태" >&2
  printf '  %-3s %-26s %8s %10s  %s\n' "---" "--------------------------" "--------" "----------" "--------------------" >&2

  local -a R_NAME=() R_MISS=()
  local idx=0 r tot n_all n_miss b_miss status
  local sum_miss=0 sum_bytes=0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    n_all="$(awk -F'\t' -v x="$r" '$1==x' "$WORK/all.segs" | wc -l)"
    n_miss="$(awk -F'\t' -v x="$r" '$1==x && $4==1' "$WORK/all.segs" | wc -l)"
    b_miss="$(awk -F'\t' -v x="$r" '$1==x && $4==1 {s+=$3} END{print s+0}' "$WORK/all.segs")"
    idx=$((idx + 1))
    R_NAME[$idx]="$r"
    R_MISS[$idx]="$n_miss"
    if [ "$n_miss" -eq 0 ]; then
      status="업로드 완료"
      printf '  %-3s %-26s %8s %10s  %s\n' "$idx" "$r" "-" "-" "$status" >&2
    else
      if [ "$n_miss" -eq "$n_all" ]; then status="전체 미업로드"
      else status="일부 업로드 ($((n_all - n_miss))/$n_all)"; fi
      sum_miss=$((sum_miss + n_miss)); sum_bytes=$((sum_bytes + b_miss))
      printf '  %-3s %-26s %8s %10s  %s\n' \
        "$idx" "$r" "$n_miss/$n_all" "$(human "$b_miss")" "$status" >&2
    fi
  done <<< "$routes"

  log ""
  if [ "$sum_miss" -eq 0 ]; then
    log "미업로드 세그먼트가 없다. 올릴 것이 없다."
    return 0
  fi
  log "미업로드 합계: 세그먼트 $sum_miss 개, $(human "$sum_bytes")"
  log ""

  local sel
  # stdin 을 데이터로 쓰지 않으므로 그냥 읽는다.
  # 대화형은 물론 `echo 1,3 | drivelog.sh pick` 같은 파이프 입력도 그대로 동작한다.
  printf '올릴 route 번호 (예: 1,3-5 / all / q): ' >&2
  read -r sel || sel=""

  case "$(printf '%s' "$sel" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" in
    q|quit|exit|"") log "취소했다."; return 0 ;;
    a|all)
      ROUTE_FILTER=""
      log "전체 미업로드분을 올린다."
      ;;
    *)
      local picked=() i
      while IFS= read -r i; do
        [ -n "$i" ] || continue
        if [ "${R_MISS[$i]}" -eq 0 ]; then
          log "  건너뜀 [$i] ${R_NAME[$i]} — 이미 전부 올라가 있다"
          continue
        fi
        picked+=("${R_NAME[$i]}")
      done < <(parse_selection "$sel" "$idx" | sort -un)

      [ ${#picked[@]} -gt 0 ] || { log "선택된 route 가 없다."; return 0; }
      ROUTE_FILTER="$(printf '%s,' "${picked[@]}")"
      ROUTE_FILTER="${ROUTE_FILTER%,}"
      log ""
      log "선택: ${#picked[@]} 개 route"
      printf '  %s\n' "${picked[@]}" >&2
      ;;
  esac

  # 작업 클론을 정리하고 upload 에 그대로 넘긴다 (upload 가 새로 만든다).
  rm -rf "$WORK" 2>/dev/null || true
  WORK=""
  log ""
  cmd_upload
}

# ---------- 명령: upload ----------
cmd_upload() {
  step "프로필 $PROFILE  ->  브랜치 $BRANCH"
  make_work_repo
  refresh_tip

  local kf
  kf="$(known_files)"
  log "원격 기준 처리 완료: $(printf '%s\n' "$kf" | count_lines) 개 (보관 $(remote_files | count_lines) + 정리 $(pruned_list | count_lines))"

  local todo_name=() todo_src=()
  if [ -n "$FROM_DIR" ]; then
    [ -d "$FROM_DIR" ] || die "디렉터리 없음: $FROM_DIR"
    local f b
    while IFS= read -r f; do
      b="$(basename "$f")"
      if printf '%s\n' "$kf" | grep -qxF "$b"; then continue; fi
      route_matches "$(route_of "$b")" || continue
      todo_name+=("$b")
      todo_src+=("local:$f")
    done < <(find "$FROM_DIR" -type f -name '*rlog.zst' | sort)
  else
    [ -n "$SSH_TARGET" ] || die "프로필 '$PROFILE' 에 SSH 대상이 없다. drivelog.conf 확인."
    local dongle
    if ! probe_device; then
      device_err_hint
      exit 1
    fi
    dongle="$DONGLE"
    log "디바이스 $SSH_TARGET  dongle=$dongle"
    check_dongle "$dongle"
    local s sz name todo_bytes=0
    while read -r s sz; do
      [ -n "$s" ] || continue
      name="$(seg_to_name "$s" "$dongle")"
      if printf '%s\n' "$kf" | grep -qxF "$name"; then continue; fi
      route_matches "$(seg_route "$s")" || continue
      todo_name+=("$name")
      todo_src+=("ssh:$s")
      todo_bytes=$((todo_bytes + ${sz:-0}))
    done < <(device_segments_sized | sort)
    [ "$todo_bytes" -gt 0 ] && log "받아올 총 용량: $(human "$todo_bytes")"
  fi

  local total=${#todo_name[@]}
  if [ "$total" -eq 0 ]; then
    if [ -n "$ROUTE_FILTER" ]; then
      log "--route '$ROUTE_FILTER' 에 해당하는 새 파일이 없다."
      log "  ./drivelog.sh list --profile $PROFILE  로 올릴 수 있는 route 를 확인할 것."
    else
      log "새로 올릴 파일이 없다."
    fi
    return 0
  fi
  [ -n "$ROUTE_FILTER" ] && log "--route '$ROUTE_FILTER' 적용"
  if [ "$LIMIT" -gt 0 ] && [ "$LIMIT" -lt "$total" ]; then
    total="$LIMIT"
    log "--limit $LIMIT 적용"
  fi
  log "업로드 대상: $total 개"

  if [ "$DRY_RUN" -eq 1 ]; then
    local k
    for ((k = 0; k < total; k++)); do
      log "  [dry-run] ${todo_name[$k]}  <- ${todo_src[$k]}"
    done
    return 0
  fi

  local batches=$(((total + BATCH_FILES - 1) / BATCH_FILES))
  local i=0 bn=0
  while [ "$i" -lt "$total" ]; do
    bn=$((bn + 1))
    : > "$WORK/batch.list"
    local bytes=0 j=0 name src sz
    while [ "$j" -lt "$BATCH_FILES" ] && [ "$i" -lt "$total" ]; do
      name="${todo_name[$i]}"
      src="${todo_src[$i]}"
      case "$src" in
        local:*)
          cp -- "${src#local:}" "$WORK/stage/$name"
          ;;
        ssh:*)
          ssh -o BatchMode=yes "$SSH_TARGET" \
            "cat '$DEVICE_DATA_DIR/${src#ssh:}/rlog.zst'" > "$WORK/stage/$name"
          ;;
      esac
      sz="$(stat -c %s "$WORK/stage/$name" 2>/dev/null || echo 0)"
      [ "$sz" -gt 0 ] || die "받은 파일이 비어 있다: $name"
      bytes=$((bytes + sz))
      printf '%s\n' "$name" >> "$WORK/batch.list"
      i=$((i + 1))
      j=$((j + 1))
    done

    # 이번 배치에 포함된 route 를 원장에 덧붙인다. 파일과 같은 커밋에 들어가므로
    # 중간에 끊겨도 "올라갔는데 원장에 없는" 상태가 생기지 않는다.
    sed 's/--[0-9]*--rlog\.zst$//' "$WORK/batch.list" \
      | { grep . || true; } | awk '!seen[$0]++' > "$WORK/batch.routes"

    log "batch $bn/$batches  파일 ${j} 개  $(human "$bytes")  -> push"
    build_and_push "$WORK/batch.list" \
      "drivelog(ssh): add ${j} file(s) (batch ${bn}/${batches})" \
      "$REPO_SUBDIR" "$WORK/batch.routes" || die "batch $bn push 실패"

    rm -f "$WORK"/stage/* 2>/dev/null || true
  done

  step "완료. 원격 $BRANCH tip = $(printf '%s' "$BASE" | cut -c1-8)"
  log "로컬에는 아무것도 남지 않는다 (작업 클론 삭제됨)."
}

# ---------- 명령: put (임의 파일을 브랜치 루트에 올린다) ----------
cmd_put() {
  [ ${#PUT_PATHS[@]} -gt 0 ] || die "올릴 파일을 지정할 것."
  step "프로필 $PROFILE  ->  브랜치 $BRANCH"
  make_work_repo
  refresh_tip

  : > "$WORK/batch.list"
  local p b n=0
  for p in "${PUT_PATHS[@]}"; do
    [ -f "$p" ] || die "파일 없음: $p"
    b="$(basename "$p")"
    cp -- "$p" "$WORK/stage/$b"
    printf '%s\n' "$b" >> "$WORK/batch.list"
    n=$((n + 1))
  done

  build_and_push "$WORK/batch.list" "tooling: add/update ${n} file(s)" "" \
    || die "push 실패"
  step "완료. 원격 $BRANCH tip = $(printf '%s' "$BASE" | cut -c1-8)"
}

# ---------- 명령: prune (오래된 route 를 브랜치에서 덜어낸다) ----------
# 기본은 계획만 출력한다. 실제로 지우려면 --yes 가 필요하다.
#   --yes : 최신 route 만 남긴 커밋을 새로 쌓는다.
#
# 한계: 이 방식은 브랜치 tip 에서 파일을 덜어낼 뿐 히스토리는 남는다. 즉
# 클론 받는 쪽의 체크아웃 용량은 줄지만 GitHub 이 실제로 차지하는 저장 용량은
# 줄지 않는다. 저장 용량까지 되찾으려면 히스토리를 다시 써야 하는데, 그러려면
# 기존 blob 을 전부 로컬에 가지고 있어야 한다(= 수 GB 다운로드). 그 작업은
# 대역폭이 넉넉한 클라우드 쪽에서 하는 편이 맞다. 자세한 내용은 TOOLING.md 참고.
route_of() { printf '%s' "${1%--*--rlog.zst}"; }

cmd_prune() {
  step "프로필 $PROFILE  ->  브랜치 $BRANCH  (keep=$KEEP_ROUTES)"
  make_work_repo
  refresh_tip

  local rf
  rf="$(remote_files)"
  [ -n "$rf" ] || { log "원격에 파일이 없다."; return 0; }

  local routes
  routes="$(printf '%s\n' "$rf" | while IFS= read -r n; do
    [ -n "$n" ] && route_of "$n" && printf '\n'
  done | sort -u)"

  # 정렬 기준은 업로드 순서(order.txt)다. route 이름으로 정렬하면 안 된다.
  # 기기 재빌드로 카운터가 되감기면 최신 주행이 가장 오래된 것으로 취급된다.
  order_rank_file "$WORK/order.rank"
  local n_ranked
  n_ranked="$(count_lines < "$WORK/order.rank")"

  local sorted_routes n_routes keep_list n_unranked
  sorted_routes="$(printf '%s\n' "$routes" | route_sort_keys "$WORK/order.rank" \
                   | sort | cut -f2-)"
  n_routes="$(printf '%s\n' "$sorted_routes" | count_lines)"
  n_unranked="$(printf '%s\n' "$routes" | route_sort_keys "$WORK/order.rank" \
                | grep -c '^0 ' || true)"
  keep_list="$(printf '%s\n' "$sorted_routes" | tail -n "$KEEP_ROUTES")"

  log "route 수: $n_routes,  유지: $(printf '%s\n' "$keep_list" | count_lines)"
  log "정렬 기준: 업로드 순서 (order.txt, $n_ranked 개 기록됨)"
  if [ "$n_unranked" -gt 0 ]; then
    log "  · 원장에 없는 route $n_unranked 개는 가장 오래된 것으로 취급한다"
    if [ "$n_ranked" -eq 0 ]; then
      log ""
      log "  주의: order.txt 가 비어 있어 전부 이름순으로 처리된다."
      log "        기존 데이터의 순서를 git 히스토리에서 복원하려면 먼저 실행할 것:"
      log "          ./drivelog.sh init-order --profile $PROFILE"
      log ""
    fi
  fi

  local keep_files drop_files n_keep n_drop
  keep_files="$(printf '%s\n' "$rf" | while IFS= read -r n; do
    [ -n "$n" ] || continue
    if printf '%s\n' "$keep_list" | grep -qxF "$(route_of "$n")"; then printf '%s\n' "$n"; fi
  done)"
  drop_files="$(printf '%s\n' "$rf" | while IFS= read -r n; do
    [ -n "$n" ] || continue
    if ! printf '%s\n' "$keep_list" | grep -qxF "$(route_of "$n")"; then printf '%s\n' "$n"; fi
  done)"
  n_keep="$(printf '%s\n' "$keep_files" | count_lines)"
  n_drop="$(printf '%s\n' "$drop_files" | count_lines)"
  log "파일: 유지 $n_keep,  삭제 $n_drop"

  if [ "$n_drop" -eq 0 ]; then log "지울 것이 없다."; return 0; fi
  if [ "$PRUNE_YES" -ne 1 ]; then
    log ""
    log "삭제 대상 route (업로드가 오래된 순):"
    printf '%s\n' "$sorted_routes" | head -n "$((n_routes - KEEP_ROUTES))" | sed 's/^/  /' >&2
    log ""
    log "유지할 route (가장 최근 업로드 $KEEP_ROUTES 개):"
    printf '%s\n' "$keep_list" | sed 's/^/  /' >&2
    log ""
    log "실제로 지우려면 --yes 를 붙일 것."
    return 0
  fi

  # 유지할 파일만으로 drivelog 서브트리를 새로 만든다.
  # 기존 blob 은 원격에 이미 있으므로 로컬로 내려받지 않는다.
  local sub_entries="$WORK/keep.entries"
  "${G[@]}" ls-tree "$BASE:$REPO_SUBDIR" > "$WORK/all.sub"
  : > "$sub_entries"
  local line nm
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    nm="${line#*$'\t'}"
    if printf '%s\n' "$keep_files" | grep -qxF "$nm"; then printf '%s\n' "$line" >> "$sub_entries"; fi
  done < "$WORK/all.sub"

  local subtree root commit
  subtree="$("${G[@]}" mktree --missing < "$sub_entries")"
  [ -n "$subtree" ] || die "서브트리 생성 실패"

  # 삭제 이력을 pruned.txt 에 누적한다. 기기에 원본이 남아 있어도
  # 다음 upload 가 이 목록을 보고 다시 올리지 않는다.
  { pruned_list; printf '%s\n' "$drop_files"; } | { grep . || true; } | sort -u > "$WORK/pruned.new"
  local pblob
  pblob="$("${G[@]}" hash-object -w --no-filters -- "$WORK/pruned.new")"
  [ -n "$pblob" ] || die "pruned.txt 생성 실패"

  {
    printf '040000 tree %s\t%s\n' "$subtree" "$REPO_SUBDIR"
    printf '100644 blob %s\t%s\n' "$pblob" "$PRUNED_FILE"
  } > "$WORK/add.root"
  "${G[@]}" ls-tree "$BASE" > "$WORK/old.root"
  root="$(merge_tree "$WORK/old.root" "$WORK/add.root")"
  [ -n "$root" ] || die "루트 트리 생성 실패"

  commit="$("${G[@]}" commit-tree "$root" -p "$BASE" -m "drivelog: prune, keep newest $KEEP_ROUTES route(s)")"
  [ -n "$commit" ] || die "커밋 생성 실패"
  "${G[@]}" push --quiet --no-thin origin "$commit:refs/heads/$BRANCH" || die "push 실패"
  step "완료. $n_drop 개 파일을 브랜치에서 덜어냈다 (히스토리에는 남아 있다)."
}

# ---------- 명령: init-order (원장 최초 생성, 1회) ----------
# 구 도구로 올린 기존 파일들은 order.txt 에 없다. 그 순서를 git 히스토리에서
# 복원한다. 각 파일이 "어느 커밋에서 처음 추가됐는가" 가 곧 업로드 시점이다.
# 추정이 아니라 기록이므로 이름이나 기기 시각보다 정확하다.
#
# 이때만 히스토리 전체가 필요하다. --filter=blob:none 이므로 데이터 blob 은
# 받지 않는다 (커밋과 트리만, 수 MB 수준).
cmd_init_order() {
  step "프로필 $PROFILE  ->  브랜치 $BRANCH  (업로드 순서 원장 생성)"
  make_work_repo
  refresh_tip

  local existing
  existing="$(order_list | { grep . || true; } | count_lines)"
  if [ "$existing" -gt 0 ] && [ "$PRUNE_YES" -ne 1 ]; then
    log "order.txt 에 이미 $existing 개가 있다."
    log "다시 만들려면 --yes 를 붙일 것 (기존 순서는 덮어쓰인다)."
    return 0
  fi

  log "히스토리를 받는다 (blob 제외, 커밋·트리만) …"
  local hist="$WORK/hist"
  git clone --quiet --filter=blob:none --no-checkout \
    --single-branch --branch "$BRANCH" "$REMOTE_URL" "$hist" || auth_hint
  local H=(git -C "$hist")

  local n_commits
  n_commits="$("${H[@]}" rev-list --count HEAD)"
  log "커밋 $n_commits 개를 오래된 순으로 훑는다 …"

  # 커밋을 오래된 순으로 보며, 각 커밋에서 처음 추가된 route 를 순서대로 기록한다.
  "${H[@]}" log --reverse --format='%H' -- "$REPO_SUBDIR" \
    | while IFS= read -r c; do
        "${H[@]}" diff-tree --no-commit-id --name-only --diff-filter=A -r "$c" \
          -- "$REPO_SUBDIR" 2>/dev/null || true
      done \
    | sed "s#^${REPO_SUBDIR}/##; s/--[0-9]*--rlog\.zst\$//" \
    | { grep . || true; } | awk '!seen[$0]++' > "$WORK/stage/$ORDER_FILE"

  local n_routes
  n_routes="$(count_lines < "$WORK/stage/$ORDER_FILE")"
  [ "$n_routes" -gt 0 ] || die "히스토리에서 route 를 찾지 못했다"

  log "복원된 route: $n_routes 개"
  log "  가장 먼저 올린 것: $(head -n1 "$WORK/stage/$ORDER_FILE")"
  log "  가장 나중에 올린 것: $(tail -n1 "$WORK/stage/$ORDER_FILE")"

  if [ "$DRY_RUN" -eq 1 ]; then
    log ""
    log "[dry-run] 아래 순서로 order.txt 를 올릴 예정이다:"
    cat -n "$WORK/stage/$ORDER_FILE" | sed 's/^/  /' >&2
    return 0
  fi

  printf '%s\n' "$ORDER_FILE" > "$WORK/order.list"
  build_and_push "$WORK/order.list" \
    "drivelog: init upload-order ledger ($n_routes routes from history)" "" \
    || die "order.txt push 실패"
  step "완료. 이제 prune 이 업로드 순서로 판단한다."
}

case "$CMD" in
  status)     cmd_status ;;
  list)       cmd_list ;;
  pick|i)     cmd_pick ;;
  upload)     cmd_upload ;;
  put)        cmd_put ;;
  prune)      cmd_prune ;;
  init-order) cmd_init_order ;;
  *)          die "알 수 없는 명령: $CMD (status|list|pick|upload|put|prune|init-order)" ;;
esac
