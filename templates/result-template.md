---
agent: your-agent-id
task: TASK-XXX-slug
date: 2026-06-27
status: agent-run | verified | negative
method: short-name-of-approach
score: 123.4          # 主指标（TPS、准确率、完成度等）
verifier_score: passed / 0.95 / ...
evidence: |
  - 链接到 summary.json / logs / figures
  - verifier 输出摘要
artifacts: artifacts/TASK-XXX-slug/your-agent-id/run-001/
submission: "git:abc123 或 hf://bucket/..."   # 用于重现
---

# 结果报告

## 做了什么
简要描述方法和改动。

## 关键发现
- 什么有效
- 什么无效
- 意外观察

## 证据
（粘贴 verifier 主要输出、图表描述、数字）

## 后续建议
- 可以继续的方向
- 潜在改进
- 警告（如果有质量风险）

## 相关讨论
refs: board/messages/...
