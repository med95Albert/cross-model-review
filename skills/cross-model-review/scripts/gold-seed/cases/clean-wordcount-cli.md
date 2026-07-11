# 新建文字統計小工具 wordcount.py — 實作計劃

## 目標
1. 新建命令列工具 `wordcount.py`（本計劃新建，零相依、不依賴任何既有程式碼）：讀取一個 UTF-8 文字檔路徑參數，輸出行數、詞數（空白分隔）、字元數
2. 檔案不存在或不可讀時，印出清楚錯誤訊息到 stderr 並以非零代碼結束

## 實作步驟

### Step 1｜參數與讀檔（新建 wordcount.py）
- 只用標準庫（argparse）；接一個位置參數 `file`
- 以 `encoding="utf-8", errors="replace"` 讀檔

### Step 2｜統計與輸出
- 行數＝`splitlines()` 長度；詞數＝`split()` 總數；字元數＝`len(text)`
- 輸出固定一行：`lines=<n> words=<n> chars=<n>`

### Step 3｜錯誤處理
- 任何開檔／讀檔失敗（以 `except OSError` 總類承接，涵蓋不存在、權限不足、路徑是目錄等）→ stderr 印 `wordcount: 無法讀取 <路徑>: <原因>`，exit code 2，stdout 不輸出
- 解碼問題不會拋錯（Step 1 已用 `errors="replace"`）

### Step 4｜驗收
- 對一個三行測試檔執行 → 三個數字正確
- 對不存在的路徑執行 → stderr 有訊息、exit code 2、stdout 無輸出
