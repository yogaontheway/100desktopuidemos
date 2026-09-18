# 100 Desktop UI & Shader Demos

[![Build](https://github.com/yogaontheway/100desktopuidemos/actions/workflows/build.yml/badge.svg)](https://github.com/yogaontheway/100desktopuidemos/actions/workflows/build.yml)

A curated collection of 100 desktop UI components, interactive effects, and shaders for macOS/iOS built with SwiftUI & Metal.

基于 **SwiftUI + Metal (MSL)** 开发的 100 个桌面端交互特效与 UI 组件合集。单仓多项目（Monorepo）结构，每个 Demo 独立成 folder、互不依赖。

## 环境要求

- **Xcode 27+** / macOS 26.6+（工程由 Xcode 27 保存，project file format 110，低版本 Xcode 无法打开）
- Metal 无需 Toolchain，shader 为运行时编译的 MSL 字符串

## CI

每次 push 到 main 以及每个 PR 都会自动编译仓库内所有 Xcode 工程 / Swift 包（`.github/workflows/build.yml`，跑在 `xcode-27` 镜像上）。新增 Demo 无需改配置，会自动被发现。

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
