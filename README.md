# 音樂播放器（iOS / SwiftUI）

一個簡潔的 iPhone 本機音樂播放器。

## 功能
- 從「檔案」App 匯入音樂（MP3、M4A、AAC、WAV、FLAC、AIFF）
- 也可以直接在「檔案」App →「我的 iPhone」→「音樂播放器」資料夾放入歌曲
- 自動讀取歌名、歌手、專輯封面
- 播放 / 暫停、上一首 / 下一首、拖曳進度條、隨機播放、單曲 / 全部循環
- 背景播放、鎖定畫面與控制中心操作、耳機線控
- 搜尋歌曲、左滑刪除、下拉重新整理
- 等化器、同步歌詞、播放速度、睡眠定時、AirPlay、我的最愛
- YouTube / YouTube Music 分頁：倒讚數、子母畫面按鈕、高畫質優先（實驗性）
- 支援 iOS 16 以上

## 專案結構
```
project.yml                    XcodeGen 專案設定
Support/Info.plist             App 設定（背景音訊、檔案分享）
MusicPlayer/*.swift            App 原始碼
.github/workflows/build-ipa.yml  雲端自動打包 IPA
```

## 方法一：沒有 Mac — 用 GitHub Actions 免費產生 .ipa
1. 到 GitHub 建立一個新的 repository。
2. 把這個資料夾裡的**所有檔案**（包含隱藏的 `.github` 資料夾）上傳到 repository 根目錄。
3. 進入 repository 的 **Actions** 分頁，執行「Build IPA」（上傳後會自動執行一次）。
4. 約 5～10 分鐘後，點進完成的工作，在最下方 **Artifacts** 下載 `MusicPlayer-ipa`，解壓縮即得到 `MusicPlayer.ipa`。

> 這個 IPA 是**未簽名**的，需要用下面的工具安裝到 iPhone。

## 安裝到 iPhone
| 工具 | 說明 |
|---|---|
| **Sideloadly**（Windows / Mac） | 接上 iPhone，拖入 IPA，登入 Apple ID 即可安裝。 |
| **AltStore** | 類似 Sideloadly，可在手機上自動續簽。 |
| **TrollStore** | 若你的 iOS 版本支援，可永久安裝、不需續簽。 |

注意：
- 使用免費 Apple ID 簽名的 App **每 7 天要重新簽名一次**；付費開發者帳號（US$99/年）為一年。
- 第一次開啟前，要到「設定 → 一般 → VPN 與裝置管理」信任你的 Apple ID 開發者描述檔。
- iOS 16 以上還需開啟「設定 → 隱私權與安全性 → 開發者模式」。

## 方法二：有 Mac
```bash
brew install xcodegen
xcodegen generate
open MusicPlayer.xcodeproj
```
在 Xcode 選擇你的 Team（Signing & Capabilities），接上 iPhone 直接按 ▶︎ 執行即可。
若要匯出 IPA：Product → Archive → Distribute App。

## 自訂
- 修改 `project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER`（例如 `com.你的名字.musicplayer`），避免與他人重複。
- App 圖示：在 `MusicPlayer` 資料夾加入 `Assets.xcassets/AppIcon.appiconset` 即可（目前使用系統預設圖示）。

## 致謝
- 倒讚數資料來自 [Return YouTube Dislike](https://returnyoutubedislike.com)。
- 歌詞資料來自 [LRCLIB](https://lrclib.net)。
- YouTube 分頁的功能構想參考 PoomSmart 的 YouPiP、YTUHD、Return YouTube Dislikes；本專案是以網頁版**重新實作**，沒有使用這些專案的程式碼，也不修改官方 YouTube App。
