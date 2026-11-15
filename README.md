# PiliProbe

PiliPlus 卡在啟動 logo 時的診斷插件。只會作用在名字含 "pili" 的 App，其他 App 不受影響。

## 取得 deb
1. 把整個資料夾（含隱藏的 .github）上傳到你自己的 GitHub 倉庫。
2. 到倉庫的 Actions 頁面，等 "Build deb" 跑完。
3. 點進那次執行，在最下面 Artifacts 下載：
   - PiliProbe-rootless：給 Dopamine（無根越獄）
   - PiliProbe-roothide：給 roothide 環境（這一個是未驗證的）
4. 解壓得到 .deb，用 Filza 或越獄包管理器安裝，再註銷（respring）。

## 使用
1. 打開 PiliPlus，讓它卡在 logo。
2. 等 15 秒，會彈出視窗，完整日誌已自動複製到剪貼簿。
3. 到 Claude 對話框貼上，或截圖視窗內容。
4. 若沒有彈窗，日誌檔在該 App 的 Documents/piliprobe.log。

診斷完之後記得把插件移除。
