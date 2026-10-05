# 第三方组件与素材

本项目（泡泡 · Bloop，桌面「随时指导」桌宠）**自身**的代码、提示词、文档与自绘素材以
**PolyForm Noncommercial License 1.0.0** 发布（非商业免费，商用需授权），见 [LICENSE](LICENSE)。
但它运行时会借用、或历史上借用过下面这些第三方东西，它们各有各的授权，**不受本项目许可覆盖**。

## 运行时借用（不随本项目分发）

| 组件 | 授权 | 我们怎么用它 |
|---|---|---|
| **DeepSeek Harness**（`dsh` 可执行文件、`app.asar` 内的运行时与插件） | 见其自身发布条款 | 桌宠的"大脑"和语音识别都借它的运行时；**不复制、不打包**，只在运行期调用本机已安装的实例 |
| **sherpa-onnx**（`sherpa-onnx.node`） | Apache-2.0 | 语音识别（STT）的原生推理；由 DSH 发行包提供 |
| **FunASR SenseVoiceSmall 模型**（`model.int8.onnx`，约 228MB） | [FunASR 模型开源协议](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE) | STT 的模型权重；**不随本项目分发**，首次使用时按需下载到 `.stt/model/` |
| **Node.js** | MIT | 跑 STT 的 `.cjs` 需要一个普通 node（不能用 Electron 的 RUN_AS_NODE，见 `stt-sensevoice.cjs` 注释） |
| **Microsoft Edge** | 微软条款 | 对话窗口用它的 `--app=` 无地址栏模式显示 DSH 自己的 Web 界面 |
| **Electron**（重写版） | MIT | `desktop-pet/` 的运行时 |

## ⚠️ 角色形象：随仓库分发，但**不主张所有权**

仓库里带着两份同一个文件：`desktop-guide/assets/pet.png` 与 `desktop-pet/assets/pet.png`
（610×610，带透明通道）。它们就是桌宠默认用的那张脸。

**这张图不在本项目的许可范围内。** PolyForm Noncommercial 1.0.0 覆盖的是代码、提示词、文档与
**自绘**素材；这张图**不适用**那份许可，作者**不对它主张任何权利**，也不声称它属于本项目，
更没法替它对外授权。完整声明：[`desktop-guide/assets/PROVENANCE.md`](desktop-guide/assets/PROVENANCE.md)。

**它从哪来**：最初取自本机已装的 `dsh-whale-widget` 插件的 `assets/DSniang1.png`。
那份插件的**代码是 MIT**，但它的 `PROVENANCE.md` 对 `assets/**` 写的是
「由维护者提供或使用 AI 工具生成，按 **as-is** 随插件分发，**仅用于运行本插件**；
**不授予再许可**，也不声明为原创作品」。

本仓库维护者认为它属于**网上流传的表情包 / AI 生成图，原始出处无法考证** ——
于是选择：**放进来用，但不写作者、不写来源、不声明版权、不收费**，
并接受"权利人一句话就撤"的约束。

**权利人怎么主张**：开一条 issue 说明**文件名**与**依据**，我们核实后**立即替换或移除**，
不附加任何条件。也欢迎直接提供可自由再分发的替代素材。

**想换成自己的图**：覆盖这两个 `assets/pet.png` 即可（两个版本都会优先用它）；
桌面宠的 `config.json` 里 `petImage` 也可以指到任意一张带透明通道的 PNG。

## 参考过的项目

设计上参考过 [Coopanion](https://github.com/Pal-AI-Lab/Coopanion)（AGPL-3.0）与
[Cortico](https://github.com/Pal-AI-Lab/Cortico)（MIT）的公开实现思路
（路径与供应商表、事件投递语义、自研 Live2D 式渲染器）。

**只借思路，没有复制代码** —— Coopanion 是 AGPL-3.0，抄代码会把本项目也传染成 AGPL。
如果你打算并入它的任何代码，请先确认许可证兼容性。
