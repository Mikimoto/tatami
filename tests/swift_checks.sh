#!/usr/bin/env bash
# 三組**從來就不需要 bash** 的檢查，從 diff_bash_swift.sh 搬過來的（那支在 bash 退役
# 時一起刪掉）。
#
# 為什麼不併進 golden_swift.sh：那支的性質是「不需要 bash、awk、jq 或 layout.json」，
# 而且實測驗過（把整個 scripts/ 拿掉照樣跑完 2257 組）。這三組要 jq、要真實的
# layout.json，混進去就把那個性質弄髒了，之後也沒人分得出哪些是自足的。
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=app/.build/debug/tatami
FAILED=0
RAN=0
EXPECTED=3

if [ ! -x "$BIN" ]; then
  printf '! 找不到 %s，先跑 swift build --package-path app\n' "${BIN}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  printf '! 找不到 jq，這支的對照組就是 jq 本身\n' >&2
  exit 1
fi

# ---------- fmt ----------
#
# 對照組是 `jq .` **本身**而不是 bash：保序重排這個表面 bash 那側從來沒有過，
# 一直都是直接呼叫 jq。餵 `examples/layout.json`（使用者真實設定的副本，只讀不寫），
# 所以它同時是一條「真實形狀的設定餵給我們的 writer 仍與 jq 一致」的性質測試。
fmt_matches_jq() {
  local expected actual erc arc
  expected=$(mktemp -t swiftcheck-XXXXXX)
  actual=$(mktemp -t swiftcheck-XXXXXX)
  jq . examples/layout.json >| "$expected" 2>/dev/null; erc=$?
  "$BIN" fmt < examples/layout.json >| "$actual" 2>/dev/null; arc=$?
  RAN=$((RAN + 1))
  if ! cmp -s "$expected" "$actual"; then
    printf 'DIFF fmt（對照組是 jq .）\n'
    printf '  jq   :\n'; xxd "$expected" | head -3 | sed 's/^/    /'
    printf '  swift:\n'; xxd "$actual" | head -3 | sed 's/^/    /'
    FAILED=1
  elif [ "$erc" != "$arc" ]; then
    printf 'DIFF fmt（exit code：jq=%s swift=%s）\n' "$erc" "$arc"
    FAILED=1
  else
    printf 'same fmt（對照組是 jq .）\n'
  fi
  rm -f "$expected" "$actual"
}

# ---------- validate 吃到不合法 JSON ----------
#
# 這兩組**不進語料**，因為 jq 的錯誤文字複製不了——錄進去就是一組永遠 DIFF 的案例。
# 能斷言的是 rc 與那句前綴，而那兩件事不需要 bash 在場。
#
# 前綴取自 tests/oracle/workmode-38.line（凍結的那一行），不是抄在這裡：抄一份
# 就會與 workmode.sh 漂移，而那正是這種檢查最容易壞掉的方式。
validate_rejects() {
  local label="$1" input="$2" prefix
  prefix=$(sed -n 's/.*printf '"'"'\(![^%]*\)%s.*/\1/p' tests/oracle/workmode-38.line)
  if [ -z "$prefix" ]; then
    printf '! 從 tests/oracle/workmode-38.line 挖不出前綴，這條檢查等於沒跑\n' >&2
    FAILED=1
    return
  fi
  local err rc
  err=$(mktemp -t swiftcheck-XXXXXX)
  "$BIN" __diff validate "$input" 2>| "$err" >/dev/null; rc=$?
  RAN=$((RAN + 1))
  if [ "$rc" != 1 ]; then
    printf 'DIFF %s（rc=%s，預期 1）\n' "$label" "$rc"
    FAILED=1
  elif ! grep -q -- "^${prefix}" "$err"; then
    printf 'DIFF %s（stderr 沒有以「%s」開頭）\n' "$label" "$prefix"
    sed 's/^/    /' "$err"
    FAILED=1
  else
    printf 'same %s（只比前綴與 rc，jq 的錯誤文字複製不了）\n' "$label"
  fi
  rm -f "$err"
}

fmt_matches_jq
validate_rejects '不是合法 JSON（裸字串）' 'not json'
validate_rejects '不是合法 JSON（截斷）' '{"home":'

# 跑過的組數要正面確認：三條全部靜默跳過時一個 DIFF 都不會有，
# 那與全部通過的外觀完全相同。
if [ "$RAN" != "$EXPECTED" ]; then
  printf '! 只跑了 %s 組，預期 %s 組\n' "$RAN" "$EXPECTED" >&2
  FAILED=1
fi

if [ "$FAILED" = 0 ]; then
  printf -- '--- Swift-only 檢查全部通過：%s 組 ---\n' "$RAN"
else
  printf -- '--- 有差異，見上 ---\n'
fi
exit "$FAILED"
