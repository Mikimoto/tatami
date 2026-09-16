#!/usr/bin/env bash
# 走 golden 語料驗 Swift，完全不碰 bash。
#
# 語料是 `tests/diff_bash_swift.sh --record` 錄下來的：**輸入與輸出一起凍住**。
# 只凍輸出是不夠的，因為有兩類輸入不是常數——隨機矩形那 400 組來自 awk 的 rand()
# （實作定義的序列），設定查詢有幾組吃的是使用者會編輯的 layout.json。凍住輸入之
# 後，這支 harness 不需要 awk、不需要 jq、不需要 layout.json，也不需要 bash 那 49
# 支函式，所以 workmode.sh 換成 wrapper 之後它照樣跑得動。
#
# 語料錄的是**bash 當時的行為**，其中包含幾個已知缺陷（見 CLAUDE.md 那節）。所以
# 它是「現況的快照」而不是「正確的定義」：之後要修那些缺陷，就要連對應的 golden
# 一起改，並在 commit message 寫明改了哪幾組與為什麼。改期望值等於改行為。
#
# 不在這支裡的三組：validate 的兩組不合法 JSON（只比 rc 與 stderr 前綴，因為 jq 的
# 錯誤文字複製不了）與 fmt（對照組是 `jq .` 不是 bash）。三組都不依賴 bash，退役時
# 會搬過來，現在還留在 diff_bash_swift.sh。
#
# 語料真的有牙齒嗎——2026-08-16 實測四個突變，每個都還原確認回到全同（當時語料
# 是 2243 組，之後又補了 14 組斷言輸入）：
#
#   拿掉 JQPrint 的 DEL 跳脫          語料 0 組  ← 單元測試紅，語料沒反應
#   JQNumber 門檻 +15 → +14           語料 1 組  ← 只有極端量級那組會走到
#   LayoutTree.prune 的 axis 鍵       語料 7 組
#   RectTree（rects_to_tree）的 axis 鍵  語料 255 組
#
# 兩件事值得記住。一是語料是**精準**的：改一支窄函式就只有用到它的那幾組轉紅，
# 改在大宗路徑上就 255 組一起紅，不是全有全無。二是第一列——**語料與單元測試守
# 的不是同一批東西**，DEL 那條只有單元測試看得到。所以退役之後兩邊都要留著，
# 誰都不能取代誰。
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=app/.build/debug/tatami
GOLDEN_DIR=tests/golden
MANIFEST="${GOLDEN_DIR}/manifest.tsv"
EXPECTED=2257
FAILED=0
RAN=0

# compare <名稱> <期望檔> <期望 rc> <實際檔> <實際 rc>
# 比檔案不比字串：$(...) 會砍掉尾端換行，而「有沒有尾端換行」正是待驗的東西之一。
compare() {
  local name="$1" eout="$2" erc="$3" aout="$4" arc="$5"
  if ! cmp -s "$eout" "$aout"; then
    printf 'DIFF %s\n' "$name"
    printf '  golden:\n'; xxd "$eout" | head -3 | sed 's/^/    /'
    printf '  swift :\n'; xxd "$aout" | head -3 | sed 's/^/    /'
    FAILED=1
    return 1
  fi
  if [ "$erc" != "$arc" ]; then
    printf 'DIFF %s（exit code：golden=%s swift=%s）\n' "$name" "${erc}" "${arc}"
    FAILED=1
    return 1
  fi
  return 0
}

# replay_case <idx> <channel> <期望 rc> <label>
# 回 0＝相同。缺檔一律硬失敗，不可以當成空輸出去比——那會讓「語料掉了」與
# 「兩邊都是空的」外觀完全相同，正好是這支 harness 要防的東西。
replay_case() {
  local idx="$1" channel="$2" erc="$3" label="$4"
  local argvf="${GOLDEN_DIR}/${idx}.argv" eout="${GOLDEN_DIR}/${idx}.out"

  if [ ! -f "$argvf" ] || [ ! -f "$eout" ]; then
    printf 'MISSING %s %s（語料缺檔：%s / %s）\n' "$idx" "$label" "$argvf" "$eout"
    FAILED=1
    return 1
  fi

  local -a argv=()
  local a
  while IFS= read -r -d '' a; do argv+=("$a"); done < "$argvf"
  if [ "${#argv[@]}" -eq 0 ]; then
    printf 'MISSING %s %s（argv 是空的）\n' "$idx" "$label"
    FAILED=1
    return 1
  fi

  local aout arc
  aout=$(mktemp -t goldenswift-XXXXXX)
  # stdin 給 /dev/null：manifest 走 fd 3，但受測程式若讀 stdin 仍可能吃掉別的東西。
  if [ "$channel" = stderr ]; then
    "$BIN" __diff "${argv[@]}" 2>| "$aout" >/dev/null </dev/null
  else
    "$BIN" __diff "${argv[@]}" >| "$aout" 2>/dev/null </dev/null
  fi
  arc=$?

  compare "${idx} ${label}" "$eout" "$erc" "$aout" "$arc"
  local result=$?
  rm -f "$aout"
  return $result
}

# 這支 harness 本身是未經驗證的程式碼，所以三個方向都要有對照組：必定相同、
# 位元組不同、rc 不同，外加「語料缺檔必須硬失敗」——只有負向對照組的話，
# harness 整個壞掉與「全部通過」外觀相同。
self_test() {
  local a b c
  a=$(mktemp -t goldenharness-XXXXXX)
  b=$(mktemp -t goldenharness-XXXXXX)
  c=$(mktemp -t goldenharness-XXXXXX)
  printf 'hello' >| "$a"; printf 'hello' >| "$b"; printf 'world' >| "$c"

  if ! compare '正控制組' "$a" 0 "$b" 0 >/dev/null; then
    printf '! harness 壞了：相同的輸入被判成不同\n' >&2; rm -f "$a" "$b" "$c"; exit 1
  fi
  if compare '負控制組（位元組）' "$a" 0 "$c" 0 >/dev/null 2>&1; then
    printf '! harness 壞了：不同的位元組被判成相同\n' >&2; rm -f "$a" "$b" "$c"; exit 1
  fi
  if compare '負控制組（rc）' "$a" 0 "$b" 1 >/dev/null 2>&1; then
    printf '! harness 壞了：不同的 exit code 被判成相同\n' >&2; rm -f "$a" "$b" "$c"; exit 1
  fi
  rm -f "$a" "$b" "$c"

  # 缺檔那條：拿一個一定不存在的 idx 去跑，必須回非零並且把 FAILED 設起來。
  FAILED=0
  if replay_case 9999999 stdout 0 '不存在的語料' >/dev/null 2>&1; then
    printf '! harness 壞了：語料缺檔沒有被判成失敗\n' >&2; exit 1
  fi
  if [ "$FAILED" != 1 ]; then
    printf '! harness 壞了：語料缺檔沒有把 FAILED 設起來\n' >&2; exit 1
  fi

  # 每個負向對照組都是靠「compare／replay_case 真的把 FAILED 設起來」來判定的，
  # 所以跑完 self_test 時 FAILED 必定是 1。收尾一定要清掉，否則整份語料全過也會
  # 回非零——第一次寫這支就是這樣壞的，而且外觀是「零個 DIFF 但結論說有差異」。
  FAILED=0
  printf '四個對照組都如預期（相同→過、位元組不同→DIFF、rc 不同→DIFF、缺檔→MISSING）\n'
}

if [ ! -x "$BIN" ]; then
  printf '! 找不到 %s，先跑 swift build --package-path app\n' "${BIN}" >&2
  exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  printf '! 找不到語料 %s，先跑 bash tests/diff_bash_swift.sh --record\n' "${MANIFEST}" >&2
  exit 1
fi

self_test

# manifest 走 fd 3：迴圈裡會叫 workmode，它若讀 stdin 就會把 manifest 吃掉。
while IFS=$'\t' read -r idx channel erc label <&3; do
  RAN=$((RAN + 1))
  replay_case "$idx" "$channel" "$erc" "$label"
done 3< "$MANIFEST"

# 跑過的組數要正面確認，不能用「沒看到 DIFF」推論——語料整個沒讀到時
# 一個 DIFF 都不會有，那與全部通過的外觀完全相同。
if [ "$RAN" != "$EXPECTED" ]; then
  printf '! 只跑了 %s 組，預期 %s 組（語料被截斷或 manifest 壞了）\n' "$RAN" "$EXPECTED" >&2
  FAILED=1
fi

if [ "$FAILED" = 0 ]; then
  printf -- '--- 語料全部相同：%s 組 ---\n' "$RAN"
else
  printf -- '--- 有差異，見上 ---\n'
fi
exit "$FAILED"
