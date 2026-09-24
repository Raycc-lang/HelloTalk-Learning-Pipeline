# HelloTalk 学习流水线

一条自动化的 7 阶段流水线：从 HelloTalk 语言交换 App 中提取语音消息，用 Whisper 转写，用 LLM 分析语法与词汇，构建限时 4/3/2 流利度训练，并生成 Anki 闪卡，用于有针对性的语言学习。

面向母语为中文的中级 ESL 学习者，也可适配任意语言对。

[English](README.md) | [中文](README.zh-CN.md)

---

## 目录

- [动机](#动机)
- [注意事项](#注意事项)
- [架构](#架构)
- [前置条件](#前置条件)
- [安装](#安装)
  - [Android（LSPosed 模块）](#androidlsposed-模块)
  - [Linux（流水线主机）](#linux流水线主机)
- [配置](#配置)
- [多模型变体生成](#多模型变体生成)
- [使用](#使用)
  - [手动](#手动)
  - [自动（systemd）](#自动systemd)
- [项目结构](#项目结构)
- [各阶段说明](#各阶段说明)
- [致谢](#致谢)
- [许可证](#许可证)

---

## 动机

HelloTalk 上的语言学习者每天都会产出大量自发、真实的口语。这些口语是个性化学习素材的金矿——但通话一结束就丢失了。本流水线捕获、清洗这些口语，并将其转化为结构化的 Anki 卡片，精准定位*你*个人的错误模式和词汇缺口。

---

## 注意事项

在依赖本流水线之前请先读完这些。它们界定了这个工具擅长的领域和它的边界。

**本流水线只能发现你已经在犯却没有注意到的错误——它不教你新语言。** 它是一面反馈镜，不是教科书。如果某个结构完全不在你的主动知识范围内，再怎么分析你自己的输出也不会把它引入。习得仍然需要可理解性输入和显式学习；流水线只是收紧你已经能产出的部分。

**音频来源不限于 HelloTalk。** 采集模块之所以 hook 的是 HelloTalk，只是因为这个项目是从那里起步的，但流水线本身只处理 `.wav` 文件。任何录音口语练习的来源——另一个语言交换 App、家教平台、自言自语的语音备忘录——都同样可用。把 Stage 1（Pull）换成任何能把音频落到磁盘的方式即可，其余阶段与来源无关。

**产出反馈后一定要自己读一遍再继续。** LLM 有时会出错：错误归因、凭空发明不存在的模式、或者把正确用法标记为错误。流水线有意没有加入自动校验步骤——亲自审阅反馈本身就是一次 noticing（注意）练习，是学习的一部分。把这一步交给模型，会悄悄抽掉整个回路里最有价值的时刻之一。所以请读 `grammar.md` 和 `semantic.md`，核对被标记的错误是否成立，确认后再进入 drill 或 Anki 阶段。

---

## 架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         HELLOTALK 学习流水线                                 │
│                              (7 阶段流水线)                                  │
└─────────────────────────────────────────────────────────────────────────────┘

 ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
 │  Stage 1 │───>│  Stage 2 │───>│  Stage 3 │───>│  Stage 4 │───>│  Stage 5 │
 │   拉取   │    │   处理   │    │   转写   │    │   清洗   │    │   分析   │
 └──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘
      │                │                │                │                │
      ▼                ▼                ▼                ▼                ▼
  .wav 文件       降噪 & 按静音       原始 .txt        无噪转写         grammar.md
  来自 Android    分段               转写文本          (PII 屏蔽,       semantic.md
  -> WSL2                            via NVIDIA       ASR 噪声移除)    (LLM 输出)
                                    Whisper gRPC
                                                                    │
                                                                    ▼
                                                               ┌──────────┐
                                                               │  Stage 6 │
                                                               │ 4/3/2    │
                                                               │ 训练     │
                                                               └──────────┘
                                                                    │
                                                                    ▼
                                                               grammar-drill.md
                                                               vocabulary-drill.md
                                                               (限时复述)
                                                                    │
                                                                    ▼
                                                               ┌──────────┐
                                                               │  Stage 7 │
                                                               │   Anki   │
                                                               └──────────┘
                                                                    │
                                                                    ▼
                                                               grammar_cards.tsv
                                                               chunk_cards.tsv
                                                               -> 导入 Anki
```

### 阶段总览

| 阶段 | 脚本 | 作用 |
|------|------|------|
| **1. 拉取** | `hellotalk-pull-audio.sh` | 通过 ADB（无线或 USB）从 Android 拉取 `.wav` 文件。 |
| **2. 处理** | `hellotalk-process-audio.sh` | 用 `afftdn` 降噪，按静音边界分段，丢弃短/废片段。 |
| **3. 转写** | `hellotalk-transcribe.sh` | 将音频发送到 NVIDIA Riva/Whisper gRPC API；网络失败自动重试；对错误分类。 |
| **4. 清洗** | `hellotalk-cleanse.sh` | 移除填充词、ASR 噪声（"thank you for watching"）、非英语行，以及匹配用户自定义屏蔽列表的 PII。 |
| **5. 分析** | `hellotalk-analyze.sh` | 合并每日转写，合并稀疏日期，运行两个 LLM prompt：**语法分析**与**语义/搭配分析**。 |
| **6. 4/3/2 训练** | `hellotalk-generate-drill-interactive.sh` | 从当日语法/语义分析 + 转写上下文构建限时 4/3/2 流利度训练（同一内容按 4->3->2 分钟复述）。仅交互式；无 systemd 单元。 |
| **7. 生成 Anki** | `hellotalk-generate-anki.sh` | 将分析输出转化为制表符分隔的 Anki 卡片文件（`.tsv`），可直接导入。 |

---

## 前置条件

### Android
- Root 权限 + [LSPosed](https://github.com/LSPosed/LSPosed)（或兼容的 Xposed 框架）
- 已安装 HelloTalk App
- 已配置 ADB（无线或 USB）

### Linux 主机（WSL2 或原生）
- `bash`、`adb`、`ffmpeg`、`ffprobe`、`bc`
- Python 3.10+，安装 `openai` 和 `httpx` 包
- `systemd`（用于自动化定时器；可选——全部可手动运行）
- Google AI Studio API 密钥（默认 LLM provider）——或 NVIDIA 密钥，或任意 OpenAI 兼容端点——用于 LLM 推理；NVIDIA API 密钥用于转写

### 可选
- [Anki](https://apps.ankiweb.net/) 桌面版或移动版，用于导入卡片
- 与 TSV 字段布局匹配的自定义 Anki 笔记类型

---

## 安装

### Android（LSPosed 模块）

1. 在 Android Studio 中打开 `android-module/`，或从 CLI 构建：
   ```bash
   cd android-module
   export ANDROID_HOME=$HOME/Android/Sdk
   ./gradlew assembleDebug
   ```

2. 安装 APK：
   ```bash
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```

3. 在 **LSPosed Manager** 中：
   - 启用模块 **HelloTalk Capture**
   - 作用域设为 `com.hellotalk`
   - 强制停止 HelloTalk 并重新打开

4. 验证采集：
   - 在 HelloTalk 中发送一条语音消息
   - 检查设备上的 `/sdcard/HelloTalkCapture/` 是否有 `.wav` 文件

### Linux（流水线主机）

1. 克隆本仓库并将脚本符号链接到 PATH：
   ```bash
   git clone https://github.com/Raycc-lang/HelloTalk-Learning-Pipeline.git
   cd HelloTalk-Learning-Pipeline
   
   mkdir -p ~/.local/bin
   for f in pipeline-scripts/*; do
       ln -sf "$(realpath "$f")" ~/.local/bin/$(basename "$f")
   done
   ```

2. 将 LLM prompt 复制到预期位置：
   ```bash
   cp prompts/*.md ~/Android/HelloTalkCapture/
   mkdir -p ~/Android/HelloTalkCapture/Drill
   cp prompts/drill/*.md ~/Android/HelloTalkCapture/Drill/
   ```

3. 安装 Python 依赖：
   ```bash
   pip install openai httpx
   ```

4. 复制并填写配置模板：
   ```bash
   mkdir -p ~/.config/hellotalk
   cp config/env.template ~/.config/hellotalk/env
   # 编辑 ~/.config/hellotalk/env，填入你的 API 密钥
   ```

5.（可选）创建隐私屏蔽列表：
   ```bash
   cp config/cleanse.conf.template ~/.config/hellotalk/cleanse.conf
   # 每行一个正则，用于从转写中移除敏感内容
   ```

6.（可选）安装 systemd 单元实现自动化：
   ```bash
   mkdir -p ~/.config/systemd/user
   cp systemd/*.service systemd/*.timer ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable hellotalk-pull-audio.timer
   systemctl --user start hellotalk-pull-audio.timer
   ```

---

## 配置

所有敏感配置位于 `~/.config/hellotalk/env`。流水线支持三种 LLM provider：

| Provider | `PROVIDER=` | 所需变量 |
|----------|-------------|----------|
| Google AI Studio（默认） | `google` | `GOOGLE_API_KEY` |
| NVIDIA NIM | `nvidia` | `NVIDIA_API_KEY` |
| 自定义（任意 OpenAI 兼容端点） | `custom` | `CUSTOM_API_BASE`, `CUSTOM_API_KEY` |

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PROVIDER` | `google` | LLM 调用使用的后端（`google`、`nvidia` 或 `custom`） |
| `MODEL` | `gemini-3.5-flash` | 模型 ID（provider 特定） |
| `REASONING_EFFORT` | `high` | 思考力度：`minimal` \| `low` \| `medium` \| `high`。在 Google 的 OpenAI 兼容端点上映射为思考预算 |
| `GOOGLE_API_KEY` | - | Google AI Studio API 密钥 |
| `NVIDIA_API_KEY` | - | NVIDIA API 密钥 |
| `CUSTOM_API_BASE` | - | 自定义 OpenAI 兼容端点的 Base URL |
| `CUSTOM_API_KEY` | - | 自定义端点的 API 密钥 |
| `MERGE_MIN_LINES` | `80` | 某日 `merged.txt` 独立存在的最小行数；低于此值的稀疏日会被合并到次日 |
| `VARIANTS` | `0` | 设为 `1` 时每个 artifact 由两个模型分别生成后合并。参见[多模型变体生成](#多模型变体生成) |
| `VARIANT_SLOTS` | `"PRIMARY SECONDARY"` | 参与生成的模型槽位，按顺序排列。需加引号——该文件也会被 bash source |
| `<SLOT>_PROVIDER` | 第一个槽位继承 `PROVIDER` | 某个槽位的 provider，例如 `SECONDARY_PROVIDER=nvidia` |
| `<SLOT>_MODEL` | 第一个槽位继承 `MODEL` | 某个槽位的模型 ID。第一个之后的每个槽位都必须指定 |
| `<SLOT>_API_BASE` / `<SLOT>_API_KEY` | 各 provider 自身变量 | 每个槽位的凭据覆盖，用于指向不同的端点 |
| `<SLOT>_REASONING_EFFORT` | `REASONING_EFFORT` | 每个槽位的思考力度 |
| `<SLOT>_MAX_TOKENS` | `MAX_TOKENS` | 每个槽位的输出上限。当某个槽位的模型输出上限更低时用它（例如网关后面的 `65536`），不必给所有模型设全局上限 |
| `JUDGE_PROVIDER` / `JUDGE_MODEL` | 第一个可用槽位 | 用于合并候选结果的模型 |
| `VARIANT_KEEP` | `1` | 在 finished 文件旁保留 `variants/` 目录下的原始候选 |
| `VARIANT_MIN_UNIT_PCT` | `50` | 合并后的文件必须保留最丰富候选的条目/卡片/主题数至少此百分比，否则被拒绝 |

> **关于 `MAX_TOKENS`：** 不再全局设置。思考模型会将同样的 token 预算花在内部推理上，设得过小可能导致零可见输出。各脚本各自提供默认值（analyze/drill 为 `131072`，`hellotalk-llm-call.py` 内有 `32768` 兜底）。若某个槽位指向输出上限更低的模型，用 `<SLOT>_MAX_TOKENS` 单独降低该槽位的预算即可，例如 `SECONDARY_MAX_TOKENS=65536`。

### 各脚本备注

- `hellotalk-pull-audio.sh` - 编辑 `DEVICE=` 以匹配你的 ADB 目标（如无线连接用 `192.168.1.13:5555`）。
- `hellotalk-transcribe.sh` - 需要 NVIDIA gRPC Python 客户端（NVIDIA Riva 示例中的 `transcribe_file_offline.py`）。路径不同请更新 `PYTHON_CLIENT=`。
- `hellotalk-cleanse.sh` - 从 `~/.config/hellotalk/cleanse.conf` 读取 PII 屏蔽列表。
- `hellotalk-analyze.sh` - 设置 `MERGE_MIN_LINES`（默认 80）控制稀疏日合并阈值。

---

## 多模型变体生成

两个模型分析同一份转写，找到的错误并不相同。各自会漏掉对方捕捉到的东西，两者的并集始终优于任何一个单独的结果。将 `VARIANTS=1` 设为流水线的默认行为，而不是手动拼凑。

启用后，每个 LLM 阶段会运行三次调用而非一次：

```
                 ┌── PRIMARY 模型   ──→ variants/<名称>.primary   ─┐
输入 ────────────┤                                                  ├──→ judge ──→ 最终 artifact
                 └── SECONDARY 模型 ──→ variants/<名称>.secondary  ─┘
```

合并步骤本身也是一个 prompt——`prompts/judge-analysis.md`、`judge-tsv.md` 或 `judge-drill.md`，由阶段选择。每个 judge prompt 规定了合并标准而非询问哪个候选"看起来更好"：分析 judge 取真实发现的并集，删除引文不在转写中的条目；TSV judge 合并卡片并修复字段计数损坏；drill judge 选一个连贯的会话作为基础并从其他候选修复。候选内容被包裹在分隔符中并被当作数据处理，因此模型输出中的 stray 指令无法重定向合并过程。

### 设置

在 `~/.config/hellotalk/env` 中配置第二个槽位：

```bash
VARIANTS=1
VARIANT_SLOTS="PRIMARY SECONDARY"

PRIMARY_PROVIDER=google
PRIMARY_MODEL=gemini-3.5-flash

SECONDARY_PROVIDER=nvidia
SECONDARY_MODEL=moonshotai/kimi-k2.5
```

只有第一个槽位继承环境配置，因此不设置 `PRIMARY_*` 即可复现普通的单模型设置。之后的每个槽位必须指定自己的模型——两个候选来自同一个模型会共享盲区，因此运行器会检测到重复槽位并跳过，而不是为它付费。

支持两个以上槽位：将 `TERTIARY` 添加到 `VARIANT_SLOTS` 并配置它。所有三个 judge prompt 都支持任意数量的 `CANDIDATE N` 段落，产生的每个候选都会被发送给合并步骤。成本随槽位数加一增长——三个槽位意味着每个 artifact 四次调用。

### 成本与故障行为

每个 artifact 花费三次 API 调用而非一次。`VARIANTS=0` 是默认值，因此自动化的 systemd 运行保持低成本；在输出重要时按调用启用：

```bash
VARIANTS=1 hellotalk-generate-anki.sh
```

每种降级路径都保留已付费的内容：

| 情况 | 结果 |
|------|------|
| 一个模型失败或超时 | 使用存活的候选，不合并 |
| 所有模型以相同方式失败 | 保留失败类型——错误的 key 或模型 ID 仍会中止批次，而非在每个 artifact 上重试一次 |
| 任一生成触及日配额 | 写入配额哨兵，批次中止（exit 75），与之前相同 |
| 配额在*合并期间*被触发 | 批次中止，artifact 故意不写入。两个已付费候选保留在 `variants/` 中；下次运行时重新生成并正确合并 |
| 合并返回散文、道歉或坍缩的文件 | 使用第一个*结构上有效*的候选——而非简单地取第一个 |
| 候选内容太大无法在一次调用中合并 | 先丢弃源材料，然后使用最佳有效候选 |
| 配置了少于两个不同的模型 | 恰好一次调用——与 `VARIANTS=0` 相同，成本相同 |

合并后的文件只有在看起来仍然像它替代的 artifact 且没有坍缩时才会被接受：它必须保留最丰富候选的条目、卡片或主题数至少 `VARIANT_MIN_UNIT_PCT`（默认 50）百分比。合并会移除重复项，因此标准是百分比而非相等——但一个截断或三十张中只返回两张卡片的 judge 不能覆盖完整的候选。

> **关于配额合并行的说明：** 将未合并的候选提升到最终路径看似有帮助，实则有害。artifact 会比其输入更新，因此 freshness check 会在后续每次运行时跳过那一天，未合并的版本会被永久锁定。留空不写花费一次重新生成，产生正确结果。

原始候选保留在 finished 文件旁的 `variants/` 中，这样你可以比较每个模型产出的内容，以及合并保留了哪些内容。设置 `VARIANT_KEEP=0` 可在合并成功后删除它们。

### 凭据

只有第一个槽位继承环境配置，并且它继承所有内容——`PROVIDER`、`MODEL` 以及直接在 env 文件中设置的任何 `API_BASE` / `API_KEY`。因此为单模型使用配置的代理或自定义端点，在启用变体后仍能正常工作。

凭据也可以完全存在于槽位中，而无需环境密钥：

```bash
VARIANTS=1
PRIMARY_PROVIDER=custom
PRIMARY_MODEL=alpha
PRIMARY_API_BASE=https://endpoint-a/v1
PRIMARY_API_KEY=***
SECONDARY_PROVIDER=custom
SECONDARY_MODEL=beta
SECONDARY_API_BASE=https://endpoint-b/v1
SECONDARY_API_KEY=***
```

启动时的凭据检查是变体感知的，因此这种配置可以正常启动，而不会因为缺少环境密钥被拒绝。

---

## 使用

### 手动

按顺序运行各阶段，或只运行你需要的：

```bash
# 1. 从 Android 拉取新音频
hellotalk-pull-audio.sh

# 2. 降噪并按静音分段
hellotalk-process-audio.sh

# 3. 用 Whisper 转写
hellotalk-transcribe.sh

# 4. 清洗转写（移除噪声、ASR 噪声、PII）
hellotalk-cleanse.sh

# 5. 运行 AI 分析（语法 + 语义）
hellotalk-analyze.sh

# 6. 构建 4/3/2 流利度训练（交互式选择——推荐）
hellotalk-generate-drill-interactive.sh
#（批量变体：hellotalk-generate-drill.sh）

# 7. 生成 Anki TSV
hellotalk-generate-anki.sh
```

Stage 6 之后，训练会话输出到 `Drill/sessions/YYYY-MM-DD/`，即
`grammar-drill.md` 和 `vocabulary-drill.md`——这是用来"对着说"的内容骨架，不是
要照读的脚本。读一遍，然后做 4->3->2 分钟的限时复述。

Stage 7 之后，将生成的 `.tsv` 文件导入 Anki：
- `Anki/YYYY-MM-DD/grammar_cards.tsv`
- `Anki/YYYY-MM-DD/chunk_cards.tsv`

### 自动（systemd）

附带的 systemd 定时器按计划运行流水线：

| 定时器 | 计划 | 链式触发 |
|--------|------|----------|
| `hellotalk-pull-audio.timer` | 每天 12:00 | -> process |
| `hellotalk-process-audio.timer` | 每天 12:05 | -> transcribe |
| `hellotalk-transcribe.timer` | 每天 12:15 | -> cleanse |
| `hellotalk-cleanse.timer` | 每 6 小时 | -> analyze |
| `hellotalk-analyze.timer` | 每 6 小时（错开） | （手动 drill / Anki） |
| `hellotalk-generate-anki.timer` | 每 6 小时（错开） | - |

> **Stage 6（4/3/2 训练）刻意只做交互式——没有对应的 systemd 单元。** 训练生成需要你选择日期和训练类型（语法 / 词汇 / 两者），所以通过 `hellotalk-generate-drill-interactive.sh` 手动运行。自动定时器直接从分析跳到 Anki。

查看定时器状态：
```bash
systemctl --user list-timers hellotalk-*
```

手动运行单个阶段：
```bash
systemctl --user start hellotalk-analyze.service
```

---

## 项目结构

```
HelloTalk-Learning-Pipeline/
├── android-module/           # LSPosed Xposed 模块（Java）
│   ├── app/src/main/java/.../MainHook.java
│   ├── app/src/main/java/.../AudioCaptureManager.java
│   ├── app/src/main/java/.../WavHeaderWriter.java
│   ├── app/src/main/AndroidManifest.xml
│   └── build.gradle
├── pipeline-scripts/         # Bash + Python 自动化脚本
│   ├── hellotalk-pull-audio.sh
│   ├── hellotalk-process-audio.sh
│   ├── hellotalk-transcribe.sh
│   ├── hellotalk-cleanse.sh
│   ├── hellotalk-analyze.sh
│   ├── hellotalk-generate-drill-interactive.sh
│   ├── hellotalk-generate-drill.sh
│   ├── hellotalk-generate-anki.sh
│   ├── hellotalk-anki-interactive.sh
│   ├── hellotalk-llm-call.py
│   ├── hellotalk-provider-resolve.sh
│   ├── hellotalk-variants.sh     # 多模型生成 + 合并
│   ├── hellotalk-quota-check.sh
│   ├── hellotalk-cleanup-empty-segments.sh
│   ├── hellotalk-reset-transcribe.sh
│   └── hellotalk-common.sh
├── systemd/                  # 用户 systemd 单元
│   ├── *.service
│   └── *.timer
├── prompts/                  # LLM 系统 prompt
│   ├── analysis-grammar.md
│   ├── analysis-semantic.md
│   ├── anki-generator-grammar.md
│   ├── anki-generator-semantic.md
│   ├── judge-analysis.md     # 合并两个分析候选
│   ├── judge-tsv.md          # 合并两套 Anki 卡片
│   ├── judge-drill.md        # 合并两个训练会话
│   └── drill/                # 4/3/2 训练 prompt
│       ├── grammar-drill-prompt.md
│       ├── vocabulary-drill-prompt.md
│       └── transcript-regenerator-prompt.md
├── config/                   # 配置模板
│   ├── env.template
│   └── cleanse.conf.template
├── README.md
├── README.zh-CN.md
└── LICENSE
```

---

## 各阶段说明

### Stage 1 - 拉取
- 通过 ADB（无线或 USB）连接 Android
- 将 `.wav` 文件从 `/data/data/com.hellotalk/files/HelloTalkCapture` 暂存到 `/sdcard/`，以便非 root 拉取
- 传输成功后删除原件

### Stage 2 - 处理
- 跳过"今天"录制的文件（避免拉取正在进行的录音）
- 将畸形音频隔离到 `Invalid_audio/`
- 将超大文件（> 200 MB——可能是卡住的录音）隔离到 `Invalid_audio/`
- 用 `ffmpeg afftdn` 降噪
- 用 `silencedetect` 检测静音
- 切分为语音段；丢弃 < 2 秒的段

### Stage 3 - 转写
- 按文件大小（> 50 KB）、时长（> 0.5 s）、RMS 电平（> -40 dB）预过滤
- 调用 NVIDIA Riva Whisper gRPC，带自动标点
- 瞬时网络错误最多重试 3 次
- 失败分类：`auth_error`、`network_error`、`invalid_audio`、`rate_limit`、`no_speech`
- 将分段转写合并为每条录音一个 `.txt` 文件

### Stage 4 - 清洗
- 移除填充词（`uh`、`um`、`like`、`so`、`I think`……）
- 剥离 ASR 噪声（`[Music]`、"Thank you for watching"、"subscribe"……）
- 丢弃非英语行（中文、印地语等）
- 移除重复幻觉（同一短语重复 4 次以上）
- 应用 `cleanse.conf` 中用户自定义的 PII 屏蔽列表
- 丢弃 ≤ 3 个词的行

### Stage 5 - 分析
- 将每个日历日清洗后的转写合并到 `Analysis/YYYY-MM-DD/merged.txt`
- **合并稀疏日**：行数少于 `MERGE_MIN_LINES`（默认 80）的日期会被前置到次日的 `merged.txt`，带日期分隔头，稀疏日的文件夹会被移除。避免在单薄内容上浪费 API 调用。级联安全：若吸收一个稀疏日后目标仍低于阈值，同一轮会继续合并。
- 运行两个独立的 LLM 分析：
  - **语法** - 识别反复出现的语法错误和来自母语（中文）的结构性直译
  - **语义** - 识别三类词汇问题：近似搭配、漏掉的习语表达、语义边界错误。同一底层模式的重复出现会被去重为一条发现。
- 遵守配额哨兵：若 provider 触及日限额，批次优雅中止并稍后恢复

### Stage 6 - 4/3/2 训练
- 限时流利度训练：同一内容按递减时长复述三次（4 分钟 -> 3 分钟 -> 2 分钟）。压缩迫使程序化——你停止规划，开始产出。
- **仅交互式**，此阶段无 systemd 定时器。
  - `hellotalk-generate-drill-interactive.sh` - 推荐入口。呈现选择器，选择日期和训练类型（语法 / 词汇 / 两者），始终包含转写上下文。
  - `hellotalk-generate-drill.sh` - 非交互式批量变体，遍历每个已分析日期。
- **输入：** `Analysis/YYYY-MM-DD/grammar.md` 和 `semantic.md`，加上原始或清洗后的转写用于话题/上下文重建。
- **输出：** `Drill/sessions/YYYY-MM-DD/grammar-drill.md` 和 `vocabulary-drill.md`——内容骨架加目标结构/词块列表，用来"对着说"，不是照读的脚本。
- prompt 位于 `prompts/drill/`：
  - `grammar-drill-prompt.md` - 从 `grammar.md` 构建语法聚焦的 4/3/2 会话
  - `vocabulary-drill-prompt.md` - 从 `semantic.md` 构建词块/搭配聚焦的会话
  - `transcript-regenerator-prompt.md` - 从混乱的 ASR 输出重建干净、带说话人标签的转写，以分析文件为锚点

### Stage 7 - 生成 Anki
- 取 Stage 5 的 `grammar.md` 和 `semantic.md`
- 生成制表符分隔的闪卡文件：
  - `grammar_cards.tsv` - FILL_IN_BLANK 和 CORRECT_THE_ERROR 卡
  - `chunk_cards.tsv` - ERROR_CORRECTION、COLLOCATION_COMPLETION、IDIOM_UPGRADE 和 PATTERN_COMPLETION 卡，各自映射自上游语义子类型
- 每张卡包含母语词块示例、干扰说明和上下文例句

---

## 致谢

- **[OpenAI Whisper](https://github.com/openai/whisper)** - 现代开源语音识别的基石。
- **[NVIDIA Riva](https://docs.nvidia.com/ai-enterprise/deployment-guide-spark/0.1.0/whisper.html)** - 此处通过 NIM gRPC 实现快速、准确的转写。
- **[LSPosed](https://github.com/LSPosed/LSPosed)** - 现代 Xposed 框架，使 Android 上的运行时 hook 成为可能。
- **[Anki](https://apps.ankiweb.net/)** - 间隔重复平台，将分析转化为长期记忆。
- **[OpenClaw](https://github.com/Raycc-lang/openclaw)** / **[Hermes Agent](https://hermes-agent.nousresearch.com/)** - 协助设计、调试和文档化本流水线的 agent 基础设施。

---

## 许可证

MIT 许可证 - 详见 [LICENSE](LICENSE)。

---

## 免责声明

本工具仅供**个人学习使用**。它从运行在*你自己*设备上的 HelloTalk App 中采集音频。请遵守 HelloTalk 的服务条款，尊重对话伙伴的隐私。未经所有相关方明确同意，不得分发采集到的音频或转写。
