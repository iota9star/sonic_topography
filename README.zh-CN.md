<p align="center">
  <img src="assets/icon/app_icon.png" width="128" alt="Sonic Topography logo" />
</p>

<h1 align="center">Sonic Topography 声波地形</h1>

<p align="center">
  <img src="https://img.shields.io/badge/platforms-macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20Android%20%7C%20iOS-blue" alt="platforms" />
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license" />
</p>

基于 Flutter + Impeller 片元着色器的 GPU 音频可视化：把音乐变成一颗旋转的
"声波星球"——方块柱地形随节拍抬升、发光、泛起涟漪，还有流星、粒子与悬浮
水晶方块。整个场景在单个显示 pass 中渲染，高度场异步烘焙，CPU 每帧只推
约 30 个 uniform。

## 特性

- **单 pass GPU 渲染** —— 柱状地形、雾、流星、粒子、悬浮方块全部在一个
  片元着色器里完成（`CustomPaint` + 2D DDA 光线步进）。地形高度烘焙到
  一张小纹理，不在关键路径上。
- **真实音频分析** —— 自写 radix-2 FFT 产出 8 个频段，映射到 dB 标度
  （−75 dBFS 噪声门 / 45 dB 窗口），配合底鼓包络跟随器和谱通量触发器
  （灵敏度 / 冷却 / 频段 / 强度可调，高级模式可在实时频谱上拖十字准星）。
- **18 套内置主题** —— 精确的 linear 着色器配色，支持主题自动轮换；地面
  EQ 混音台可重塑各频段对地形的驱动。
- **自适应画质** —— 画质优先：默认按设备全分辨率渲染，在满足屏幕刷新率
  的前提下逐步上探超采样，只有真正掉帧时才降分辨率。
- **响应式界面** —— 从手机到桌面布局自适应，右侧官方抽屉承载全部设置，
  并有多尺寸自动化布局测试保障。

## 平台

macOS / Windows / Linux 桌面级渲染（Impeller / Metal / Vulkan），Android /
iOS 支持触控。不支持 Web。

## 快速开始

```bash
fvm flutter pub get
fvm flutter run -d macos   # 或 windows / linux / 已连接的设备
```

跑测试（着色器编译、布局、触发器数学、频段范围）：

```bash
fvm flutter test
```

## 操作说明

- **音频源** —— DEMO（内置合成器）、MUSIC（从系统对话框选择音频文件）、
  MIC（麦克风实时输入，dB 标度归一化）。
- **设置抽屉**（右侧边缘滑入，或点顶栏主题胶囊）：
  - *音频源* —— DEMO / MUSIC / MIC 三个切换标签就在这里。
  - *主题* —— 18 套预设点按切换，可开启自动轮换。
  - *场景* —— 发光强度、幅值、柱宽 / 间距、旋转速度、地形密度
    （每边 96–224 格）。
  - *悬浮方块* —— 随底鼓膨胀的水晶方块，强度 / 大小 / 速度 / 数量可调。
  - *脉冲 / 流星触发器* —— 谱通量检测，可调灵敏度、冷却、FFT 频段与
    强度；高级模式在实时频谱上拖动十字准星瞄准。
  - *地面 EQ* —— 8 频段混音台，调整每个频段对地形的抬升。

## CI 与发布

每次 push 会通过 GitHub Actions 构建全部支持的平台（Android APK、未签名
iOS IPA、macOS 应用、Windows / Linux 打包）并发布到 GitHub Release。
Android 产物使用仓库内提交的调试密钥签名，可直接安装；上架分发请替换为
自己的正式签名。

## 目录结构

```
lib/
  main.dart                     # 应用外壳、界面层、抽屉面板
  src/sonic_shader_controller.dart  # uniform 打包、tick 循环、烘焙管线
  src/scene/scene_state.dart    # 涟漪、流星、粒子、悬浮方块
  src/audio/                    # FFT、频段提取、节拍与频率触发器
  src/theme/sonic_theme.dart    # 18 套内置配色
shaders/
  sonic_topography.frag         # 显示 pass（DDA 光线步进 + 着色）
  sonic_heightfield.frag        # 异步烘焙 pass
test/                           # 布局、色彩、触发器与着色器测试
```

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。
