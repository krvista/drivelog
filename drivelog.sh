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
#   ./drivelog.sh status  [--profile ccnc|wk2]
#   ./drivelog.sh upload  [--profile ccnc|wk2] [--limit N] [--batch N] [--dry-run]
#   ./drivelog.sh upload  --from-dir <디렉터리>   # 이미 받아둔 로컬 파일을 올린다
#   ./drivelog.sh put <파일>...                   # 임의 파일을 브랜치 루트에 올린다

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

declare -A PROFILE_SSH PROFILE_BRANCH
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
CMD="${1:-status}"
shift || true
LIMIT=0
DRY_RUN=0
FROM_DIR=""
KEEP_ROUTES=5
PRUNE_YES=0
PUT_PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)  PROFILE="$2"; shift 2 ;;
    --branch)   FORCE_BRANCH="$2"; shift 2 ;;
    --limit)    LIMIT="$2"; shift 2 ;;
    --batch)    BATCH_FILES="$2"; shift 2 ;;
    --from-dir) FROM_DIR="$2"; shift 2 ;;
    --keep)     KEEP_ROUTES="$2"; shift 2 ;;
    --yes)      PRUNE_YES=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
    -*)         die "알 수 없는 옵션: $1" ;;
    *)          PUT_PATHS+=("$1"); shift ;;
  esac
done

if [ -n "$FORCE_BRANCH" ]; then
  BRANCH="$FORCE_BRANCH"
else
  BRANCH="${PROFILE_BRANCH[$PROFILE]:-}"
fi
SSH_TARGET="${PROFILE_SSH[$PROFILE]:-}"
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

# 원격 기준 "이미 처리된" 파일 이름 전체 (현재 보관 중 + 정리 완료)
# 주의: 빈 브랜치(아직 데이터가 없는 wk2 등)에서는 입력이 비어 grep 이 1 을 돌려준다.
# set -e 아래에서 그대로 두면 함수가 조용히 중단되므로 반드시 삼켜야 한다.
known_files() {
  { remote_files; pruned_list; } | { grep . || true; } | sort -u
}

# ---------- 2. 디바이스 인벤토리 ----------
device_dongle() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_TARGET" \
    'cat /data/params/d/DongleId 2>/dev/null' 2>/dev/null | tr -d '\r\n'
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
build_and_push() {
  local list_file="$1" msg="$2" prefix="$3"
  local attempt subtree root commit

  stage_entries "$list_file" "$WORK/add.entries"

  # 두 PC 가 서로 다른 파일을 올리므로 충돌은 항상 병합 가능하다.
  # 진 쪽은 새 tip 위에 다시 쌓아 올리기만 하면 되므로 넉넉히 재시도한다.
  for ((attempt = 1; attempt <= PUSH_RETRIES; attempt++)); do
    if [ -n "$prefix" ]; then
      "${G[@]}" ls-tree "$BASE:$prefix" > "$WORK/old.sub" 2>/dev/null || : > "$WORK/old.sub"
      subtree="$(merge_tree "$WORK/old.sub" "$WORK/add.entries")"
      [ -n "$subtree" ] || die "서브트리 생성 실패"
      printf '040000 tree %s\t%s\n' "$subtree" "$prefix" > "$WORK/add.root"
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
    log "가장 오래됨   : $(printf '%s\n' "$rf" | sort | head -1)"
    log "가장 최근     : $(printf '%s\n' "$rf" | sort | tail -1)"
  fi
  log "작업 클론 크기: $(du -sh "$WORK/repo" 2>/dev/null | cut -f1)  (데이터 blob 미포함)"

  if [ -z "$SSH_TARGET" ]; then
    log "디바이스      : 설정 없음 (drivelog.conf 에 PROFILE_SSH[$PROFILE] 지정)"
    return 0
  fi

  local dongle
  dongle="$(device_dongle || true)"
  if [ -z "$dongle" ]; then
    log "디바이스      : $SSH_TARGET 접속 불가 (지금은 다른 네트워크일 수 있다)"
    return 0
  fi
  log "디바이스      : $SSH_TARGET  dongle=$dongle"

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
      todo_name+=("$b")
      todo_src+=("local:$f")
    done < <(find "$FROM_DIR" -type f -name '*rlog.zst' | sort)
  else
    [ -n "$SSH_TARGET" ] || die "프로필 '$PROFILE' 에 SSH 대상이 없다. drivelog.conf 확인."
    local dongle
    dongle="$(device_dongle || true)"
    [ -n "$dongle" ] || die "디바이스 $SSH_TARGET 에 접속할 수 없다."
    log "디바이스 $SSH_TARGET  dongle=$dongle"
    local s name
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      name="$(seg_to_name "$s" "$dongle")"
      if printf '%s\n' "$kf" | grep -qxF "$name"; then continue; fi
      todo_name+=("$name")
      todo_src+=("ssh:$s")
    done < <(device_segments | sort)
  fi

  local total=${#todo_name[@]}
  if [ "$total" -eq 0 ]; then
    log "새로 올릴 파일이 없다."
    return 0
  fi
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

    log "batch $bn/$batches  파일 ${j} 개  $(human "$bytes")  -> push"
    build_and_push "$WORK/batch.list" \
      "drivelog(ssh): add ${j} file(s) (batch ${bn}/${batches})" \
      "$REPO_SUBDIR" || die "batch $bn push 실패"

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

  local n_routes keep_list
  n_routes="$(printf '%s\n' "$routes" | count_lines)"
  keep_list="$(printf '%s\n' "$routes" | tail -n "$KEEP_ROUTES")"
  log "route 수: $n_routes,  유지: $(printf '%s\n' "$keep_list" | count_lines)"

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
    log "삭제 대상 route:"
    printf '%s\n' "$routes" | head -n "$((n_routes - KEEP_ROUTES))" | sed 's/^/  /' >&2
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

case "$CMD" in
  status) cmd_status ;;
  upload) cmd_upload ;;
  put)    cmd_put ;;
  prune)  cmd_prune ;;
  *)      die "알 수 없는 명령: $CMD (status|upload|put|prune)" ;;
esac
