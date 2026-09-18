# 100 Desktop UI & Shader Demos

A curated collection of 100 desktop UI components, interactive effects, and shaders for macOS/iOS built with SwiftUI & Metal.

基于 **SwiftUI + Metal (MSL)** 开发的 100 个桌面端交互特效与 UI 组件合集。单仓多项目（Monorepo）结构，每个 Demo 独立成 folder、互不依赖。

## 环境要求

- macOS 14+
- Xcode 15+（Metal 无需 Toolchain，shader 为运行时编译的 MSL 字符串）

## Demo 清单

| 序号 | Demo 名称 | 技术栈 / 核心亮点 | 预览 | 代码路径 |
| :---: | :--- | :--- | :---: | :---: |
| **001** | 黑洞引力回收站 | Metal Shader、潮汐撕裂、吸积盘流场、统一遮挡场 | ![preview](./001-black-hole-trashcan/preview.gif) | [查看源码](./001-black-hole-trashcan/) |
| **002** | … | … | … | … |

## 工作流

1. 新建 `NNN-demo-name/` 文件夹，放入独立 Xcode 工程或 Playground；
2. 在 demo 目录内放一张 `preview.gif`（录制实际运行效果）；
3. 在根目录 README 的清单表格中加一行。

---

每个 Demo 均为独立实验性质，代码可自由取用。
