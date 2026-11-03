# 工作日志

## 2026-11-03（Windows 机器）

### v0.4.2 验收通过（20:52 真机日志）—— M2 总结功能收工
- 同一条 45.8s 录音：转写 148 字 → DeepSeek 3 秒 → 6 条要点、5 条待办
- 待办规则修复生效：上版只有 2 条，本版含季度三项工作共 5 条，每条带时间节点
- `cleanTranscript` 完全达标：全文补齐标点、正确分句；错字修正生效（「整理成绩」→「整理成纪要」、「控在」→「控制在」、「下月15日15号」→「下月15号」），序号「第一/第二/第三」恢复
- 残留小瑕疵（均为转写阶段丢字、模型不编造所致，属合理保守）：「散会之后」→「之后」、「会议纪要」→「会议内容」
- 决策：暂不用本地模型替换 DeepSeek（Google AI Edge Gallery 不对外暴露推理接口；3GB 模型需付费开发者账号的内存 entitlement，免费签名会 OOM）

### M2 端到端跑通（20:33 真机日志）
- 设置页保存 DeepSeek Key（35 位）→ 转写 45.8s 得 148 字（比无标点版本多 5 字，标点生效）→ 3 秒生成 5 条要点、2 条待办
- 问题：① 标点仍稀疏（`addsPunctuation` 只补了少数逗号）；② 待办只提取 2 条，季度三项工作没算进去

### v0.4.2 改进（b91dafa）
- 让模型在同一次调用里额外返回 `cleanTranscript`：补标点、分句、修错字（如「整理成绩」→「整理成纪要」），不加成本
- 待办规则收紧：有明确交付物或时间节点的事项都要列（含规划中的工作），同一件事合并
- SummaryView 新增「校对后全文」分区 + 复制按钮，原始转写收进 DisclosureGroup 备查
- Markdown 导出增加「## 会议全文」段

### M1 验收通过（20:14 真机日志）
- 45.8 秒录音 → 切 2 段（0–30s / 30–45s）→ 服务器识别 100 字 + 43 字 → 合计 143 字，每段 <1 秒
- 截断问题解决，转写主链路可用

### M2 第一步：AI 会议纪要（v0.4.0，DeepSeek）
- 新增 `Utils/KeychainStore.swift`：API Key 存钥匙串（不落 UserDefaults）
- 新增 `Services/SummaryService.swift`：调用 `https://api.deepseek.com/chat/completions`（deepseek-chat，temperature 0.2，response_format=json_object），要求模型输出 `{title, summary, keyPoints[], todos[]}`；解析做三级容错（去 ```json 包裹 → 截取首尾大括号 → 解码失败则原文兜底）；错误按 401/402/429 给中文提示；`verifyKey` 走 `/models` 校验，不消耗 token
- 新增 `Views/SummaryView.swift`：标题/概述/要点/待办分区展示，底部生成按钮，支持复制 Markdown、ShareLink 分享
- 新增 `Views/AISettingsView.swift`：填写/保存/校验/删除 Key，附成本说明
- 改动：TranscribeTestView 转写完成后出现「生成会议纪要」入口；SettingsView 顶部加 AI 设置入口；版本 0.4.0

### 修正：转写服务放错位置 + 编译错误
- 远端 `1a21265` 在**仓库根目录**上传了新版 `TranscriptionService.swift`（v0.2.1 策略：服务器优先 / 30s 分段 / 每段截断复检），但 `project.yml` 的 sources 只包含 `PhoneApp`，根目录文件**不参与编译**；且其中 `objc_setAssociatedObject(request, NSObject(), ...)` 的 key 类型错误，编译必失败
- 已在 `cf6b5e1` 中修正：
  - 新版逻辑合并进 `PhoneApp/Services/TranscriptionService.swift`，删除根目录副本
  - 用内部类 `RecognitionBridge`（NSLock 保护 + 强引用 task）替换 objc 关联对象
  - 新增识别超时保护（`max(20, length*3+10)` 秒），避免回调不触发时界面卡死
  - 服务器识别结果偏短时也用本机识别复检，取更完整者
  - 版本号 0.3.1，更新权限说明与首页版本文案

## 2026-11-02（Windows 机器）

### 已完成
- 用 v0.1（Codemagic 构建 + AltStore 侧载）在 iPhone 16 上完成 M1 初步验证：转写链路通，但 40 秒录音只识别出最后 14 个字（"之后请小王把会议纪要发给全体成员"）——苹果语音识别单次请求约 1 分钟上限 + on-device 文件转写截断 bug
- 修复 1（7268be8）：免费 Apple ID 签名拒绝中文 App 显示名。project.yml 的 CFBundleDisplayName 由「录音助手」改为 Recorder
- 修复 2（d8ef03c，v0.2.0）：
  - TranscriptionService 长音频自动分段（>45s 切成 45s 段逐段转写拼接）
  - 疑似截断自动复检：结果字数远低于时长应有字数时，自动改用苹果服务器识别重跑，取更完整结果
  - 日志新增「音频时长 X 秒」输出
- 两个提交均已推送到 origin/main

### 待办（下次继续）
1. Codemagic 重新 Start build（ios-unsigned 工作流）→ 下载新 ipa → AltServer Shift+左键 Sideload 覆盖安装
2. 用「新录音 6.m4a」复测：看日志里音频时长和最终字数，验证分段转写修复
3. M1 通过后进入下一阶段讨论：App 内录音、AI 总结（需接 LLM API）、历史记录持久化、手表端

### 已知坑（跨机器通用）
- AltServer（Windows）右键没有 Sideload .ipa，需 **Shift+左键**点托盘图标
- 免费签名 7 天过期，手机电脑同 Wi-Fi 打开 AltStore 点 Refresh 续签
- 只支持 m4a 导入；微信语音 amr/silk 未支持
- objc_setAssociatedObject 用字符串字面量当 key，建议换 static 变量（未改）
