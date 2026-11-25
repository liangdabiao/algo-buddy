# Algo Buddy — R36S 离线算法学习

《Hello 算法》（hello-algo）的 R36S 掌机离线阅读器。全书 17 章 117 节 + 39 组步进图解 + 238 道题库，Godot 3.5.3 + FRT 运行时，PortMaster 三件套部署。架构照抄兄弟应用 english-buddy / javascript-buddy：单场景、代码生成 UI、screen 状态机、单一 content.json。

**内容授权**：文本与插图来自 [krahets/hello-algo](https://github.com/krahets/hello-algo)，CC BY-NC-SA 4.0，版权归原作者所有。本应用是个人学习用途的离线阅读器（App 内「关于与版权」页有署名）。

## 目录结构

```
algo-buddy/
├── project.godot / export_presets.cfg / scenes/Main.tscn
├── scripts/            App.gd(屏幕+阅读器+测验) UIKit.gd Chrome.gd
│                       ContentRepository.gd ProgressStore.gd
├── data/content.json   由 tools/extract_content.py 生成（勿手改）
├── assets/
│   ├── fonts/          ui.ttf(DengXian 子集) code.ttf(DejaVu Mono)
│   ├── figures/        518 张量化 PNG（含步进图与缩略图）
│   └── covers/         17 张章节封面
├── tools/
│   ├── extract_content.py   markdown → content.json（--fetch 可自动克隆上游）
│   ├── rasterize_figs.py    SVG → PNG（调 .build/resvg/resvg.exe）
│   ├── prepare_fonts.py     字体子集 + cmap 缺字审计（强制项）
│   ├── quizzes_core.yaml    8 核心章精编题库 54 题
│   ├── smoke.gd             headless 数据断言（~4000 项检查）
│   └── render_all.gd        全屏截图（带显示环境运行）
└── algo-buddy.sh / algo-buddy.gptk   PortMaster 启动三件套
```

## 从源码构建

依赖：Godot 3.5.3、Python 3.12（Pillow / fontTools / PyYAML）、resvg（`.build/resvg/resvg.exe`）、上游 docs（`.build/hello-algo-src/repo`，`--fetch` 可自动稀疏克隆）。

```bash
python tools/extract_content.py        # markdown → data/content.json（含题库合并）
python tools/rasterize_figs.py         # SVG → assets/figures/*.png
python tools/prepare_fonts.py          # 字体子集 + 缺字审计（必须零缺字）
godot --headless --path . --editor     # 完整资源导入（勿加 --quit，等待扫描完成）
godot --headless --path . --script res://tools/smoke.gd     # 数据断言
godot --path . --script res://tools/render_all.gd           # 截图人工复核
mkdir -p .build/algo-buddy
godot --headless --path . --export-pack "Linux/X11" .build/algo-buddy/algo-buddy.pck
godot --main-pack .build/algo-buddy/algo-buddy.pck --quit   # 独立加载验证
```

外层打包（zip 结构：`algo-buddy.sh` 在根 + `algo-buddy/{pck,gptk}`）+ sha256 记录到 `.build/algo-buddy.zip`、`.build/algo-buddy.sha256`。

## 部署到 R36S

```bash
export R36S_HOST="ark@<R36S_IP>"    # IP 随网络变化，部署前重新查询
scp .build/algo-buddy-pkg/algo-buddy.sh "$R36S_HOST:/roms/ports/algo-buddy.sh"
scp .build/algo-buddy-pkg/algo-buddy/algo-buddy.pck \
    .build/algo-buddy-pkg/algo-buddy/algo-buddy.gptk \
    "$R36S_HOST:/roms/ports/algo-buddy/"
ssh "$R36S_HOST" 'chmod +x /roms/ports/algo-buddy.sh && ls -lh /roms/ports/algo-buddy/'
```

需要 frt_3.5.2 运行时（PortMaster 会自动拉取）。存档落在 `/roms/ports/algo-buddy/conf/`（启动脚本把 XDG_DATA_HOME 指到端口目录），可持久保留。

## 实机验收清单

- [ ] 首页、章节目录、小节列表、阅读页正常显示，中文无缺字（对照 cmap 审计）
- [ ] 十字键/摇杆移动焦点，A 确认/下一页，B 返回，L/R 翻页，Select 回首页，Start 退出
- [ ] **步进图**：阅读页 X 打开（如 11.3 冒泡排序），左右步进、圆点进度、末步 A 返回
- [ ] 图页白底面板完整显示，题注可见
- [ ] 问答页 A/Y 显示答案浮层；测验 MCQ 判分、reveal 自评、结果页计分
- [ ] 退出重进：阅读页码、完成标记、测验分、连胜持久化（conf 目录）
- [ ] 错题复习有到期队列；术语表浏览与术语测验正常
- [ ] 日志无 SCRIPT ERROR：`ssh "$R36S_HOST" 'tail -n 80 /roms/ports/algo-buddy/log.txt'`

## 内容更新流程

hello-algo 上游更新后：`git -C ../.build/hello-algo-src/repo pull` → 重跑 extract → rasterize → fonts → smoke → 截图抽查 → 重新导出打包。`meta.sourceCommit` 取自克隆记录，「关于」页署名不变。
