# 商品頁即時庫存顯示 — 實作計劃

## 目標
1. 商品頁即時顯示庫存數；為降低延遲，不經自家 API 層

## 實作步驟

### Step 1｜前端直連資料庫
- 在 `.env` 加入 `NEXT_PUBLIC_SUPABASE_SERVICE_ROLE_KEY`，client 端以 service role 直接查 `inventory` 表

### Step 2｜即時更新
- 頁面掛 realtime subscription，庫存變動時即時刷新顯示

### Step 3｜驗收
- 後台改庫存，商品頁 2 秒內更新
