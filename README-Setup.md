# 零成本安装指南（Windows 无 Mac）

目标：GitHub + Codemagic 云构建出 ipa → 另一台 Windows 电脑用 AltServer 装进 iPhone。
全程 0 元，App 每 7 天需续签一次。

---

## 第一步：创建 GitHub 仓库并推送代码

1. 注册/登录 GitHub（github.com），点右上角 "+" → "New repository"。
   - 名称：`watch-ai-recorder`（随便起，但**必须选 Public 公开**，Codemagic 免费额度才够用）
   - 其他默认，点 "Create repository"。
2. 创建后页面会显示仓库地址，形如 `https://github.com/你的用户名/watch-ai-recorder.git`。
3. 在本机把 `app/` 目录推送上去：

```
cd C:\Users\CPR429\WorkBuddy\2026-10-29-16-55-52\watch-ai-recorder\app
git remote add origin https://github.com/你的用户名/watch-ai-recorder.git
git push -u origin main
```

（push 时会弹出 GitHub 登录窗口，按提示用浏览器授权即可）

---

## 第二步：Codemagic 云构建（产出未签名 ipa）

1. 打开 codemagic.io，点 "Sign up with GitHub" 用 GitHub 账号登录（免费）。
2. 授权仓库访问后，在 Applications 列表找到 `watch-ai-recorder`，点 "Set up workflow"。
3. 配置页：
   - **Project type** 选 "Flutter App or other"（我们是自定义 YAML 工作流）；
   - 如果它检测到 `codemagic.yaml`，直接选择 workflow **`ios-unsigned`**；
   - macOS Machine 选默认的 Apple Silicon；
   - 点右上角 "Start build"。
4. 等 5-15 分钟，构建成功后页面出现 Artifacts，下载 **PhoneApp-unsigned.ipa** 存到电脑。
5. 如果构建失败：点进日志，把报错部分复制下来，交给 AI 修复（或发给 WorkBuddy）。

> 免费额度 500 分钟/月，单次构建约 10 分钟，足够每月 30+ 次。

---

## 第三步：在另一台 Windows 电脑上安装 AltServer

1. 先装苹果驱动（二选一，推荐前者）：
   - 微软商店搜 "Apple Devices" 安装（Win11 推荐）；
   - 或从苹果官网下载安装 iCloud for Windows（自带驱动）。
2. 到 altstore.io 下载 **AltServer for Windows**，解压运行安装。
3. iPhone 用**数据线**连到这台电脑（首次连接手机上点"信任"）。
4. 右键任务栏托盘里的 AltServer 图标 → "Install AltStore" → 选择你的 iPhone →
   输入你的普通 Apple ID 和密码（这是苹果官方签名机制，只在本机使用，AltStore 是开源软件）。
5. iPhone 上出现 **AltStore** 图标即成功。
   （如果提示"不受信任的开发者"：设置 → 通用 → VPN与设备管理 → 信任你的 Apple ID）

---

## 第四步：用 AltStore 安装我们的 App

1. 把 Codemagic 下载的 `PhoneApp-unsigned.ipa` 拷到这台电脑。
2. 在 iPhone 的 AltStore 里：**My Apps → 右上角 "+"** → 选择这个 ipa 文件
   （通过电脑上 AltStore File Provider 或 iTunes 文件共享传入；最简单是用 iPhone 自带"文件"App 从 AirDrop/微信文件导入后选择）。
   > 更省事的办法：ipa 放到电脑上后，右键托盘 AltServer 图标 → "Sideload .ipa" → 选文件 → 选 iPhone，一步到位。
3. 等安装完成，iPhone 上出现 **"录音助手"** App。
4. 首次打开"转写验证"时按提示允许：语音识别 + 麦克风两个权限。

---

## 验收 M1

找一个 1-5 分钟的中文音频（比如微信语音导出、手机录的一段话，转成 m4a 或直接选音频文件），
在 App 里选择它 → 等待转写 → 屏幕显示出中文文本即为 **M1 通过**。
转写文本可以直接全选复制。

---

## 注意事项

| 事项 | 说明 |
|---|---|
| 7 天过期 | 免费签名 7 天有效。iPhone 和电脑同一 Wi-Fi 时打开 AltStore 会自动续签；过期前重新侧载 ipa 也可以 |
| 3 App 上限 | 免费 Apple ID 同时最多 3 个自签 App，删掉不用的即可 |
| 语音识别走服务器 | 少数老设备不支持本机识别，App 会自动回退到苹果服务器识别（仍免费，但音频会上传给苹果） |
| 下一步 | M1 验收通过后，购入 Apple Developer（¥688/年），用《无Mac开发流程.md》六A节提示词加回手表功能 |
