# tatami

macOS 的視窗管理工具：**每個 space 各有一份版面**，切過去自動排好。
格線面板、⌥ 拖曳吸附、45 組可改的快捷鍵，一個常駐的選單列 app。

不需要 yabai、不需要 skhd、不需要關 SIP。

> 示範圖之後補。舊的那幾個是 2021 年錄的，那時視窗管理全部是 yabai 在做，
> 已經不是現在的樣子了。

## 安裝

```sh
brew tap mikimoto/tatami
brew trust mikimoto/tatami
brew install --cask tatami
```

**中間那行不能省。** Homebrew 7 起，第三方 tap 的 cask 預設不給裝，少了它會停在
`Refusing to load cask ... from untrusted tap`。

需要 macOS 14（Sonoma）以上。裝完會有 `/Applications/Tatami.app` 與一個在 PATH 上的
`tatami`——兩者是**同一個執行檔**，所以 CLI 與選單列 app 不可能版本不一致。

<details>
<summary>從原始碼建</summary>

```sh
git clone https://github.com/Mikimoto/tatami "${HOME}/Developer/tatami"
cd "${HOME}/Developer/tatami"
mise run install   # 建 tatami 並接到 ~/.local/bin
mise run app       # 建、簽、裝 ~/Applications/Tatami.app
```

這樣裝的是 ad-hoc 簽章的版本，**每次重建都要重新給一次「輔助使用」權限**——
那個授權釘在簽章上，而 ad-hoc 簽章的身分就是執行檔的雜湊。用 cask 裝的那份是
Developer ID 簽的，更新撐得過去。
</details>

然後到「系統設定 → 隱私權與安全性 → 輔助使用」把 Tatami 打開，**再重開一次 app**
（TCC 不會套用到已經在跑的行程）。

`mise run doctor` 會說環境缺什麼。除了 Swift（來自 Xcode）之外只有兩個外部工具，
兩個都是選配：`jq` 只有 `mise run test` 的其中三組對照要用，`fzf` 只有互動式的
`tatami --switch` 要用，沒裝它會自己說替代辦法。

## 這是什麼

| | |
|---|---|
| **每個 space 一份版面** | `spaceTrees`：切到哪個 space 就排哪一份，不在版面裡的視窗一概不碰 |
| **格線面板**（⌃⌥⌘G） | 縮圖上拖一個矩形，視窗就排到螢幕上對應那一塊。另有位置庫模式 |
| **⌥ ＋ 拖曳** | 搬視窗；⌥ ＋ 右鍵拖曳縮放。拖曳時浮出吸附區，放開就吸進去 |
| **45 組快捷鍵** | 焦點、搬移、縮放、跨 space／螢幕。`tatami edit` 的「快捷鍵」頁改 |
| **圖形編輯器** | `tatami edit`：拖拉畫版面、編規則、設格線 |

## 設定

住在 `~/.config/tatami/`，**不在這個 checkout 裡**——刪掉 repo 設定不會不見：

```
layout.json      版面：地點 → profile → 每個 space 一棵樹
hotkeys.json     快捷鍵、格線、位置庫（預設不存在，那時用內建的 45 組）
.tatami-state    地點覆寫、各地點記住的 profile、學到的頂端 inset
```

`examples/layout.json` 是一份可以直接抄的範本。改完用 `tatami validate` 檢查。

**地點**（`home`／`office`）靠螢幕 UUID 自動偵測，**profile**（`開發`／`會議`）
由你指定——同一組螢幕可以有好幾套版面。

## 需要的權限

**輔助使用**（系統設定 → 隱私權與安全性 → 輔助使用）。它要用 Accessibility API
移動別的 app 的視窗，沒有別的辦法。

不需要「輸入監控」，也不需要關 SIP。

## 常用命令

```sh
tatami --space          # 排目前可見的 space
tatami --space --all    # 排每一個有版面的 space（拔插螢幕之後用這個）
tatami --save [profile] # 把目前排版存進設定（要從終端機跑，它會問視窗名稱）
tatami edit             # 圖形編輯器
tatami validate         # 檢查設定
```

裸打 `tatami`（不帶參數）從終端機跑會印用法字串；`Tatami.app` 沒有參數則是進
選單列模式。

## 開發

```sh
mise run test    # 單元測試 ＋ 2257 組語料 ＋ 3 組 jq 對照
mise run lint    # swiftformat ＋ swiftlint
mise run smoke   # 對真的 AX／osascript／檔案系統（唯讀）
mise run doctor  # 環境檢查
```

架構是五層：`CLI → Adapters → Core → Domain`、`Wire → Domain`。Domain 零 import、
編輯器那三層互不越界，兩條都由 `WorkmodeArchitectureTests` 掃原始碼在守；
「Core 一個字都不格式化」是慣例，沒有測試守它。
`CLAUDE.md` 記著這個 repo 的慣例與那些「讀程式碼看不出來、踩到會浪費時間」的實測。

`docs/guide.html` 是給使用者看的繁中操作說明，但它**停在 2026-09-03**，內容還在講
yabai 與設定搬家之前的路徑——要用它之前先對照 `CLAUDE.md`。

## 歷史

這個工具原本是 1377 行 bash（那時叫 `workmode`），2026-08 移植成 Swift。
bash 那份凍在 `bash-oracle` 這個 tag，`tests/golden/` 的 2257 組語料就是從它錄的
——想知道「原本是怎麼做的」，看那裡：

```sh
git show bash-oracle:scripts/workmode.sh
```

yabai 與 skhd 2026-09-14 從作者的機器移除，設定 2026-09-15 從 repo 搬到
`~/.config/tatami/`。`yabai/yabairc` 與 `skhd/skhdrc` 留在 repo 裡當歷史紀錄，
沒有任何東西讀它們。

## 授權

Apache-2.0
