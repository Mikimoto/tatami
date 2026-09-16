#!/usr/bin/env bash
#
# tatami 的發佈管線。十二步，跑完會有一個簽好章、notarize 過、釘好票的 dmg
# 與一個 git tag，並印出 Homebrew cask 要填的兩個值。
#
#   Scripts/release.sh 0.1.0 --profile Tatami.app
#   Scripts/release.sh --dry-run 0.1.0          # 不送審、不打 tag
#   Scripts/release.sh --verify-only build/tatami-0.1.0-abc1234.dmg
#
# 骨架抄自隔壁 FindMouse 的 Scripts/release.sh，**砍掉四段它專屬的**：
# 逐一簽巢狀 bundle、驗 app-sandbox entitlements、出廠 pack 驗證、隱私清單驗證。
# tatami 的 bundle 只有四個檔（Info.plist、MacOS/Tatami、Resources/Tatami.icns、
# _CodeSignature/CodeResources），**零個巢狀 bundle**，而且**不能沙盒**——它要
# AX 權限去操作別的 app 的視窗。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${TATAMI_SIGN_IDENTITY:-Developer ID Application: DeepThought Co., Ltd. (JA387Z4D7Q)}"
STAGE="${ROOT}/build/release"

die() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
say() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }

MODE=full
VERSION=""
PROFILE=""
VERIFY_TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) MODE=dry; shift ;;
        # **先驗參數個數再 shift。** `shift 2` 在只剩一個參數時會失敗，而 set -e
        # 讓整支當場死掉——使用者只會看到 exit 1 與一片空白，底下那句說明永遠
        # 走不到。（FindMouse 的同一段記過這個實測。）
        --verify-only)
            [[ $# -ge 2 ]] || die "--verify-only 後面要接一個 .dmg 路徑。"
            MODE=verify; VERIFY_TARGET="$2"; shift 2 ;;
        --profile)
            [[ $# -ge 2 ]] || die "--profile 後面要接 keychain profile 名稱。先跑一次：xcrun notarytool store-credentials <名稱>"
            PROFILE="$2"; shift 2 ;;
        -*) die "不認得的選項 ${1}。用法見這個檔的檔頭。" ;;
        # **第二個位置參數要硬失敗，不能靜默覆蓋。** `release.sh 0.1.0 0.2.0`
        # 若取後者，發出去的檔名、dmg 卷標與 Info.plist 全部標成一個你沒打算發
        # 的版本——而每一條驗收都會通過，因為產物本身是自洽的。
        *)  [[ -z "${VERSION}" ]] || die "版本號給了兩個：「${VERSION}」與「${1}」。只能給一個。"
            VERSION="$1"; shift ;;
    esac
done

# --- 驗收的執行器 -----------------------------------------------------------
#
# **不接管線。** `cmd | tail` 的 exit code 來自 tail，那會讓每一條驗收都「通過」。
# 輸出寫檔，只在失敗時印出來。
check() {
    local what="$1"; shift
    local log; log="$(mktemp)"
    if "$@" >"${log}" 2>&1; then
        ok "${what}"; rm -f "${log}"; return 0
    fi
    printf '  \033[31m✗\033[0m %s\n' "${what}"
    sed 's/^/      /' "${log}"
    rm -f "${log}"
    return 1
}

# **spctl 在「assessments disabled」下對任何東西都回 accepted**（man spctl：
# assessment APIs "always report success"）。開發機為了測未簽版本關掉 Gatekeeper
# 是常見的事，而症狀是那兩條 spctl 驗收**靜默變成恆真句**——正好是這份驗收最該
# 防的東西。
require_gatekeeper_on() {
    spctl --status 2>&1 | grep -q 'assessments enabled' \
        || die "Gatekeeper 是關的（spctl --status）。那會讓底下兩條 spctl 驗收變成恆真句。先 sudo spctl --master-enable 再跑。"
}

notarize() {
    local target="$1" label="$2" log id
    [[ -n "${PROFILE}" ]] || die "沒有 --profile。跑一次 xcrun notarytool store-credentials <名稱> 之後把名字傳進來。"
    log="$(mktemp)"
    xcrun notarytool submit "${target}" --keychain-profile "${PROFILE}" --wait 2>&1 \
        | tee "${log}" || true
    # **`|| true` 不是裝飾。** `set -euo pipefail` 下 grep 沒中會讓這一行的賦值回
    # 非零、整支當場死掉，而它就在 `status: Accepted` 判定之前——症狀是
    # 「notarize 明明成功，腳本卻無聲無息地結束」。
    id="$(grep -Eo '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' "${log}" | head -1 || true)"
    # **不拿 exit code 當判準，看它印出來的 status。** 「送出成功、而 Apple 判
    # Invalid」會不會也回非零，這個專案還沒有樣本；看 status 在兩種情況下都對。
    if ! grep -qE 'status: *Accepted' "${log}"; then
        printf '\033[31mnotarize 沒過（%s）。以下是 Apple 給的原因：\033[0m\n' "${label}"
        # 失敗最常見的回覆只有一個 request id，要再下一個指令才看得到原因。
        # 「還要再問一次才知道為什麼」不留給未來的自己。
        if [[ -n "${id}" ]]; then
            xcrun notarytool log "${id}" --keychain-profile "${PROFILE}" 2>&1 | sed 's/^/  /' || true
        fi
        rm -f "${log}"
        die "notarize 失敗（${label}，submission ${id:-未知}）"
    fi
    rm -f "${log}"
    ok "Accepted（${label}，submission ${id:-未知}）"
}

# --- 八道驗收 ---------------------------------------------------------------
#
# **掛起來驗 dmg 裡面那個 .app**——驗的是使用者真的會拿到的東西，不是手邊那份
# staging 副本。**每一條都跑完才回報**，不在第一條就 die：只紅一條與全部都紅是
# 完全不同的診斷，而前者常常代表後面幾條根本沒執行。
#
# `local` 不可省：這個函式會被呼叫兩次以上，靠「執行順序剛好」活著的全域變數
# 遲早會死，而症狀是印出一個看起來不像 bug 的怪字串。
verify_dmg() {
    local dmg="$1" mnt app rc=0 req
    mnt="$(mktemp -d)"
    hdiutil attach "${dmg}" -readonly -nobrowse -mountpoint "${mnt}" >/dev/null 2>&1 \
        || { printf '  \033[31m✗\033[0m 掛不起來：%s\n' "${dmg}"; rmdir "${mnt}"; return 1; }

    app="$(/usr/bin/find "${mnt}" -maxdepth 1 -name '*.app' -print -quit)"
    if [[ -z "${app}" ]]; then
        printf '  \033[31m✗\033[0m dmg 裡沒有 .app\n'; rc=1
    else
        check "codesign --verify（封緘一致性）" \
              codesign --verify --deep --strict --verbose=2 "${app}" || rc=1
        # 上面那條驗的是**封緘一致性不是信任鏈**——一個好好地 ad-hoc 簽過的 bundle
        # 照樣回 0。所以要另外斷言「是誰簽的」，否則整份驗收對身分的判定 100%
        # 押在 spctl 上，而 spctl 有被全域關掉的可能。
        req='=anchor apple generic and certificate leaf[subject.OU] = "JA387Z4D7Q"'
        check "簽章者是我們（Apple 根 ＋ team JA387Z4D7Q）" \
              codesign --verify -R "${req}" "${app}" || rc=1
        # `-t exec` 給 .app，`-t open` 給 dmg。型別用錯會得到看似通過的無意義結果。
        # `--no-cache`：不加的話很可能命中前一輪留下的 assessment cache。
        check "spctl app（Gatekeeper 對 app 的判定）" \
              spctl -a --no-cache -vvv -t exec "${app}" || rc=1
        # **使用者最後執行的是這個 .app，不是 dmg。** 它自己沒有票的話，離線首次
        # 啟動就得靠系統上網查——而那正是漏 staple 最賤的症狀：本機測都過。
        check "stapler validate app（拖出來那份也要有票）" \
              xcrun stapler validate "${app}" || rc=1
        # Apple 自己的發布就緒檢查，與上一條獨立：它讀整份 bundle 的多項條件，
        # 而且**不吃 Gatekeeper 的評估快取**（spctl 那兩條會）。macOS 14 起內建，
        # 實測在 /usr/bin/syspolicy_check。
        check "syspolicy_check（Apple 的發布就緒判定）" \
              syspolicy_check distribution "${app}" || rc=1
        # tatami **沒有巢狀 bundle**（實測零命中），所以不掃 Contents/Resources
        # 底下的 *.bundle。哪天真的加了資源 bundle，這裡要補一條逐一驗簽章者的
        # 迴圈——SwiftPM 蓋的是 ad-hoc 章，而上面那條 `-R` 沒有 --deep、只驗外層。
        check "沒有意外的巢狀 bundle（有的話上面那條驗不到它）" \
              test -z "$(/usr/bin/find "${app}" -name '*.bundle' 2>/dev/null)" || rc=1
    fi
    check "spctl dmg（使用者實際遇到的那一關）" \
          spctl -a --no-cache -vvv -t open --context context:primary-signature "${dmg}" || rc=1
    check "stapler validate dmg（票沒釘上，使用者離線就被擋）" \
          xcrun stapler validate "${dmg}" || rc=1

    hdiutil detach "${mnt}" -quiet >/dev/null 2>&1 \
        || hdiutil detach "${mnt}" -force -quiet >/dev/null 2>&1 || true
    rmdir "${mnt}" 2>/dev/null || true
    return "${rc}"
}

# --- --verify-only ----------------------------------------------------------
if [[ "${MODE}" == verify ]]; then
    [[ -f "${VERIFY_TARGET}" ]] || die "找不到 ${VERIFY_TARGET}"
    require_gatekeeper_on
    say "驗收 $(basename "${VERIFY_TARGET}")"
    verify_dmg "${VERIFY_TARGET}" || die "驗收沒過。"
    ok "八道全過"
    exit 0
fi

# --- 前置 -------------------------------------------------------------------
say "1／12 工作樹與版本"
[[ -n "${VERSION}" ]] || die "要給版本號，例如：Scripts/release.sh 0.1.0 --profile Tatami.app"
# 語意版號的形狀。打錯成 `v0.1.0` 的話，tag 會變成 `vv0.1.0`、dmg 檔名也跟著錯。
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "版本號要是 X.Y.Z（不要前綴 v）：收到「${VERSION}」"
[[ -z "$(git -C "${ROOT}" status --porcelain)" ]] \
    || die "工作樹不乾淨。發版要能對得回一個 commit。"
SHA="$(git -C "${ROOT}" rev-parse --short HEAD)"
git -C "${ROOT}" rev-parse "v${VERSION}" >/dev/null 2>&1 \
    && die "tag v${VERSION} 已經存在。"
ok "${VERSION} @ ${SHA}"

say "2／12 工具鏈"
for tool in codesign hdiutil ditto xcrun spctl; do
    command -v "${tool}" >/dev/null || die "找不到 ${tool}"
done
command -v syspolicy_check >/dev/null || die "找不到 syspolicy_check（macOS 14 起內建）"
security find-identity -v -p codesigning | grep -qF "${IDENTITY}" \
    || die "鑰匙圈裡沒有這個簽章身分：${IDENTITY}"
ok "齊了"

say "3／12 release 建置"
rm -rf "${STAGE}"; mkdir -p "${STAGE}"
swift build --package-path "${ROOT}/app" -c release >/dev/null
BIN="${ROOT}/app/.build/release/tatami"
[[ -x "${BIN}" ]] || die "建置完卻找不到 ${BIN}"
ok "$(/usr/bin/du -h "${BIN}" | awk '{print $1}')"

say "4／12 組裝 bundle"
BUILD_NUMBER="$(date -u +%Y.%m%d.%H%M)"
APP="${STAGE}/Tatami.app"
# 用 `mise run app` 那一套會裝到 ~/Applications 並重簽使用者正在用的那份——
# 那份的 AX 授權不該為了一次發版被動到。所以這裡自己組一份在 build/ 底下。
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/Tatami"
[[ -f "${ROOT}/assets/Tatami.icns" ]] || die "找不到 assets/Tatami.icns，先跑 mise run icon"
cp "${ROOT}/assets/Tatami.icns" "${APP}/Contents/Resources/Tatami.icns"
cat >| "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.deepthought.tatami</string>
    <key>CFBundleName</key><string>Tatami</string>
    <key>CFBundleExecutable</key><string>Tatami</string>
    <key>CFBundleIconFile</key><string>Tatami</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "${APP}/Contents/Info.plist" >/dev/null || die "Info.plist 不合法"
# **斷言版本真的寫進去了。** heredoc 沒加引號才會插值，而那個改動失敗時產生的是
# 一個**結構合法但版本空白**的 plist——`plutil -lint` 抓不到。
GOT="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "${APP}/Contents/Info.plist")"
[[ "${GOT}" == "${VERSION}" ]] || die "Info.plist 的版本是「${GOT}」，不是「${VERSION}」"
ok "${VERSION} (${BUILD_NUMBER})"

say "5／12 簽章"
# `--timestamp` 是 notarize 的要求。不給旗標時 codesign 走 system-specific default
# behavior，man page 明寫 "may result in some but not all code signatures being
# timestamped"——給了旗標，連不上時戳伺服器會硬失敗而不是靜默降級。
# **沒有 --entitlements**：tatami 不能沙盒，它要 AX 權限操作別的 app 的視窗。
codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${APP}"
# 立刻斷言 designated requirement 裡沒有 cdhash。AX 的授權釘在 DR 上，
# 而一個含 cdhash 的 DR 會讓使用者每次更新都要重新授權。
codesign -d -r- "${APP}" 2>&1 | grep -qi cdhash \
    && die "designated requirement 裡有 cdhash，AX 授權撐不過更新。"
ok "已簽 ${IDENTITY}"

if [[ "${MODE}" == dry ]]; then
    say "--dry-run：到此為止（不送審、不打 tag）"
    ok "產物在 ${APP}"
    exit 0
fi

say "6／12 notarize .app（第一次等 Apple）"
# **兩個產物各送審一次，因為票是按 cdhash 發的。** 送 dmg 時 Apple 也會替裡面的
# .app 發一張票，但那救不了流程——票要等送審完才存在，而 .app 一旦被釘票，用它
# 重打的 dmg 就是新的 cdhash、又得再送一次。所以順序只能是「先釘 .app，再拿釘好
# 的去打 dmg」。
#
# 交出去的是 zip 而不是 .app 本身：notarytool 只吃 zip／dmg／pkg。zip 只是運輸
# 工具，**票是釘在 .app 上**，所以送完就丟。要用 `ditto -c -k --keepParent` 而
# 不是 `zip`——後者不保留 symlink 與 extended attributes，簽章會在 Apple 那側驗不過。
APP_ZIP="${ROOT}/build/tatami-${VERSION}-${SHA}-app.zip"
rm -f "${APP_ZIP}"
ditto -c -k --keepParent "${APP}" "${APP_ZIP}"
notarize "${APP_ZIP}" ".app"
rm -f "${APP_ZIP}"

say "7／12 staple .app"
xcrun stapler staple "${APP}"
# 立刻斷言，不要等到第 11 步：這一步失敗的話，後面打出來的 dmg 裡是一份沒有票的
# .app，而那個 dmg 自己的票會讓 9／12 與 10／12 看起來一切正常。
# 票寫進 Contents/CodeResources，不在簽章封印範圍內——釘票前後 cdhash 相同。
check "stapler validate app（票真的釘上去了）" xcrun stapler validate "${APP}" \
    || die "票沒釘上 .app。繼續下去會打出一個內含無票 .app 的 dmg。"

say "8／12 打包 dmg"
# 為什麼交給使用者的是 dmg 不是 zip：**zip 不能 staple**。使用者拿到的那個容器
# 自己要有票，否則離線連掛載都可能被擋。
DMG="${ROOT}/build/tatami-${VERSION}-${SHA}.dmg"
rm -f "${DMG}"
ln -sfn /Applications "${STAGE}/Applications"
hdiutil create -volname "tatami ${VERSION}" -srcfolder "${STAGE}" \
    -ov -format UDZO "${DMG}" >/dev/null
codesign --force --timestamp --sign "${IDENTITY}" "${DMG}"
ok "$(basename "${DMG}")"

say "9／12 notarize dmg（第二次等 Apple）"
notarize "${DMG}" "dmg"

say "10／12 staple dmg"
xcrun stapler staple "${DMG}"

say "11／12 驗收"
require_gatekeeper_on
verify_dmg "${DMG}" || die "驗收沒過，不打 tag。"
ok "八道全過"

say "12／12 tag"
git -C "${ROOT}" tag -a "v${VERSION}" -m "tatami ${VERSION}"
ok "v${VERSION}（**還沒推**）"

SHA256="$(shasum -a 256 "${DMG}" | awk '{print $1}')"
cat <<SUMMARY

────────────────────────────────────────────────────────────
  ${VERSION} @ ${SHA}   build ${BUILD_NUMBER}
  $(basename "${DMG}")

  接下來（都還沒做）：
    在公開 repo 上重新打 tag 並發 release（見 stage-B plan 的 Task 8）

  cask 要填的兩個值：
    version "${VERSION},${SHA}"
    sha256  "${SHA256}"
────────────────────────────────────────────────────────────
SUMMARY
