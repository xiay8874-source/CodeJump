# CodeJump

简体中文 | [English](README.en.md)

<img src="Assets/AppIcon.png" alt="CodeJump 图标" width="100">

原生 macOS 菜单栏应用，把 Claude、Obsidian 等应用里的代码引用，定位到 **IntelliJ IDEA、VS Code、Cursor 或 Zed**。

鼠标指向引用，按 **⌥J**。CodeJump 在已导入的本地项目中查找文件和符号；遇到同名类、方法重载或不确定的位置，会展示源码预览和候选。

## 下载与安装

- [下载最新版本](https://github.com/xiay8874-source/CodeJump/releases/latest)
- 系统要求：**macOS 14+**；已发布 DMG 面向 **Apple Silicon（arm64）**。
- 软件界面目前为中文，英文使用说明见 [English README](README.en.md)。

打开 DMG，将 `CodeJump.app` 拖入 Applications。启动后添加参与搜索的项目文件夹，选择默认编辑器，并在 **系统设置 → 隐私与安全性 → 辅助功能** 中启用 CodeJump。

当前发布使用固定本机证书签名，**尚未使用 Apple Developer ID 签名或 Apple 公证**。另一台 Mac 首次运行可能需要通过系统设置中的正常应用允许流程。签名私钥不包含在下载包里。

应用常驻菜单栏；关闭设置窗口不会退出。配置项目后，使用菜单栏或 **⌥H** 打开主页。

## 日常使用

| 快捷键 | 功能 |
|---|---|
| **⌥J** | 识别鼠标指向或选中的代码引用 |
| **⌥P** | 搜索并切换项目 |
| **⌥H** | 显示或收起主页与设置 |

设置中可统一改为 **⌘⌥J / ⌘⌥P / ⌘⌥H**；各快捷键独立注册。

1. 勾选需要搜索的项目，可以添加别名或临时限定项目范围。
2. 鼠标指向文件、类名、方法或链接，按 **⌥J**。
3. 唯一且已核验的结果可以直接打开；有歧义时展示候选和代码预览。
4. 用方向键、回车或数字键选择，Esc 取消。

项目切换会优先核对已打开的 IDEA 窗口，无法确认时请求编辑器打开项目。同名项目或工作树不会仅凭最近记录自动猜测。

没有辅助功能权限时，仍可使用手动定位和菜单栏的剪贴板入口。剪贴板仅在主动调用时读取；悬停功能不修改剪贴板。移除项目只改变搜索范围，不删除项目文件。

## 支持的引用

```text
src/main/java/com/example/Foo.java:128
src/main/java/com/example/Foo.java:128:8
Foo.java#L128-L140
Foo#process
com.example.Foo.process
```

Markdown 超链接可以隐藏长路径，保留简洁的可见名称：

```markdown
[Foo#process](src/main/java/com/example/Foo.java:128)
[shop-app / Foo#process](src/main/java/com/example/Foo.java:128)
```

同项目不必重复项目名；跨项目或有歧义时再添加。名称、路径和行号应与真实源码一致。普通点击仍由来源应用处理，CodeJump 使用 **⌥J** 读取链接并定位。

也支持本机 `file:///` 链接和可选专用协议：

```text
codejump://open?project=shop-app&path=src/main/java/com/example/Foo.java&line=128
```

专用协议始终先显示预览，不接受 shell 命令或网络文件。GitHub 等 `https://` 链接暂不自动映射到本地源码。

本地 Java 定位会核对方法声明、所属类及内部类，排除注释、字符串和方法调用；重载保持候选，旧行号与当前方法范围不一致时要求确认。其他语言支持文件、行号和列号定位。

裸方法名查询需要可选 IDEA 插件；未启用插件时使用 `Foo#process`。足够长的类名简写可得到明确标注的后缀候选，不会被视为精确命中。

## Claude Code 引用规则

主页 **Claude 代码引用 → 安装 / 编辑规则…** 支持安装、编辑、恢复推荐规则和移除。

- 点击保存才写入全局 `~/.claude/CLAUDE.md`，新开的 Claude Code 会话加载。
- 只更新 `<!-- CodeJump:begin -->` 与 `<!-- CodeJump:end -->` 之间的内容，保留其他指令。
- 保存或移除前，在 `~/.claude/codejump-backups/` 备份原文件。
- 检测外部修改冲突，不直接覆盖；恢复推荐只修改草稿，关闭窗口会保留未保存草稿。

该功能配置 **Claude Code**（含桌面端 Code 模式）的全局规则，不修改普通聊天偏好、账号或模型路由。推荐规则鼓励完整符号标签和相对路径链接，但不能保证模型每次完全遵循。规则内容和语言均可自行编辑。

## 可选 IDEA Companion

**CodeJump Companion 0.2.2** 适用于 **IntelliJ IDEA 2026.1（261.*）**。从 Release 下载 ZIP，在 **设置 → 插件 → 齿轮 → 从磁盘安装插件** 中选择；按 IDEA 提示重启，然后在 CodeJump 启用“使用可选 IDEA 插件”。

未连接时，可在 IDEA 执行 **Tools → Start CodeJump Bridge**。目标项目需要在 IDEA 中打开；插件关闭、未连接或 IDEA 正在索引时，本地文件定位仍然可用。

插件使用 Java PSI 查询类、裸方法名、重载参数、继承方法，以及依赖 JAR 的源码或反编译声明：

```text
java.lang.String.substring(int, int)
java.util.ArrayList.stream()
```

PSI 结果先展示候选，再打开当前声明。桥接仅监听随机 `127.0.0.1` 端口，要求每进程令牌并拒绝浏览器 Origin 请求；端点文件仅当前用户可访问，跳转目标会在 IDEA 内重新核验。

## 隐私与边界

- 解析和索引均在本机执行，不调用 AI、不上传源码，不向 Claude 注入程序或改写会话。
- 仅按快捷键时读取辅助功能文本；读取和重试次数有上限，不持续跟踪鼠标。
- 只索引已启用的项目根目录，跳过版本库内部文件、依赖/构建输出、二进制和符号链接目录。
- 来源应用决定能提供哪些文字和链接；无法准确读取时，可选中文字或使用手动定位。
- 项目偏好、最近跳转和索引保存在 `~/Library/Application Support/CodeJump/`。
- 最近识别信息只在内存中保留，除非主动导出反馈。反馈可能包含选中文字和项目路径，分享前请检查内容。
- 打开前重新检查文件和项目边界，编辑器通过参数数组启动，不拼接 shell 命令。

最近跳转表示请求已发送，不等于编辑器已确认显示目标。CodeJump 不会自动重启无响应的 IDE。

## 从源码构建

需要 macOS 14+、**Swift 6**、Apple Command Line Tools 和 Python 3。Swift 包没有第三方 package 依赖。

```sh
git clone https://github.com/xiay8874-source/CodeJump.git
cd CodeJump
./script/test.sh
./script/build_and_run.sh --build-only
```

产物位于 `dist/CodeJump.app`。仅构建模式允许临时 ad-hoc 签名；若希望保留辅助功能授权，不应使用该临时身份覆盖已安装版本。

需要长期本机安装时，可创建并导入自己的固定签名身份：

```sh
python3 script/local_signing.py --prepare
python3 script/local_signing.py --install
./script/build_and_run.sh --install
```

`--prepare` 生成本机私有材料；`--install` 将不可导出的专用私钥导入用户钥匙串，并删除临时密钥文件。系统钥匙串确认由用户本人完成，不修改系统根证书或 TLS 信任。这是本机签名，不等同于 Developer ID 分发或公证。

安装需要固定身份，旧应用备份在 `output/backups/`。切换签名身份可能需要重新授权，后续构建复用同一证书和应用身份。

使用已安装的 IDEA SDK 构建插件，再打包应用与插件：

```sh
python3 idea-plugin/build.py
python3 script/package_dmg.py
```

IDEA 不在默认位置时设置 `CODEJUMP_IDEA_APP`。DMG 和 SHA-256 文件输出到 `dist/`，打包脚本拒绝覆盖同名发布包。

## 项目结构与参与贡献

- `Sources/CodeJumpCore`：引用解析、项目索引、Java 定位、启动计划、Claude 指令区块管理。
- `Sources/CodeJump`：SwiftUI/AppKit 界面、辅助功能读取、快捷键与编辑器集成。
- `Sources/codejump-cli`：只读定位与性能检查。
- `idea-plugin`：可选 Java PSI 桥接；`Tests/CodeJumpCoreTests`：解析和行为回归测试。

欢迎提交 Issue 和 Pull Request。报告识别问题时，提供最小引用、来源应用/编辑器版本、期望结果和匿名化示例源码；请移除私人路径、聊天内容及凭据。影响行为的修改请运行 `./script/test.sh`。

## 许可证

采用 [MIT License](LICENSE)。
