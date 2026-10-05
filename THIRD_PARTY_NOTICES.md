# 第三方组件与素材

本项目（桌面「随时指导」桌宠）**自身**的代码以 MIT 发布，见 [LICENSE](LICENSE)。
但它运行时会借用、或历史上借用过下面这些第三方东西，它们各有各的授权，**不受本项目 MIT 覆盖**。

## 运行时借用（不随本项目分发）

| 组件 | 授权 | 我们怎么用它 |
|---|---|---|
| **DeepSeek Harness**（`dsh` 可执行文件、`app.asar` 内的运行时与插件） | 见其自身发布条款 | 桌宠的"大脑"和语音识别都借它的运行时；**不复制、不打包**，只在运行期调用本机已安装的实例 |
| **sherpa-onnx**（`sherpa-onnx.node`） | Apache-2.0 | 语音识别（STT）的原生推理；由 DSH 发行包提供 |
| **FunASR SenseVoiceSmall 模型**（`model.int8.onnx`，约 228MB） | [FunASR 模型开源协议](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE) | STT 的模型权重；**不随本项目分发**，首次使用时按需下载到 `.stt/model/` |
| **Node.js** | MIT | 跑 STT 的 `.cjs` 需要一个普通 node（不能用 Electron 的 RUN_AS_NODE，见 `stt-sensevoice.cjs` 注释） |
| **Microsoft Edge** | 微软条款 | 对话窗口用它的 `--app=` 无地址栏模式显示 DSH 自己的 Web 界面 |
| **Electron**（重写版） | MIT | `desktop-pet/` 的运行时 |

## ⚠️ 素材：不能随本项目分发

`desktop-guide/` 在**没有自绘素材**时会兜底用本机已安装的
`dsh-whale-widget` 插件里的 `assets/DSniang1.png`（鲸鱼形象）。

那个插件的**代码是 MIT，但 `assets/**`（图片、动图、音效）明确不在 MIT 覆盖范围内** ——
其 `PROVENANCE.md` 写明「按 as-is 随插件分发，**仅用于运行本插件**，不授予再许可」。

所以：

- **本机自用**：没问题，兜底路径就是为了这个。
- **对外分发**（发仓库、打安装包、发布 Release）：**必须换成你自己拥有或可再分发的素材**。
  把自绘图放进 `desktop-pet/assets/pet.png`（重写版）或 `desktop-guide/assets/pet.png`（原版），
  它会**优先于**鲸鱼被采用。仓库里**不含**任何鲸鱼素材，也不应该加进去。

## 参考过的项目

设计上参考过 [Coopanion](https://github.com/Pal-AI-Lab/Coopanion)（AGPL-3.0）与
[Cortico](https://github.com/Pal-AI-Lab/Cortico)（MIT）的公开实现思路
（路径与供应商表、事件投递语义、自研 Live2D 式渲染器）。

**只借思路，没有复制代码** —— Coopanion 是 AGPL-3.0，抄代码会把本项目也传染成 AGPL。
如果你打算并入它的任何代码，请先确认许可证兼容性。
