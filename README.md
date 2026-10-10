# CodeJump

一个原生 macOS 菜单栏应用，把 Claude、Obsidian 等应用中的代码引用交给 IntelliJ IDEA、VS Code、Cursor 或 Zed。

## 使用

1. 打开 `/Applications/CodeJump.app`，拖入常用项目文件夹；勾选的项目才参与搜索。
2. 默认编辑器为 IntelliJ IDEA。可选其他编辑器或指定 `.app` 安装位置。
3. 在系统设置 → 隐私与安全性 → 辅助功能中启用 CodeJump。
4. 鼠标指向引用，按 **⌥J**（设置中可改为 **⌘⌥J**）。唯一且已核验的匹配直接打开；多个项目、重载或需要核对的位置显示候选，支持数字、上下键、回车和 Esc。
5. 按 **⌥P** 弹出项目选择（组合键设置会同时改为 **⌘⌥P**）。输入项目名、别名或路径筛选，用上下键和回车选择，也可按 **⌘1…9**。优先切到已打开的 IDEA 项目窗口，未找到可确认的窗口时请求编辑器打开该项目。
6. 按 **⌥H** 打开主页与设置，主页已在前台时再按一次收起（组合键设置会同时改为 **⌘⌥H**）。主页在其他应用后方或已最小化时，按下快捷键会将它带回前台。应用已运行时，在 Finder 中再次打开 `CodeJump.app` 也会显示主页。

项目排序结合选择次数和最近选择时间，历史权重每 7 天减半，避免很久以前常用的项目长期占据首位；搜索精确匹配与前缀匹配优先。记录随项目设置保存在本机。

IDEA 已打开窗口先核对项目选择按钮提供的根目录。只有导入根和 IDEA 窗口的项目名称都唯一时才允许名称回退，同名工作树不猜。窗口查找有节点和耗时上限。

普通单击的行为不变。应用不会改写笔记、修改文件关联、注入 Claude、上传代码或持续读取鼠标位置。没有辅助功能权限时，手动定位框和菜单栏的剪贴板入口仍可使用。剪贴板入口只在主动选择后读取，悬停入口不会改动剪贴板。

设置窗口可以关闭，应用继续在菜单栏运行。项目可分别启停、移出范围、设置别名。项目移除只影响搜索范围，不删除项目文件。

主页标题和底部索引状态固定可见，中间设置可以滚动；展开定位信息或增加项目时不会把标题挤出窗口。窗口初始大小会适应当前屏幕可用区域，再次打开时保留可见范围内的窗口尺寸和位置。

三个快捷键分别注册，某一个被占用不影响其他两个；项目搜索框正在输入中文候选时，回车、方向键与 Esc 交给输入法。指定 IDEA 安装位置后，窗口查找也仅限该安装。

快捷键没有识别到引用、没有匹配或索引尚未就绪时，仅在鼠标旁显示约 2.5 秒的提示，不会弹出主页面或抢焦点。候选窗口出现时暂时隐藏设置页，取消后回到原应用。配置过项目后，启动应用只常驻菜单栏；需要主页时按 ⌥H，或在菜单栏主动选择“主页与设置…”。

## 支持的引用

```text
/path/to/Foo.java:128
src/main/java/Foo.java:128:8
Foo.java#L128-L140
BatchProcessRecordCommand:246-251
demo-alpha-core/.../ability/InternalRecordAbility.java:188
RecordAbility.enrichRecord（28-33 行）
RecordAbility#enrichRecord
```

支持 Markdown 文件链接、`file:///` 本机链接及可选的 `codejump://open?project=demo-alpha&path=relative/File.java&line=28` 链接。自定义协议只做定位，不接受命令或网络文件；外部协议请求始终先显示目标预览。

可见链接标签中的方法名或行号，会在与目标文件明确相符且无歧义时补到链接目标。带历史提交的引用会提示打开的是当前工作区。Java 方法定位读取本地声明，排除注释、字符串和方法调用；重载保持候选。文件行号和方法同时出现时，核对当前方法范围，旧行号已漂移会给出当前声明位置并要求确认。

本地方法声明定位支持 Java 的所属类与内部类校验，排除同文件其他类的方法。支持数组注解、方法括号、完整包名及紧贴中文的行号；显式参数仅作为本地确认提示，可选 IDEA 插件进一步按参数类型过滤。其他语言仍支持文件、行和列。省略路径必须能在导入项目中匹配；同名项目或工作树不会仅凭最近使用记录自动选择。

## 性能与边界

- 按快捷键时才读取辅助功能信息；读取范围、超时、输入长度、引用数、候选源码大小都有上限。
- 项目索引在后台建立；跳转用内存字典按文件名、类名及路径查找，不进行全盘扫描，不调用 AI。
- 纯内容修改不重建查询表、不重写路径索引；方法定位按完整源码内容缓存，源文件变化即重新解析，缓存最多 64 项 / 8 MB。
- FSEvents 合并文件变更并更新受影响子树，大批变更退回整批重建。排除版本库、依赖和构建输出，跳过二进制及符号链接目录。
- 跳转前再次检查文件和项目边界，文件被删除或换成跨项目符号链接时拒绝执行。
- 编辑器通过参数数组启动，不使用 shell 拼接。IDEA 先传项目根，再传文件和位置，并转换零基列号。
- 辅助功能信息由来源应用决定。部分渲染节点可能只有标签、无法提供鼠标字符位置，或把很多引用放在同一节点。无法可靠确定时显示候选或使用选中文本/手动输入，不猜位置。

## 开发与验证

需要 macOS 14+、Swift 6 / Apple Command Line Tools，无第三方运行依赖。

```sh
./script/test.sh
./script/build_and_run.sh --build-only
./script/build_and_run.sh --install
```

`script/test.sh` 兼容仅安装 Command Line Tools 时 Swift Testing 的框架路径。

构建脚本默认 Release；`CODEJUMP_CONFIGURATION=debug` 可切换 Debug。支持 `--verify`、`--debug`、`--logs`、`--telemetry`。安装时只替换相同 bundle ID 的 CodeJump，原版本备份在 `output/backups/`。

只读性能检查，不启动编辑器：

```sh
.build/release/codejump-cli --project /path/to/project --query 'Foo.java:128' --benchmark 1000
```

## 数据位置

- `~/Library/Application Support/CodeJump/settings.json`：项目范围及偏好。
- `~/Library/Application Support/CodeJump/index-v1.json`：本地索引缓存。
- 诊断界面中的最近识别文字只存在内存；系统日志只记录文件数量和耗时。

本地构建使用 ad-hoc 签名，二进制重新构建后 macOS 可能要求重新授权辅助功能；正式分发需要稳定的开发者签名和公证。

如果系统设置的开关已经打开，但 CodeJump 仍显示“开启辅助功能权限”，这是旧构建的授权记录尚未更新：在辅助功能列表中移除 CodeJump，再添加 `/Applications/CodeJump.app`，回到应用点击刷新。系统弹出的 Touch ID 或密码验证需由用户本人完成。仅关闭再打开旧条目的开关可能无法更新签名记录。

也可以在移除旧记录后点击 CodeJump 的“前往授权”，让新构建重新出现在列表中，再启用开关。若应用仍读取到旧权限状态，退出并重新打开 CodeJump 后再检查。

IDEA 收到命令与成功显示代码是两个阶段。若 IDE 自身卡顿、出现文件缓存错误或内存不足，需要先恢复 IDE 状态；CodeJump 不会自动重启 IDE。

## 0.2.0 新功能

- 悬停读取保留 UTF-16 字符范围，同段多个引用时优先选择鼠标实际覆盖的引用；精准目标没有匹配时，邻近文字只显示候选，必须确认。
- 候选窗口显示项目根、来源、定位理由和前后代码；方向键或鼠标悬停可切换预览，当前行高亮。
- 主页可临时选择“本次搜索范围”。可选记住来源应用常用项目，只调整排序，跨项目重名仍需选择。
- 最近 30 次成功发送的跳转保存在本地设置，可清空；再次点击会重新核对源码和行号，再显示候选。记录表示请求已发送，不代表 CLI 编辑器确认完成。
- “识别错了？保存本地反馈”把当前文字、来源和候选导出为 JSON，保存位置由用户选择，不自动上传。反馈不包含插件令牌或可执行跳转凭据。

## 可选 IDEA Companion

已提供 `dist/CodeJumpCompanion-0.2.1.zip`，面向本机 IDEA 2026.1（261.*）。构建：

```sh
python3 idea-plugin/build.py
```

使用 IDEA 设置 → 插件 → 齿轮 → 从磁盘安装。支持动态加载；若连接未出现，运行 Tools → Start CodeJump Bridge。然后在 CodeJump 主页启用“使用可选 IDEA 插件”并检查连接。默认不启用，关闭或未连接时仍可用本地索引。

插件依据 [JetBrains PSI 查询 API](https://plugins.jetbrains.com/docs/intellij/psi-cookbook.html) 查找当前已打开项目中的 Java 类和方法，支持完整类名、重载参数类型、继承方法、依赖 JAR 的源码或反编译声明。例如：

```text
java.lang.String.substring(int, int)
java.util.ArrayList.stream()
com.example.beta.service.enricher.impl.OrderRecordEnricher.enrich
```

参数按 IDEA 展示类型或完整类型匹配，不进行表达式类型推断；空括号作为常见方法展示格式，不自动排除带参数重载。PSI 结果始终显示候选并标明将打开当前声明，不把原引用中的旧行号当成已验证位置。项目未打开或 IDEA 正在索引时，本地路径仍可使用。

只监听随机的 `127.0.0.1` 端口，要求每进程随机令牌，拒绝浏览器 Origin 请求；端点文件仅当前用户可读写，位于 `~/Library/Application Support/CodeJump/idea/`。客户端核对运行中的 IDEA PID 和安装路径。跳转使用五分钟内的 PSI 智能指针，在 IDE 中重新核验有效性，不接受任意 shell 命令。最多 64 个子查询 / 128 个结果，单次连接超时 2 秒；插件仅辅助候选，不改变自动打开门槛。

已安装插件的本地验证（`--navigate` 会实际打开一个 JDK 方法）：

```sh
python3 idea-plugin/verify.py --project /path/to/open/project
python3 idea-plugin/verify.py --project /path/to/open/project --navigate
```


## 0.2.1 裸符号识别

选中 `addBatch2RecordAndAddressLock` 这样的裸方法名，或在手动定位框输入它，即可通过已连接的 IDEA 插件按方法名查询已打开项目的声明。同名方法、重载和跨项目结果均显示候选，不自动跳转。没有插件连接时请使用 `RecordHelper.addBatch2RecordAndAddressLock`。

代码块中的独立类名和驼峰方法名也可作为候选识别；若 AX 提供鼠标字符位置，只取命中位置的符号，否则显示附近候选并要求确认。明确选中的文字优先于邻近链接。

`EnricherManager` 这类 AI 简写不一定对应真实类。没有精确类名时，对至少 8 个字符的独立类名提供最多 64 个类名后缀候选，并明确标注“未找到同名类”；文件路径、完整包名和带方法的引用不做该模糊匹配。例如 beta 的实际类是 `BatchCreateRecordEnricherManager`，不会把所有包含 EnricherManager 的类当成精确命中。
