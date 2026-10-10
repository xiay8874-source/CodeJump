# CodeJump

一个原生 macOS 菜单栏应用，把 Claude、Obsidian 等应用中的代码引用交给 IntelliJ IDEA、VS Code、Cursor 或 Zed。

## 使用

1. 打开 `/Applications/CodeJump.app`，拖入常用项目文件夹；勾选的项目才参与搜索。
2. 默认编辑器为 IntelliJ IDEA。可选其他编辑器或指定 `.app` 安装位置。
3. 在系统设置 → 隐私与安全性 → 辅助功能中启用 CodeJump。
4. 鼠标指向引用，按 **⌥J**（设置中可改为 **⌘⌥J**）。唯一且已核验的匹配直接打开；多个项目、重载或需要核对的位置显示候选，支持数字、上下键、回车和 Esc。
5. 按 **⌥P** 弹出项目选择（组合键设置会同时改为 **⌘⌥P**）。输入项目名、别名或路径筛选，用上下键和回车选择，也可按 **⌘1…9**。优先切到已打开的 IDEA 项目窗口，未找到可确认的窗口时请求编辑器打开该项目。

项目排序结合选择次数和最近选择时间，历史权重每 7 天减半，避免很久以前常用的项目长期占据首位；搜索精确匹配与前缀匹配优先。记录随项目设置保存在本机。

IDEA 已打开窗口先核对项目选择按钮提供的根目录。只有导入根和 IDEA 窗口的项目名称都唯一时才允许名称回退，同名工作树不猜。窗口查找有节点和耗时上限。

普通单击的行为不变。应用不会改写笔记、修改文件关联、注入 Claude、上传代码或持续读取鼠标位置。没有辅助功能权限时，手动定位框和菜单栏的剪贴板入口仍可使用。剪贴板入口只在主动选择后读取，悬停入口不会改动剪贴板。

设置窗口可以关闭，应用继续在菜单栏运行。项目可分别启停、移出范围、设置别名。项目移除只影响搜索范围，不删除项目文件。

快捷键没有识别到引用、没有匹配或索引尚未就绪时，仅在鼠标旁显示约 2.5 秒的提示，不会弹出主页面或抢焦点。候选窗口出现时暂时隐藏设置页，取消后回到原应用。配置过项目后，启动应用只常驻菜单栏；需要设置时主动选择“项目与设置…”。

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

目前方法声明定位优先支持 Java；其他语言仍支持文件、行和列。省略路径必须能在导入项目中匹配；同名项目或工作树不会仅凭最近使用记录自动选择。

## 性能与边界

- 按快捷键时才读取辅助功能信息；读取范围、超时、输入长度、引用数、候选源码大小都有上限。
- 项目索引在后台建立；跳转用内存字典按文件名、类名及路径查找，不进行全盘扫描，不调用 AI。
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

IDEA 收到命令与成功显示代码是两个阶段。若 IDE 自身卡顿、出现文件缓存错误或内存不足，需要先恢复 IDE 状态；CodeJump 不会自动重启 IDE。
