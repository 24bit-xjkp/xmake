# 在 xmake 中实现 `qt_add_qml_module` 的计划

- 分支：`QML_AOT`
- 目标：在 `xmake/includes/qt/` 提供 `qt_add_qml_module(...)`，在 `xmake/rules/qt/` 提供 `qt.qml` 与 `qt.qml.resource` 两条规则，实现与 Qt CMake 集成 `qt_add_qml_module()` 中「QML 资源打包 + qmlcachegen AOT + qmltc + AOT 统计报告」等价的核心能力。
- 依据：本机 Qt 6.12.0 / Qt 5.15.19 工具实测、`/usr/lib/cmake/Qt6Qml/Qt6QmlMacros.cmake`（Qt 6.12 发行版，6027 行）以及当前 xmake checkout 的规则机制实测。

---

## 0. 关键修订与决策（最终版）

> 本实现经历十九轮反馈。§0.1（第二轮）、§0.2（第三轮，只覆盖 qrc 渲染）、§0.4（第四轮）、§0.5（第五轮）、§0.6（第六轮）、§0.7（第七轮）、§0.8（第八轮）、§0.9（第九轮）、§0.10（第十轮）、§0.11（第十一轮）、§0.12（第十二轮）、§0.13（第十三轮）、§0.14（第十四轮）、§0.15（第十五轮）、§0.16（第十六轮）、§0.17（第十七轮）、§0.18（第十八轮）与 §0.19（第十九轮，当前）是**当前实现**的最终决策；§3–§13 保留初版设计说明，与它们冲突处以 §0.1、§0.2、§0.4、§0.5、§0.6、§0.7、§0.8、§0.9、§0.10、§0.11、§0.12、§0.13、§0.14、§0.15、§0.16、§0.17、§0.18、§0.19 为准。

### 0.1 第二轮：实现后的优化（qrc 渲染已由 §0.2 更新）

| # | 要求 | 落实 |
|---|------|------|
| 1 | `qt_add_qml_module` 给 target 注入 `qt.qrc`，不再探测 rcc；qmltc 用到的 moc 同理，尽量复用已有规则的工具探测 | `qt_add_qml_module` 注入 `qt.qml`/`qt.qml.resource`/`qt.qrc`；`qt.qml` 静态依赖 `qt.moc`（§0.8）；rcc 来自 `qt.qrc.on_config` 的 `target:data("qt.rcc")`，moc 来自 `qt.moc.on_config` 的 `target:data("qt.moc")`；删除 `find_rcc`/`get_moc_flags`，qmltc 生成的头文件直接以 `qt.moc` 规则加入 target，在 build 阶段由 `qt.moc` 规则 moc + 编译 |
| 2 | `qt.qml` 增加文件后缀支持，`add_rules("qt.qml") + add_files("*.qml") + add_values(...)` 即可使用 | `set_extensions(".qml", ".js", ".mjs", ".qmldir")`；无后缀的 `qmldir` 在 `load.lua` 中按文件名绑定（`add_files("qmldir")` 即可）；示例工程 `tests/projects/qt/qml_module_rule`。`qt_add_qml_module` 仍用 `add_files(..., {rules = {"qt.qml", override = true}})` 显式绑定，避免扩展名规则重复加入同一 sourcebatch |
| 3 | 不在 config 阶段生成 qrc；config 只探测环境，prepare 时生成 | `qt.qml` 的 values 检查在 `load.lua`（§0.9）；§0.15 起 `on_config` 只做工具/能力断言，不生成 qrc；qrc/qmltc file map 在 prepare 阶段用 `qrc.write_if_changed(qrcfile, qrcdata)` 生成（内部用 `core.project.depend` 增量，§0.8）；qrc 交给 build 阶段的 `qt.qrc` 规则编译（loader 的 rsp 已在 §0.4 移除，参数改由 `winos.cmdargv` 处理） |
| 4 | 不往 `target:data` 塞源文件列表，prepare 时通过 sourcebatch 处理 | §0.16 起改为：`_get_setup()` 只创建一次并缓存在 `target:data("qt.qml.setup")`，其中包含完整模块文件列表；on_prepare/after_prepare 只读取缓存，不再重复构造 setup |
| 5 | 看 `on_prepare_files` 是否要加 `batch = true, distcc = true` | §0.16 起静态只注册 `on_preparecmd_file`；只有同时需要 qmlcachegen 和 qmltc 时，才由 `config.lua` 给当前 target 附加 `on_prepare_files(..., {jobgraph = true})`，因此不再需要 `batch = true`。`distcc` 仍不添加，因为它只作用于生成物被编译的阶段 |
| 6 | 工具查找用 `lib.detect.find_tool`，用 `version = true` 取版本，xmake 自带探测缓存，不在 `target:data` 重复缓存 | `utils.find_sdk_tool()` 统一调用 `find_tool(name, {paths = <SDK bindir/libexecdir>})`：`qmlcachegen`/`qmltc` 用 `version = true` 取版本，版本号直接用 `tool.version`；`qmlaotstats` 不支持 `--version`，用 `check = "--help"` 探测。不覆盖 detectcache 的 cachekey，探测失败后由用户执行 `xmake f -c` 重新探测。§0.15 起工具探测放在 `qt.qml` 的 `on_config` 阶段 |
| 7 | depvalues 支持 Lua table，不要强行转成字符串数组 | 所有 `cmds:add_depvalues()` 直接传 table（工具 argv、`-I` 目录列表等）；删除初版 config 中 `"key=value"` 形式的字符串 depvalues |
| 8 | 合并冗余函数（函数体短且只调用一次） | 删除 `qrcgen.lua`/`aotstatsgen.lua` 两个单函数脚本（qrc 直接写入、aotstats 列表用 `batchcmds:call` 内联）；合并 `_get_cppfiles`/`_add_cppfiles`；删除 `get_resource_path`/`get_tool_version`/`find_rcc`/`get_moc_flags` |
| 9 | 用 `lib.detect.has_flags` 判断工具是否支持某个选项 | `--only-bytecode` 直接探测；`--dump-aot-stats` 必须和 `--module-id=...` 一起探测（单独传入会以非 0 退出）；新增 `xmake/modules/detect/tools/find_qmlcachegen.lua`，使 `find_toolname` 能解析 `qmlcachegen`（`has_flags` 需要 `tool.name` 非空，否则会拼接 nil） |
| 10 | qmltc namespace 默认 nil：nil 时按 uri 自动生成；`""` 表示不传 `--namespace`（保持匿名命名空间） | `utils.get_setting()` 的 `namespace` 默认 nil；`qmltc.lua::add_generate()`：nil → `uri:gsub("%.", "::")`，`""` → 不追加 `--namespace`，其他字符串原样传入 |

实现评审后的补充修复：

- 工具查找修正 `ipairs({qt.libexecdir_host, ...})` 在首个 nil 处截断的问题；`find_program` 的 PATH 兜底结果会被丢弃（工具必须位于选中的 SDK 目录内），不覆盖 detectcache 的 cachekey，`has_flags` 带 `version = true`。
- 资源 qrc 改为在 prepare 任务图构建阶段同步生成（`qt.qml.resource` 的 `on_prepare_files` 使用 `{jobgraph = true}`），保证 qmlcachegen/qmltc 任务启动时 `--resource` 指向的 qrc 一定存在，不再依赖规则顺序。
- `qt.qml` 在 §0.15 起通过 `on_config` 探测工具；§0.17 起纯资源模块也会按 settings 探测，需要显式 `cachegen=false` 才不要求 qmlcachegen。
- `--dry-run`：当前工具命令由 `runcmds(dryrun=...)` 跳过，但 qrc/qmldir/scanfile 的 `depend.on_changed` 仍会同步写入（§0.13）；此前「完全不写文件」的设计未保留。
- AOT 关闭或没有 sidecar 时保留旧报告（§0.14）；§0.15 起移除 qmlimportscanner。删除 `has_resources`/`cachegendir` 等未使用字段。
- 工具/版本断言由 settings 直接触发（§0.17）：`cachegen=true` 就探测 qmlcachegen，`type_compiler=true` 就探测 qmltc，与是否存在对应源文件无关；`aot_stats=false` 时不再探测 qmlaotstats / `--dump-aot-stats`。
- `aot_stats=true` 但 AOT 被 values 关闭（`cachegen=false`/`only_bytecode`）时的 warning 只在 `load.lua` 打印一次（§0.9），prepare 任务不再重复。
- qrc/file map（以及 §0.4 之前的 loader rsp）按排序后的文件列表渲染；§0.15 起移除 qmlimportscanner。
- qmltc 生成文件名对嵌套路径追加哈希，避免展平后同名（`a/b.qml` vs `a_b.qml`）；moc 归属与 include 不受影响。

### 0.2 第三轮：qrc 自动生成改用 `core.base.xml`

| # | 要求 | 落实 |
|---|------|------|
| 1 | qrc 的自动生成（QML 模块 qrc、资源 qrc、qmltc file map）不再手写 XML 字符串，改用 xmake 自带的 `core.base.xml` 模块 | `xmake/rules/qt/qml/qrc.lua`：删除手写 `_escape()`，`generate_qrc()` 用 `xml.new()`/`xml.text()` 构建 `<RCC>` 节点树，再用 `xml.encode(doc, {pretty = true, indent = 2})` 生成文本；`write_if_changed(filepath, qrcdata)` 在内部生成文本并用 `core.project.depend` 增量（§0.8）；`prepare_qml.lua`/`prepare_resource.lua` 的调用点直接传 qrcdata |

要点：

- 转义交给 xml 模块（文本内容转义 `& < >`，属性值再转义 `"`），路径/alias 含 `&`、`<` 等字符时 qrc 仍然合法。
- 属性由 xml 模块输出并按渲染后的属性串排序（`alias` 在 `empty` 之前），`<qresource prefix="...">`、`<file alias="...">path</file>` 的排版（2 空格缩进、文本节点与标签同行）与手写渲染逐字节一致；普通路径下生成内容不变，不会引入额外的 rcc 重编译。
- 参考文档：<https://xmake.io/zh/api/scripts/extension-modules/core/base/xml.html>；实现：`xmake/core/base/xml.lua`（`xml.encode`），沙箱适配：`xmake/core/sandbox/modules/import/core/base/xml.lua`。

### 0.3 第一轮决策（保留，供参考）

| # | 反馈 | 计划落实 |
|---|------|----------|
| 1 | `qt_add_qml_module` 遇到无法按后缀分类的直接调用 `add_files` 添加，由 xmake 自带机制处理 | §4.2：在函数内按 pattern 后缀分类；`.qml/.js/.mjs/.qmldir` → `qt.qml`，其他明确后缀 → `qt.qml.resource`，**无法识别的 pattern 原样交给普通 `add_files(...)`（不带 rules）**，由 xmake 在 config 阶段以原生 `unknown source file: ...` / `cannot match ...` 机制报错或告警；不引入内部 value，也不做自定义 raise。注意：由于 `qt.qml` 现在带 `set_extensions`，`src/*` 这类 pattern 匹配到的 `.qml` 会按扩展名正常进入 `qt.qml`，只有无法识别扩展名的文件才会报 `unknown source file` |
| 2 | 使用 xmake 规则自带增量机制：qml 源文件变化时重新生成 qrc，从而自动触发 qrc 重新编译 | **已被 §0.1 第 3/8 条取代**：qrc 在 prepare 阶段用 `write_if_changed` 同步写入，不再有 `qrcgen` job；qml 内容变化时 qrc 内容与 mtime 不变，但 `qt.qrc` 规则会把 `rcc -list` 得到的资源文件加入 depfiles，rcc 仍会正确重编译；文件增删导致 qrc 内容变化时 qrc 被重写并触发 rcc |
| 3 | `aot_stats=true` 且 `only_bytecode=true` 时报 warning | §5.9：该组合输出 warning 并忽略 AOT 报告（不报错、不生成/更新报告，旧报告保留） |
| 4 | cachegen/qmltc 也基于 jobgraph；两步用不同 jobgraph 分组并行；生成 cpp 直接加入 target，由 c++ 规则编译 | §3.1–§3.3、§5.1：`qt.qml` 改为 `on_prepare_files(..., {jobgraph = true})`；qmlcachegen 与 qmltc 分属两组、组间无边；生成 cpp 用 `target:add("files", ..., {always_added = true})` 注册，build 阶段重扫任务图后由 `c++.build` 编译（qmltc 头文件改为用 `qt.moc` 规则注册，见 §0.1 第 1 条） |
| 5 | 恢复 aotstatsgen/qrcgen 独立脚本，并通过 `batchcmds:lua` 调用 | **已被 §0.1 第 8 条取代**：两个脚本已删除，qrc 直接写文件；aotstats 列表用 `batchcmds:call` 在 job 内联函数中生成，避免 lua 线程与其它子进程并发的问题 |
| 6 | 用 qmlimportscanner 建依赖图，按图决定重编译哪些 QML；每个 QML 源文件一套 depfiles/depvalues | §5.12；**§0.15 已移除 qmlimportscanner**，改为每个文件只依赖自身 |
| 7 | C++ 源文件生成的 depcache 命名 `<qmlfile>.d`；判断 depmtime 是否该用 QML 源文件 mtime | §5.12：cachegen 的 depcache=`target:dependfile(<qml 源文件>)`；结论是 **depmtime 仍用生成产物的 mtime**（qmltc 用 dependfile mtime），用 QML 源 mtime 会导致「改了自己不重建」/「永远重建」（§0.12 改为按工具产物命名 depcache） |

### 其它已确认的决策（保持不变）

- ~~`qt_add_qml_module` 通过 `add_rules("qt.qml", "qt.qrc", "qt.moc")` 激活规则；`qt.qml` 自身 `add_deps("qt.env", "qt.qrc", "qt.moc")`~~，已被 §0.6/§0.8 取代：`qt_add_qml_module` 注入 `qt.qml`/`qt.qml.resource`/`qt.qrc`，`qt.moc` 由 `qt.qml` 静态依赖。
- 新增 options：`qt.qml.discard`（默认 false）、`qt.qml.aot_stats`（默认 nil）。
- 默认打包原始 QML；`discard=true` 时 qrc 条目加 `empty="true"`。
- Qt 版本分层支持：cachegen 需 Qt ≥ 6.2、type_compiler 需 Qt ≥ 6.4，qrc-only 路径可用于 Qt5.15。
- 目录外文件警告，alias 使用相对工程根目录的路径并在 warning 中报告。
- ~~文件分类按后缀~~，已被 §0.6 取代：文件直接交给规则的后缀匹配；示例工程每个特性一个；示例 JS 需要类型标注。
- 静态库资源被链接器丢弃的问题由用户 `add_linkgroups(..., {whole = true})` 解决，不由 qt 规则处理。

### 0.4 第四轮：评审反馈

| # | 要求 | 落实 |
|---|------|------|
| 1 | `qt.qml.only_bytecode` 依赖 qmlcachegen 时不再强制开启 `qt.qml.cachegen`，改为忽略 `only_bytecode` 并警告 | `utils.get_setting()` 删除「`only_bytecode` 把 `cachegen` 强制为 true」的逻辑，改为在 `cachegen` 未启用时把 `only_bytecode` 置为 false（所有消费方都看到忽略后的值）；`load.lua` 在 load 阶段对用户显式设置的 `only_bytecode` 打印一次 warning：`qt.qml: qt.qml.only_bytecode is ignored because qt.qml.cachegen is disabled` |
| 2 | 不再生成 `setup.paths.loaderrsp`，改用 `core.base.winos` 的 `winos.cmdargv` 自动处理 loader 参数过长 | `utils.get_paths()` 删除 `loaderrsp`，`prepare_qml.lua::_write_files()` 不再写 rsp；`cachegen.add_loader()` 把 `--resource`/`--resource-name`/`-o` 与全部 QML 资源路径直接放进 argv，Windows 下用 `winos.cmdargv(args, {raw = true})` 在超过命令行长度限制时自动转成 `@<临时参数文件>`。`core.base.winos` 为此增加 `raw` 模式：逐行原样写入（不做 MSVC 式 `--opt value` 合并、不加引号/转义、按 UTF-8 写盘），因为 `qmlcachegen` 的 `@file` 是逐行解析且不会去引号（`argumentsFromCommandLineAndFile()`），保留旧 rsp 的语义 |

要点：

- loader 的 argv 仍然完整记录为 depvalues（qrc 路径 + 每个资源路径），不依赖临时参数文件做增量判断；depfiles 用生成的 qrc 文件，qrc 内容不变（文件列表不变）时 loader 任务照常跳过。
- 临时参数文件由 `winos.cmdargv()` 写到系统临时目录（`os.tmpfile()`），不落在工程目录，因此 `xmake clean`/`--dry-run` 不受影响；Windows 之外不调用 `winos.cmdargv()`，直接传 argv。
- `cachegen` 关闭时 `only_bytecode` 被忽略（§0.4），因此 `aotstats.get_aot()` 无需再处理该组合，也不会出现「以为开了 only_bytecode 但实际没开」的静默行为。

### 0.5 第五轮：qmltc 测试用例直接创建 C++ 对象

| # | 要求 | 落实 |
|---|------|------|
| 1 | 工作区中开启 qmltc 的测试用例不再用 `engine.load()` 加载 QML，而是直接创建 qmltc 生成的 C++ 对象 | `tests/projects/qt/qml_module_type_compiler/main.cpp`：包含 qmltc 生成的头文件 `Main.qml.h`（§0.19 起保留源文件名），在 `QQmlEngine` 就绪后直接构造 `MyAppNs::Main window(&engine)`，以 `window.isVisible()` 作为运行验收；删除 `<QQmlApplicationEngine>` 与 `engine.load(QUrl("qrc:/qt/qml/MyApp/Main.qml"))` |

要点：

- qmltc 生成的类在构造函数里通过 `QML_init()` 完成对象树创建、属性初始化与 QML 绑定建立，绑定求值依赖 qmlcachegen 生成单元在静态初始化时注册的 `QQmlPrivate::QmlUnitCacheHookRegistration`（loader cpp），因此直接构造不需要 `engine.load()`。
- `main.cpp` 能包含生成头，是因为 `qt.qml.on_prepare_files` 把 `<autogendir>/rules/qt/qmltc` 加入了 `includedirs`，Qt 私有头则由 `qt.quickapp` 提供；prepare 阶段先于 build 阶段，干净构建时头文件已生成（已用 `xmake clean` + 删除 `build/.gens`、`build/.deps` 的干净构建验证）。
- 该用例的运行时路径从「engine.load + qmlcachegen」变为「qmltc 生成的 C++ 对象」，从而真正校验 qmltc 产物参与编译、moc、链接与运行，而不只是检查生成文件是否存在。

### 0.6 第六轮：规则化收尾（qmldir 部分由 §0.7 调整）

> 本节是当前实现的最终决策，与 §3–§13 的旧描述冲突时以本节为准。

| # | 要求 | 落实 |
|---|------|------|
| 1 | `qt.qml.resource` 改为按后缀匹配，只支持 QML 中常用的资源格式 | 规则用 `set_extensions(...)` 注册图片（QImageReader/Qt Image Formats）、字体（TrueType/OpenType）、着色器（`.qsb`）、翻译（`.qm`）、音视频（QMediaFormat）、Qt Quick 3D（`.mesh`）和常用数据（`.json/.txt`）；不再靠显式 `{rules = ...}` 绑定任意后缀 |
| 2 | `qt.qml` 去掉 `.qmldir` 后缀 | `set_extensions(".qml", ".js", ".mjs")`，与 Qt 的 `QML_FILES` 定义一致 |
| 3 | qmldir 对非 QML 插件不是必须的，去掉构建流程中的 qmldir；import 目录走 values | 删除 qrc 中的 `qmldir` 条目、`-i <qmldir>` 参数、qrc 多 qmldir 警告和 `load.lua` 的无后缀绑定；`qt.qml.import` values 统一作为 `-I` import 目录传给 qmlimportscanner/qmlcachegen/qmltc |
| 4 | 添加文件时不再用 `rules` 指定规则 | `qt_add_qml_module` 只做 `add_rules("qt.qml", "qt.qml.resource", "qt.qrc")` + 普通 `add_files(...)`，文件由规则自带的后缀匹配分派；不支持的扩展名由 xmake 原生报 `unknown source file` |
| 5 | 非必要不使用 `always_added` | 生成的 qrc 在写入后再加入 target；生成的 cachegen/qmltc cpp、loader cpp 和 qmltc 头文件在 `after_preparecmd_files` 中确认存在后再加入 target；QML 规则不再使用 `always_added` |
| 6 | `qt_add_qml_module` 不统一注入 `qt.moc`，由 `qt.qml` 自己声明依赖 | `qt.qml` 静态 `add_deps("qt.env", "qt.qrc", "qt.moc")`；`load.lua` 只做 values 校验，不再动态 `rule_add`（§0.8 调整）；`qt_add_qml_module` 只注入 `qt.qml`/`qt.qml.resource`/`qt.qrc` |
| 7 | 参考其他规则，尽量不用 xmake 内部接口 | 生成逻辑改为标准的 `before_preparecmd_files` / `on_preparecmd_file` / `after_preparecmd_files` + `batchcmds`，删除 `private.utils.batchcmds`、手工 `jobgraph`、`target:data_set` 状态传递；qmlimportscanner 改用公开的 `core.project.depend` 同步增量扫描，确保在计算 depfiles 前得到最新依赖图（§0.11/§0.12 为并行生成重新引入 `private.utils.batchcmds` + jobgraph；§0.16 起 `target:data` 只用于缓存 setup，不用于传递工具探测结果） |

当前生命周期：

```
load:   qt.qml.on_load      校验 values；qt.moc 由 qt.qml 静态依赖
config: qt.env 探测 SDK；qt.qml.on_config 探测所需工具（§0.15）
prepare(before, 每 batch):  写 qml qrc/qmltc file map/qmldir 并加入 target；生成 loader
prepare(on, 每文件 job):    qmlcachegen 组 / qmltc 组独立并行（每个工具 job 独立 batchcmds）
prepare(cmd, 每 batch):     同一个 on_prepare 以 batchcmds 形式执行/收集命令
prepare(after, 每 batch):   把已生成的 cpp/qmltc header 加入 target；生成 AOT 报告
build:                      c++.build 编译生成的 cpp；qt.qrc 编译 qrc；qt.moc 处理 qmltc header
```

要点：

- `qt.qml.resource` 与 `qt.qml` 用 `add_orders("qt.qml.resource", "qt.qml")` 保证资源 qrc 在任何 qmlcachegen/qmltc 读取 `--resource` 之前写好。
- 每个 QML 文件的 qmlcachegen/qmltc job 使用独立 batchcmds 和独立依赖缓存（`target:dependfile(<cpp/header>)`，§0.12）；扫描输出在工具 job 启动前一定存在（§0.10），失败直接中止构建，不回退到「依赖全部模块文件」。
- 生成文件在 `after_preparecmd_files` 时已经存在，因此可以普通 `target:add("files", ...)` 加入；qmltc 头文件由 `qt.qml` 静态依赖的 `qt.moc` 规则处理，不再显式设置 `rules`。
- 如果某个模块确实需要在运行时被打包 `qmldir`（例如被其它模块 import），仍可用 `add_files("qmldir", {rules = "qt.qml.resource"})` 显式加入资源 qrc；这只是用户侧的可选兜底，不在 `qt_add_qml_module` 的自动流程中。
- §0.7 调整：启用 `type_compiler` 时，规则会自动生成并打包 qmldir；测试工程 `qml_module_type_compiler` 恢复 `import MyApp` 与跨文件组件，其余工程仍不 import 自身。

### 0.7 第七轮：为 qmltc 自动生成 qmldir（qmldir 写入由 §0.8 调整）

| # | 要求 | 落实 |
|---|------|------|
| 1 | 在 `before_preparecmd_files` 时，启用 `type_compiler` 就自动生成 qmldir | `qmltc.lua::write_files()` 在 `before_preparecmd_files` 阶段与 qml qrc 同步生成；不写源树、不加入 target files；`_write_qmldir()` 用 `core.project.depend` 保证内容不变时 mtime 不变（§0.8） |
| 2 | 参考 Qt CMake 的 qmldir 实现 | 只登记 `.qml` 且文件名首字母大写的组件（对应 `qt6_target_qml_sources()` 的 `^[A-Z]` 规则），条目格式为 `Type <major>.<minor> <path>`（如 `2.3.4` → `2.3`，按 semver 的 major.minor），路径含空白时加引号；build-time qmldir 用相对源文件路径，runtime qmldir 用 qrc alias 并带 `prefer :/qt/qml/<uri>/` |
| 3 | 需要时增加 values | 新增 `qt.qml.version`（默认 `1.0`，`qt_add_qml_module({version = "..."})` 注入），用 `core.base.semver` 校验/解析（§0.8），类型条目使用 `<major>.<minor>`；类型条目由 `.qml` 文件列表和 alias 推导，无需其他 value |

实现细节：

- 生成两个 qmldir：
  - `<autogendir>/rules/qt/qmltc/qmldir`：qmltc 的 `-i` 输入。类型路径相对 qmldir 目录，指向真实源文件；qmltc/qmlcachegen 的 depfiles 包含它，文件增删或改版本会触发重生成。
  - `<autogendir>/rules/qt/qml/qmldir`：打包进 qml qrc（`alias="qmldir"`），类型路径使用资源 alias，带 `prefer :/qt/qml/<uri>/`；即使 `discard=true` 也打包（`qrc.generate_qrc()` 支持按条目覆盖 `empty`）。
- qmlcachegen 也传 `-i <build-time qmldir>`，与 Qt CMake `qt6_target_qml_sources()` 生成的 qmlcachegen 命令一致。qmltc 生成的 `QML_init()` 在运行时会通过 qmlcachegen 单元执行 `import <uri>`；如果 qrc 中没有 qmldir，运行时报 `module "<uri>" is not installed`，并在 `QQmlEnginePrivate::createComponentRootContext()` 崩溃，因此 runtime qmldir 是 qmltc 自导入可运行的必要条件。
- qmldir 按空白分词，含空白的路径用双引号包裹；已实测 qmltc 能正确解析并匹配 file map，runtime qml 引擎也能加载带引号的 alias。嵌套目录（如 `sub dir/MyButton.qml`）同样验证通过。
- 测试：`qml_module_type_compiler` 恢复 `import MyApp 2.3` 与 `MyButton { text: "sum=" + Utils.sum(1, 2) }`，验证 qmltc 解析同模块类型、qmlcachegen AOT、runtime qmldir、`version` value；另验证路径含空格、嵌套目录 alias、新增 QML 类型、`discard + type_compiler`、`cachegen=false + type_compiler`、干净/增量/并行构建。
- 限制：qmldir 只登记 `.qml` 组件；`.js/.mjs` 仍通过 `import "xxx.js"` 使用；C++ `QML_ELEMENT` 类型需要 qmltypes（本规则不生成），因此 qmltc 仍不能解析模块内的 C++ 类型。

### 0.8 第八轮：增量生成与 semver

| # | 要求 | 落实 |
|---|------|------|
| 1 | `qrc.write_if_changed` 直接接收 qrcdata，内部生成写入字符串，并用 `core.project.depend` 实现增量，qrcdata 作为 depvalues | `qrc.lua::write_if_changed(filepath, qrcdata)` 在 `depend.on_changed()` 回调中调用 `generate_qrc(qrcdata)` 后写盘；depfile 为 `<qrc>.d`，files 为 qrc 自身，values 是 qrcdata 的扁平化列表（prefix、discard、每个 entry 的 alias/path/empty）；不再 `readfile` 比较内容 |
| 2 | qmldir 写入不用 `qrc.write_if_changed`，单独函数也用 depend 增量 | `qmltc.lua::_write_qmldir(filepath, lines)`；depfile 为 `<qmldir>.d`，files 为 qmldir 自身，values 为 qmldir 行列表；`_write_qmltc_qmldir()`/`_write_resource_qmldir()` 只构造行 |
| 3 | `qt.qml.version` 的校验和解析走 `core.base.semver` | `load.lua` 用 `semver.is_valid()` 校验；`qmltc.get_qmldir_version()` 用 `semver.new():major()/minor()` 生成 `<major>.<minor>`，如 `2.3.4` -> `2.3`；不再使用正则或 `gsub` |
| 4 | 尽可能去除防卫性代码 | `after_prepare()` 直接 `target:add("files", cppfiles)` / `target:add("files", headers)`，空表交给 xmake 处理；不再判断 `#cppfiles > 0`/`#headers > 0` |

> 版本差异：Qt CMake 默认把类型登记为 `<major>.0`（`qml_module_files_versions`）；本实现按本轮要求取 semver 的 `<major>.<minor>`，因此 `2.3.4` 生成 `2.3`。

工作区中同时调整的实现：

- `qt.qml` 改为静态依赖 `add_deps("qt.env", "qt.qrc", "qt.moc")`，删除 `load.lua` 里动态 `rule.rule("qt.moc")` + `target:rule_add()` 的代码；`qt_add_qml_module()` 只注入 `qt.qml`/`qt.qml.resource`/`qt.qrc`。
- `qt_add_qml_module()` 直接 `for _, arg in ipairs(args) do add_files(arg) end`，不再先展平到 `files` 表再添加。
- `prepare_qml.lua` 的导出函数改名为 `before_prepare` / `on_prepare` / `after_prepare`，分别对应 `before_preparecmd_files` / `on_preparecmd_file` / `after_preparecmd_files`（§0.11/§0.12 曾改为同一个 `on_prepare`；§0.16 起拆回 `on_preparecmd_file` 与双工具专用 `prepare_jobgraph`）。

增量语义：

- 生成的 qrc/qmldir 的 depend 缓存放在产物旁边（`<file>.d`），不依赖 `target:dependfile()`；`depend.on_changed()` 同时比较 dependfile 时间、输出文件 mtime 和 depvalues。输出被删除、qrcdata/行内容变化时重写；内容不变时不触碰 mtime。
- qrc 的 payload 文件内容变化不会触发 qrc 重写（qrcdata 只有路径），仍由 `qt.qrc` 的 `rcc -list` depfiles 触发 rcc 重编译。
- qmldir 的 depvalues 是行列表，新增/删除类型、修改版本都会重写；qmltc/qmlcachegen 的 depfiles 仍包含 qmldir，因此会重新生成。

### 0.9 第九轮：load 统一做 values 检查

| # | 要求 | 落实 |
|---|------|------|
| 1 | 把 `qt.qml` 的 `on_config` 检查合并到 `load.lua` | 删除当时的 `on_config`；`load.lua` 在 `on_load` 中完成 values 类型、URI、版本和矛盾检查。§0.15 起重新加入 `on_config`，只用于工具断言 |
| 2 | 直接根据 values 检查，不考虑 sourcefiles | `load.lua` 不再读取 `target:sourcebatches()`；`qt.qml` 规则被后缀匹配触发即说明存在可 AOT 编译的 `.qml/.js/.mjs`。`only_bytecode` + `cachegen=false`、`aot_stats=true` + (`cachegen=false`/`only_bytecode`) 等矛盾只在 load 中 warning |
| 3 | 工具/能力检查保留在 prepare | §0.15 起改为在 `qt.qml` 的 `on_config` 中执行（`cachegen.get_tool()` / `qmltc.get_tool()` / `aotstats.get_aot()`）；load 不探测工具，只做廉价 values 检查 |

要点：

- `aotstats.get_aot()` 删除 `aot.ignored` 状态，`aot_stats` 被 values 关闭的 warning 只在 load 打印一次。
- `qt.qml` 生命周期变为 `on_load` + 三个 prepare 阶段；§0.15 起增加 `on_config` 仅用于工具断言，config 仍不生成 qrc。
- `aot_stats=true` 与 `cachegen=false`/`only_bytecode` 的组合仍按原语义 warning 并禁用 AOT 报告，不报错。

### 0.10 第十轮：qmlimportscanner 扫描必须成功（已由 §0.15 移除）

| # | 要求 | 落实 |
|---|------|------|
| 1 | 不要在 `try` 块内执行 qmlimportscanner，允许错误向上传播 | `prepare_qml.lua::_scan_imports()` 直接调用 `os.iorunv()`，删除 `try`/`catch` 和失败 warning；扫描进程非 0 退出时由沙箱 `os.iorunv()` 直接抛错并中止构建 |
| 2 | 断言 qmlimportscanner 的输出非空 | 扫描成功后 `assert(outdata and outdata ~= "", "qt.qml: qmlimportscanner returned no output for %s", qmlfile)`；输出为空时不再删除旧 JSON 后继续构建 |
| 3 | 基于「扫描总是成功」简化下游 | `_scan_file()` 删除 `ok` 返回值与失败后清理 depend 缓存的逻辑；`_get_depfiles()` 直接 `json.loadfile(scanfile)`，删除 mtime 陈旧检查和「回退到全部模块文件」分支 |

要点：

- 扫描失败时 `depend.on_changed()` 不会写入 dependfile（`save()` 在回调成功后才执行），下次构建会重新扫描；构建本身在失败处直接中止，不会使用旧依赖图继续生成。
- `_scan_file()` 始终在 `_get_depfiles()` 之前执行；扫描输出缺失时 `lastmtime = os.mtime(scanfile) = 0` 会强制重扫（§0.13），因此计算 depfiles 时扫描 JSON 一定存在。
- 手工验证：给 `qt.qml.import` 传入不存在的目录时，`qmlimportscanner` 以非 0 退出，构建直接失败并打印 `qmlimportscanner: No such file or directory: ...`，不再打印 warning 后继续。

### 0.11 第十一轮：prepare 改为 jobgraph + batchcmd_files（由 §0.12 调整）

> §0.12 已将这里的两套导出函数合并为一个 `on_prepare`，并将 qmlcachegen/qmltc 拆成独立组；本节保留第十一轮的中间状态。

| # | 要求 | 落实 |
|---|------|------|
| 1 | `on_prepare` 改为 `on_preparecmd_files` 形式 | `prepare_qml.lua` 导出 `on_preparecmd_files(target, batchcmds, sourcebatch, opt)`，遍历 sourcebatch 中的文件，把同一套生成命令加入 batchcmds；`xmake.lua` 用 `on_preparecmd_files` 注册 |
| 2 | 使用 jobgraph 重构 | 同时注册 `on_prepare_files(..., {jobgraph = true})`：为每个 QML/JS 文件添加一个 job，job 内新建独立 `batchcmds` 并执行，文件之间并行且保留每个文件独立的依赖缓存；`on_preparecmd_files` 保留 batch 形式供命令收集 |
| 3 | 重构 `_get_depfiles`，去掉 depset | 不再维护 `depset`/`_add_depfile()`；先收集候选 depfiles，再 `path.normalize()` 后 `table.unique()` 去重。重复确实存在：当前文件自身 + `import <本模块 URI>`/目录 import 会再次带回该文件；`table.unique()` 保留首次出现顺序，依赖列表稳定 |

要点：

- `on_prepare_files` 的每个 job 使用 `private.utils.batchcmds.new()` 创建独立 batch，继续使用 `batchcmds` 的 depfiles/depcache/progress，因此 qmlcachegen/qmltc 的增量和进度显示不变；`on_preparecmd_files` 则把同一套命令加入外部传入的 batchcmds，用于 prepare 阶段以 buildcmds 收集命令的场景。
- `_get_module_setup()` 始终从 `target:sourcebatches()["qt.qml"]` 取完整的模块文件列表，避免 `xmake build Main.qml` 这类被过滤的 sourcebatch 导致 import/qmldir 依赖不完整；job 列表仍使用传入的 sourcebatch。
- §0.15 起 `setup.qmls` 直接是 `sourcefile -> entry` 字典，`_find_file()`/`setup.filemap` 已删除。
- `_prepare_file()` 统一完成扫描、qmlcachegen/qmltc 命令和 depcache 设置，两种 prepare 形式共用，避免逻辑分叉。
- §0.12 调整：两套导出函数合并为同一个 `on_prepare`，qmlcachegen/qmltc 拆成独立 jobgraph 组，depcache 改为按工具产物命名。

### 0.12 第十二轮：统一 jobgraph/batchcmds 入口，拆分工件组

| # | 要求 | 落实 |
|---|------|------|
| 1 | `{jobgraph = true, batch = true}` 时把 jobgraph 参数当 batchcmds 用 | `on_prepare(target, jobgraph, sourcebatch, opt)` 用 `jobgraph.add_orders`/`jobgraph.runcmds` 区分 jobgraph 与 batchcmds（与 `c++/modules/builder.lua` 的 `build_bmis()` 一致）；`on_prepare_files(..., {jobgraph = true, batch = true})` 和 `on_preparecmd_files(...)` 都调用该函数 |
| 2 | qmlcachegen 与 qmltc 放两个独立 jobgraph 组并行 | §0.15 起移除 importscanner 组；qmlcachegen 组和 qmltc 组各自逐文件建 job，两组之间没有边 |
| 3 | 拆分后每个工具独立增量 | qmlcachegen 的 depcache 改为 `target:dependfile(<生成的 cpp>)`，qmltc 改为 `target:dependfile(<生成的 header>)`；不再共用 `target:dependfile(<qml 源文件>)`，避免两个 job 并发写同一个依赖缓存 |
| 4 | 扫描输出缺失时仍能恢复 | `_scan_file()` 的 `changed` 加入缺失检查；§0.13 进一步改为 `lastmtime = os.mtime(scanfile)`，删除输出后 lastmtime=0 自动重扫 |

要点：

- 组结构：`qmlcachegen`/`qmltc` 各自的 job；两组之间不建边，因此可并行（§0.15 起不再有 importscanner 组）。
- jobgraph 模式下每个工具 job 创建独立 `batchcmds`：`_add_cachegen_job()` / `_add_qmltc_job()` 分别设置 depfiles、depcache、runcmds；batchcmds 模式（`jobgraph.runcmds`）只把命令加入外部 batchcmds，由调用方决定执行或收集。
- §0.15 起 `_get_depfiles()` 只返回当前文件（以及 type_compiler 下的 qmldir/map），不再有扫描 JSON。
- `_get_setup()` 不再在 jobgraph 构建阶段用 `os.isfile(resourceqrc)` 决定是否加入资源 qrc，而是按 `qt.qml.resource` sourcebatch 是否非空加入；资源 qrc 由 `qt.qml.resource` 的 before hook 在 `qt.qml` 之前生成，构造阶段文件可能尚未写出。
- 测试：clean 构建、`-j8`、no-op、touch `Main.qml` 只重生成 Main 的 cachegen/qmltc、touch `MyButton.qml` 重生成 Main+MyButton、删除扫描 JSON 后重建、`xmake project -k compile_commands`、非法 import 失败传播。

### 0.13 第十三轮：输出 mtime 作为 lastmtime，保留 dry-run

| # | 要求 | 落实 |
|---|------|------|
| 1 | qrc/qmldir 等自定义生成文件用输出 mtime 作为 lastmtime | `qrc.write_if_changed()` 和 `qmltc.lua::_write_qmldir()` 的 `depend.on_changed()` 增加 `lastmtime = os.mtime(filepath)`；输出文件被删除时 lastmtime=0，依赖检查会触发重写 |
| 2 | scanfile 用输出 mtime | （§0.15 已移除 qmlimportscanner，本节仅作历史记录）`_scan_file()` 增加 `lastmtime = os.mtime(scanfile)`，删除后自动重扫 |
| 3 | 工具输出用 set_depmtime | qmlcachegen 设置 `set_depmtime(os.mtime(cppfile))`；qmltc 因会保留未变化输出的 mtime，使用 `max(header mtime, dependfile mtime)`，header/impl/dependfile 任一缺失时为 0；删除 cpp/header 后自动重生成 |
| 4 | 删除 dry-run 参数（若可行） | **不可行**：实测 `batchcmds:runcmds()` 在 jobgraph job 中不会继承顶层 `--dry-run`，去掉 `dryrun` 会真的执行 qmlcachegen/qmltc。保留 `dryrun = option.get("dry-run")`，并验证 dry-run 不执行工具命令 |
| 5 | qrc 内容变化也要能触发重写 | `qrc.write_if_changed()` 新增 `_get_depvalues()`，把 prefix/discard + 每个 entry 的 `{alias, path, tostring(empty)}` 转成嵌套数组；修复前 `values = qrcdata` 被 `depend.is_changed()` 当成空数组，新增/删除 QML 文件时 qrc 不重写，现在会正确重写 |

要点：

- qrc/qmldir/scanfile 的 `depend.on_changed` 都同时设置 `lastmtime` 和 `changed = target:is_rebuilt()`；前者负责删除输出后的恢复，后者负责 `-r`。
- qmltc 的特例：Qt 对内容相同的输出保留 mtime，直接使用 header mtime 会让每次构建都判为变化；`max(header, dependfile)` 既保留输出 mtime 的语义，又保证生成基准不会倒退；header/impl 任一缺失都强制重生成。
- dry-run 探测：一个临时 jobgraph rule 在 `--dry-run` 下调用不带 `dryrun` 的 `batchcmds:runcmds()`，命令实际执行并创建了文件；因此不能删除该参数。
- `--dry-run` 的当前边界：工具命令由 `runcmds(dryrun=...)` 跳过执行；qrc/qmldir/scanfile 由 `depend.on_changed` 同步写入，没有 dry-run 参数，仍会写出。要做到完全无副作用，需要在这些生成入口另加 dry-run 检查，本轮按「可以的话」保留 `dryrun` 而不扩散处理。
- qrc 的 depvalues：实测新增 `Extra.qml` 时旧实现（`values = qrcdata`）不会重写 qrc，导致 qmlcachegen 报 `Failed to find a resource path`。`depend.is_changed()` 能比较一层嵌套数组（如 `{"prefix", {"alias", "path"}}`），但不会递归比较数组里的字典；因此 entry 用固定字段顺序的嵌套数组，`entry.alias`/`entry.path` 直接使用，`empty` 用 `tostring(entry.empty)` 保留 `nil`/`false`/`true` 三态。
- `table.values(entry)` 虽然能把字典转数组，但底层 `pairs` 顺序不稳定；实测会导致 qrc 每次构建都判为变化并重写，因此没有采用，改用固定字段顺序的数组。
- 测试：分别删除 qml qrc、资源 qrc、build-time/runtime qmldir、扫描 JSON、cachegen cpp、qmltc header 后重新构建，均自动恢复；随后 no-op 构建不再重生成；`--dry-run` 不执行 qmlcachegen/qmltc（但 qrc/qmldir/scanfile 仍会同步写入）。


### 0.14 第十四轮：按工具拆分实现模块，qmlaotstats 探测与报告语义

| # | 要求 | 落实 |
|---|------|------|
| 1 | 把 qmlcachegen、qmltc、qmlaotstats 的支持拆成独立提交/模块 | 新增 `xmake/rules/qt/qml/cachegen.lua`、`qmltc.lua`、`aotstats.lua`：分别负责工具探测/版本断言、输出路径、逐文件命令、生成物收集和报告；`prepare_qml.lua` 只保留 setup、qrc 和 jobgraph 编排，`utils.lua` 只保留共享的 values/alias/路径/工具查找/import 参数 helper（§0.15 进一步移除 importscanner） |
| 2 | qmlaotstats 探测改用 `check = "--help"`，不设置 cachekey | `utils.find_sdk_tool()` 对 `qmlcachegen`/`qmltc` 使用 `version = true`，对 `qmlaotstats` 使用 `check = "--help"`（§0.15 已移除 qmlimportscanner）；不覆盖 detectcache 的 cachekey。若之前探测失败，执行 `xmake f -c` 重新探测 |
| 3 | 没有 sidecar 时保留旧报告 | `aotstats.add_report()` 的 `batchcmds:call` 只列出实际存在的 sidecar；没有 sidecar 时直接返回，不调用 `qmlaotstats`，也不删除已有 `.aotstats`/`.aotstats.txt` |

附带的简化：

- `utils.get_autogen_dir()` 统一生成目录；`get_autogen_file()`、`cachegen`/`qmltc`/`aotstats` 共用。
- §0.15 起 `_collect_files()` 直接返回字典，`_find_file()`/`filemap` 已删除。
- `qrc.generate_qrc()` 改为局部函数，`write_if_changed()` 不再返回未使用的结果。
- `load.lua` 直接比较类型，删除重复的 semver 校验。
- AOT 报告在一次 `batchcmds:call` 中完成 sidecar 过滤、聚合和格式化；生成器模式不会导出该 call（与原有 prepare 生成模型一致）。

> 当前模块布局：
> - `cachegen.lua`：`get_tool()`、`get_output()`、`get_generated_files()`、`get_paths()`、`add_generate()`、`add_loader()`。
> - `qmltc.lua`：`get_tool()`、`get_qmldir_version()`、`get_outputs()`、`get_paths()`、`write_files()`、`add_generate()`、`get_generated_files()`。
> - `aotstats.lua`：`get_aot()`、`get_paths()`、`add_report()`。
> - `prepare_qml.lua`：`_get_setup()`、`_get_depfiles()`、`_add_*_job()`、`before_prepare()`、`on_prepare()`、`after_prepare()`（§0.15 起不再有 `_scan_file()`）。
> - `utils.lua`：`get_setting()`、`get_alias()`、`get_autogen_file()`/`get_autogen_dir()`、`find_sdk_tool()`、`has_tool_option()`、`add_import_args()`、`get_paths()`（QML 模块 qrc）；`get_needs()` 已在 §0.17 删除，`get_mangled_name()` 已在 §0.18 合并进 `get_autogen_file()`。


### 0.15 第十五轮：on_config 探测工具、字典化模块文件、去掉 importscanner

| # | 要求 | 落实 |
|---|------|------|
| 1 | 工具断言放到 `qt.qml` 的 `on_config` | 新增 `xmake/rules/qt/qml/config.lua`，通过 `on_config("config")` 直接根据 values 的 `cachegen`/`type_compiler` 调用 `cachegen.get_tool()`/`qmltc.get_tool()`/`aotstats.get_aot()`，结果存入 `target:data("qt.qml.tools")`/`target:data("qt.qml.aot")`；prepare 只读取结果，不再探测工具（§0.17 去掉按源文件判断的 `get_needs()`） |
| 2 | `setup.qmls` 改为字典，去掉 `setup.filemap` | `_collect_files()` 直接返回 `sourcefile -> file entry` 的字典；`utils.get_file_list()` 按 sourcefile 排序，供 qrc/loader/qmldir 等需要稳定顺序的地方使用；删除 `setup.filemap`、`_find_file()`，prepare 直接使用 `setup.qmls[sourcefile]` |
| 3 | 去掉 qmlimportscanner 依赖图 | 删除 `qmlimportscanner` 工具查找、`_scan_file()`、`_get_moduledeps()`、`_get_directorydeps()`、`qmlimportscanner` 输出/依赖缓存；每个生成源只依赖自己的 QML 文件（`type_compiler` 下 cachegen/qmltc 额外依赖生成的 qmldir，qmltc 还依赖 file map）。修改一个文件只会重新生成该文件，不再级联重生成 importer |
| 4 | 去掉目录导入支持 | 依赖图移除后不再解析 `import.type`，目录导入不再被追踪；qmlcachegen/qmltc 仍按 Qt 自身语义处理 import |
| 5 | 保持 qmlaotstats 的 `--help` 探测、无 cachekey、旧报告保留 | 同 §0.14 |

要点：

- §0.17 起工具选择只看 settings：即使没有任何 `.qml/.js/.mjs`，只要 `setting.cachegen`/`setting.type_compiler` 为 true 也会探测并断言对应工具；纯资源模块需要显式设置 `cachegen=false`（Qt5 的 qrc-only 路径）。
- on_config 运行在 `qt.env` 的 SDK 探测之后；cachegen/qmltc/qmlaotstats 的版本/能力断言都在配置阶段失败，而不是等到 prepare。
- 生成顺序：`utils.get_file_list()` 对字典 key 排序后再渲染 qrc/loader/qmldir，避免 Lua 字典无序导致生成物抖动。
- 增量语义变化：`qmlcachegen`/`qmltc` 的 depfiles 不再包含 import 目标文件，只包含自身（以及 `type_compiler` 下的 qmldir、qmltc file map）；改变被导入文件不会触发生成，C++ 编译阶段仍由编译器的依赖文件处理包含关系。
- `qmlimportscanner` 相关章节（§0.10、§0.12、§5.12）保留为历史记录，与 §0.15/§0.17 冲突处以 §0.15/§0.17 为准。

---


### 0.16 第十六轮：缓存 setup、单工具走 `on_preparecmd_file`、双工具才用 jobgraph

| # | 要求 | 落实 |
|---|------|------|
| 1 | 给 `_get_setup()` 加缓存，on_prepare/after_prepare 直接读取 | `_get_setup(target, sourcebatch)` 由 `before_prepare` 传入本次 prepare 的 sourcebatch 并构造 setup，然后 `target:data_set("qt.qml.setup", setup)`；`on_preparecmd_file`、`prepare_jobgraph`、`after_prepare` 直接读取 `target:data("qt.qml.setup")`，不再调用 `_get_setup` |
| 2 | 把 `on_prepare_files`/`on_preparecmd_files` 改成 `on_preparecmd_file` | `xmake/rules/qt/qml/xmake.lua` 静态只注册 `before_preparecmd_files`、`on_preparecmd_file`、`after_preparecmd_files`；`on_preparecmd_file` 逐文件把 qmlcachegen/qmltc 命令加入调用方传入的 batchcmds，不再手工创建 batchcmds |
| 3 | 只涉及 qmlcachegen 时不用 jobgraph | 默认 target 的 `qt.qml` 规则没有 `on_prepare_files`，普通构建直接走 `on_preparecmd_file`；每个文件由 xmake 分配独立 batchcmds，文件之间仍然并行，但规则本身不创建 jobgraph 分组 |
| 4 | 同时需要 qmlcachegen 和 qmltc 时用 jobgraph 并行两个工具 | `config.lua` 在 `tools.cachegen and tools.qmltc` 时克隆当前 target 的 `qt.qml` 规则，附加 `on_prepare_files`（`{jobgraph = true}`）并 `target:rule_add()` 替换该 target 的规则实例；`prepare_jobgraph()` 建立 qmlcachegen/qmltc 两个无依赖组，同一文件的 cachegen 和 qmltc 可并行。克隆只影响当前 target，其他 target 仍走 `on_preparecmd_file` |
| 5 | jobgraph 情况不再创建 `batchcmds.new({target = target})`，直接实现功能 | 新增 `cachegen.generate()` / `qmltc.generate()`：用 `core.project.depend.on_changed()` 做增量判断，在回调里直接 `os.mkdir()` + `os.vrunv()`，参数由 `get_args()` 统一构造；jobgraph job 只调用这两个函数，不再为每个文件创建 batchcmds |
| 6 | batchcmds 模式使用另一套实现 | `cachegen.add_generate()` / `qmltc.add_generate()` 仍负责把命令和 depfiles/depvalues/depmtime/depcache 加入 batchcmds；`on_preparecmd_file` 使用这一套实现，项目生成器以 buildcmds 收集命令时也走这里。两套实现共享 `get_args()`/`get_depfiles()`，避免参数和依赖不一致 |
| 7 | AOT 报告不应每次重建 | `aotstats.add_report()` 只把**当前存在**的 sidecar 加入报告和 depfiles；没有任何 sidecar 时直接返回并保留旧报告。报告按 setup.qmls 聚合；无改动构建不再重复生成 `*.aotstats` |

要点：

- `_get_setup()` 的缓存键是 target 级别的 `qt.qml.setup`，生命周期与一次 xmake 进程中的 target 一致。setup.qmls 来自 `before_prepare` 传入的 sourcebatch；`on_preparecmd_file`/`prepare_jobgraph`/`after_prepare` 只读缓存。若 before_prepare 收到过滤后的 sourcebatch（例如 `xmake --files=Main.qml`），qrc/loader/qmldir 也按该批次生成；此时同模块其他类型不在 setup 中，partial qmltc 构建可能无法解析它们，需要完整构建。
- 动态附加 `on_prepare_files` 使用 `rule:clone()`、`rule:extraconf_set()` 和 `target:rule_add()`，只替换当前 target 的规则实例；`target:data("qt.qml.jobgraph")` 防止重复附加。
- `prepare_jobgraph()` 在 before_prepare 任务执行之前构建任务图，因此 `_add_job()` 把 setup 读取延迟到 job 运行时；`prepare_jobgraph()` 只用 `target:data("qt.qml.tools")` 决定是否添加分组。
- 命令收集模式（`buildcmds`）下 xmake 会跳过 `on_prepare_files`，直接调用 `on_preparecmd_file`，因此生成器仍能拿到 qmlcachegen/qmltc 命令，不会执行 jobgraph。
- jobgraph 的直接执行路径同样处理 `--dry-run`：`depend.on_changed(..., {dryrun = ...})` 直接调用回调，回调只 `vprint()` 命令，不创建目录、不执行工具。
- `cachegen.add_generate()`/`qmltc.add_generate()` 现在自带 depfiles/depcache，`on_preparecmd_file` 不再依赖 prepare_qml 里的 job 辅助函数。
- `aotstats` 的 sidecar 过滤同时修复了之前把不存在的纯 JS sidecar 写入 depfiles、导致每次构建都判定为 changed 的问题。

验证：

- `qml_module`、`qml_module_type_compiler`、`qml_module_no_cachegen`、`qml_module_only_bytecode`、`qml_module_discard`、`qml_module_rule` 干净构建并运行成功。
- `qml_module_type_compiler`：`QML_DEBUG` 计数确认 setup 只创建一次；确认走 `prepare_jobgraph`；同时只修改 `MyButton.qml` 时只重新生成该文件的 cachegen/qmltc。
- `qml_module`：确认走 `on_preparecmd_file`；只修改 `MyButton.qml` 时只重新生成该文件的 cachegen。
- `cachegen=false + type_compiler=true` 的临时工程构建/运行成功，确认 qmltc-only 不走 jobgraph。
- 一个工程内同时存在 cachegen-only target 和双工具 target 时，两者都构建/运行成功。
- `--dry-run` 下打印 qmlcachegen/qmltc 命令但不创建生成物；`build.jobgraph:false`、`xmake project -k compile_commands`、无改动构建均通过。

---

### 0.17 第十七轮：工具选择只看 settings

| # | 要求 | 落实 |
|---|------|------|
| 1 | 去掉 `get_needs()` 判断，直接根据 settings 选择工具 | `config.lua` 不再调用 `utils.get_needs()`；`setting.cachegen` 为 true 就调用 `cachegen.get_tool()`，`setting.type_compiler` 为 true 就调用 `qmltc.get_tool()`，即使 target 没有任何 `.qml/.js/.mjs` |
| 2 | 删除按源文件判断的辅助函数 | 删除 `utils.get_needs()` 与只被它使用的 `utils.is_qml_source()`；`is_qmltc_file()` 仍保留，供 qmltc 逐文件过滤使用 |
| 3 | AOT 统计也直接看 settings | `aotstats.get_aot(target, setting, cachegen_tool)` 去掉 `needs` 参数，生效条件改为 `setting.cachegen and not setting.only_bytecode and setting.aot_stats ...` |
| 4 | 纯资源模块的行为 | 默认 `cachegen=true` 时，即使没有 QML 源文件也会探测/断言 qmlcachegen；纯资源模块需要显式 `cachegen=false`。`type_compiler=true` 同理 |

要点：

- 工具探测和版本断言发生在 `on_config`，不再依赖 `target:sourcefiles()`；配置阶段的行为只由 values 决定，和 target 实际包含哪些文件无关。
- `setup.qmls` 为空时，`before_prepare`/`on_preparecmd_file`/`after_prepare` 不会添加生成任务；但 `tools.cachegen`/`tools.qmltc` 仍然存在，双工具 target 仍会附加 jobgraph（只是没有 job）。
- `aot_stats` 仍要求 `cachegen` 开启；`aot_stats=true` 且 `cachegen=false` 时保持原有 warning/忽略语义。

验证：

- 六个 QML 工程干净构建并运行成功。
- `cachegen=false` 的工程不再探测 qmlcachegen；`type_compiler=false` 的工程不探测 qmltc。
- `aotstats.get_aot()` 调用点和参数已同步修改，AOT 报告生成/无改动跳过正常。

---

### 0.18 第十八轮：代码审查修正与 CMake 增量粒度对齐

| # | 要求 | 落实 |
|---|------|------|
| 1 | 以 `_` 开头的私有函数不需要再写 `local` | `aotstats.lua`、`config.lua`、`prepare_qml.lua`、`qmltc.lua`、`qrc.lua`、`utils.lua` 中的 `local function _*` 全部改为 `function _*`；`qrc.lua` 的 `generate_qrc()` 一并改为 `_generate_qrc()`，统一按模块私有函数处理 |
| 2 | load 阶段拒绝 `{cachegen = false, discard = true}` | 已在 qmlcachegen 的后续提交中加入 `load.lua` 断言：没有 qmlcachegen 时 QML 源既不会被编译也不会被打包，`discard` 会让模块丢失全部 QML 内容；该组合直接在 `on_load` 报错 |
| 3 | 判断 `get_mangled_name()` 是否必要，能删就删 | 删除 `utils.get_mangled_name()`，把路径/文件名处理合并进 `utils.get_autogen_file(target, dir, sourcefile, extension, opt)`；`opt.flat` 负责 qmltc 的展平+哈希命名。`qmltc.get_outputs()` 直接调用该函数，删除 `_get_name()` |
| 4 | 多个 QML 模块链接到同一可执行文件时 qrc 符号重复 | `utils.get_paths()` 的 qrc 文件名追加 `hash.strhash32(target:fullname())`，例如 `qml_module_<hash>.qrc`、`qml_resource_<hash>.qrc`；rcc 生成的 `qInitResources_*` 符号随文件名区分 |
| 5 | `find_sdk_tool()` 的 4 个 SDK 目录可能为 nil | 已在更早的 fix 提交中改为逐项检查后再插入，避免 Lua 表中间的 nil 截断 `ipairs`，也避免把 nil 传给 `find_tool`；host 目录仍然排在 target 目录之前 |
| 6 | 与 Qt CMake 的 QML 增量编译粒度对齐 | Qt CMake 的每个 qmlcachegen 输出都依赖自身源文件、模块 qrc、qmldir（以及 qmltypes），qmltc 还依赖 file map/qrc；因此**修改一个文件内容只重建该文件，增删模块文件会重建整个模块的生成物**。qmlcachegen 侧已在 qmlcachegen 的后续提交中把 `setup.resources`（模块 qrc、资源 qrc）加入 `get_depfiles()`；本轮给 `qmltc.get_depfiles()` 也加入 `setup.resources`，和已有的 qmldir/file map 一起实现相同粒度 |

要点：

- `get_autogen_file()` 的默认命名保留源目录和源文件名（§0.19 起不再替换 `.`）；`flat = true` 时仅对含子目录的路径展平并追加哈希，根目录文件保持 `Main.qml.h` 这类名字。
- qmlcachegen 本来就用 `--resource` 读取模块 qrc，但之前 depfiles 没有包含它们；补上后，新增/删除 `.qml/.js/.mjs` 或资源文件会重写 qrc，从而让所有 qmlcachegen 输出重新生成。仅修改文件内容时 qrc 不重写，仍只重生成该文件，和 CMake 的粒度一致。
- qmltc 同样通过 `--resource` 读取 qrc；`get_depfiles()` 加入 `setup.resources` 后，qrc 变化会重建全部 qmltc 输出，与 CMake 的 qmltc 依赖列表一致。
- qrc 文件名带 target fullname 哈希只影响生成文件/符号名，不影响资源前缀、alias 或运行时 URL。
- `find_sdk_tool()` 的目录过滤仍会拒绝 PATH 回退找到的其它 Qt SDK 工具。

验证：

- 六个 QML 工程干净构建并运行成功；`qml_module`、`qml_module_type_compiler` 的无改动构建通过。
- `qml_module`：只修改 `Main.qml` 时只重新生成 `Main.qml` 的 cachegen；新增/删除 `Added.qml` 时全部 cachegen 输出重新生成，恢复后无改动构建通过。
- `qml_module_type_compiler`：新增/删除 `Added.qml` 时全部 cachegen/qmltc 输出重新生成，运行通过。
- 两个静态 QML 模块（`mod_a`、`mod_b`）链接到同一个可执行文件，构建/运行成功；`nm` 确认 `qInitResources_qml_module_<hash>` 符号不同。
- `cachegen=false + discard=true` 的临时工程在 `xmake f` 阶段报出新增断言。

---

### 0.19 第十九轮：SDK 查找、import 路径与生成文件名

| # | 要求 | 落实 |
|---|------|------|
| 1 | 保留源文件名（原 “Keep source file names” 修复） | 不再把 `Main.qml` 变成 `Main_qml`：qmlcachegen 输出 `Main.qml.cpp`，qmltc 输出 `Main.qml.h`；qmltc 测试工程包含 `Main.qml.h` |
| 2 | `find_sdk_tool()` 过滤 nil SDK 目录 | `dirs` 逐项检查后再插入，host 目录仍然优先，避免 nil 截断 `ipairs` |
| 3 | 私有函数去掉冗余 `local` | 现有模块的 `local function _*` 改为 `function _*`；`generate_qrc()` 改为 `_generate_qrc()`；qmltc/aotstats 新增文件也直接使用模块函数 |
| 4 | `find_program` 缓存不包含 `paths` | `find_sdk_tool()` 给 `find_program` 传入由 SDK 目录哈希生成的 `cachekey`，切换 SDK 时不会复用另一个 SDK 的缓存程序 |
| 5 | 相对 import 路径基准错误 | `utils.get_setting()` 用 `target:scriptdir()` 把 `qt.qml.import` 转为绝对路径，`sub/xmake.lua` 中的 `{import = "imports"}` 会解析为 `sub/imports`，不再相对工程根目录 |

要点：

- qmltc 的 file map alias 和生成头文件中的跨组件包含使用源文件名，例如 `MyButton.qml.h`。
- 子目录中的 QML 仍会得到展平+哈希的 qmltc 输出名，因为 qmltc 用文件名包含其它组件的头文件，必须避免不同目录下的同名文件冲突。
- `find_sdk_tool()` 的 `cachekey` 只由 SDK 目录和工具名决定，不使用 `force`，保留正常探测缓存。
- `qt.qml.import` 的相对路径按声明 target 的 `xmake.lua` 所在目录解析，和 xmake 其它路径属性的语义一致。

验证：

- 六个 QML 工程干净构建并运行成功。
- `qml_module` 生成 `Main.qml.cpp`，`qml_module_type_compiler` 生成 `Main.qml.h` 并运行通过。
- 两个 SDK 目录切换时 `find_sdk_tool()` 不会复用另一个 SDK 的缓存；相对 import 的临时 `sub/xmake.lua` 工程能正确传入绝对 `-I` 路径。

---

## 1. 背景与目标

Qt 6 的 CMake 集成中，`qt_add_qml_module()` 负责：

1. 校验模块 URI，按 `QTP0001` 策略决定资源前缀（NEW：`/qt/qml/`）；
2. 把 `.qml/.js/.mjs` 与 `RESOURCES` 打包进 qrc，并在 NEW 策略下映射到 `:/qt/qml/<URI 点换斜杠>/...`；
3. 对 `.qml/.js/.mjs` 调用 `qmlcachegen` 做 AOT 编译并注册编译单元缓存（`qmlcache_loader.cpp`）；
4. 可选地对 `.qml` 调用 `qmltc` 生成 C++（需要 moc 与私有头）；
5. 可选地收集 AOT 编译统计（`qmlaotstats`，Qt 6.8+）；
6. 生成 qmldir/qmltypes/plugin 等模块元数据。

本计划实现 xmake 侧的 **打包 + AOT + qmltc + AOT 报告**，并在 qmltc 场景下自动生成 qmldir；不实现 plugin/qmltypes 自动生成、qmllint、部署等（见 §10）。§0.15 起不再使用 `qmlimportscanner` 建立构建期依赖图，增量只按文件自身计算。

> 注意：以下 §2–§13 是初版设计记录，其中涉及的 `qrcgen.lua`、`aotstatsgen.lua`、config 阶段生成 qrc/manifest 等做法已在第二轮优化中移除；`target:data("qt.qml.setup")` 曾在第二轮移除，§0.16 以 setup 缓存的形式重新引入；qrc 渲染已改为 `core.base.xml`（§0.2），loader 的 rsp 生成已移除（§0.4），qmltc 测试用例改为直接创建生成的 C++ 对象（§0.5），当前实现以 §0.1、§0.2、§0.4、§0.5、§0.6、§0.7、§0.8、§0.9、§0.10、§0.11、§0.12、§0.13、§0.14、§0.15、§0.16 为准。

---

## 2. CMake 侧调研摘要（实现依据）

参考：

- `qt_add_qml_module` 文档：<https://doc.qt.io/qt-6/qt-add-qml-module.html>（命令自 Qt 6.2 引入）
- `QTP0001` 策略：<https://doc.qt.io/qt-6/qt-cmake-policy-qtp0001.html>（Qt 6.5 引入，NEW 前缀 `/qt/qml/`）
- `QT_QML_GENERATE_AOTSTATS`：<https://doc.qt.io/qt-6/cmake-variable-qt-qml-generate-aotstats.html>（Qt 6.8.3 引入）
- 本机 Qt 6.12.0 的 `Qt6QmlMacros.cmake` / `Qt6CoreMacros.cmake`

### 2.1 资源布局（QTP0001 = NEW）

CMake 实测生成的 qrc：

```xml
<!-- QML/JS 文件 -->
<RCC><qresource prefix="/qt/qml/MyApp/">
  <file alias="src/Main.qml">/abs/src/Main.qml</file>
  <file alias="src/MyType.qml">/abs/src/MyType.qml</file>
</qresource></RCC>

<!-- qmldir（alias 固定为 qmldir，prefix 不带尾部斜杠） -->
<RCC><qresource prefix="/qt/qml/MyApp">
  <file alias="qmldir">/abs/build/MyApp/qmldir</file>
</qresource></RCC>

<!-- RESOURCES -->
<RCC><qresource prefix="/qt/qml/MyApp/">
  <file alias="src/data.txt">/abs/src/data.txt</file>
  <file alias="src/utils.js">/abs/src/utils.js</file>
</qresource></RCC>
```

要点：

- 资源路径 = `/qt/qml/<URI 点换斜杠>/<文件相对源目录路径>`；`Main.qml` 与模块目录同级时就是 `qrc:/qt/qml/MyApp/Main.qml`。
- **即使开启 AOT，原始 `.qml/.js/.mjs` 也始终打包进 qrc**；运行时按 qrc 路径加载，qmldir 也必须在 qrc 中。
- `DISCARD_QML_CONTENTS` 只是把 qrc 条目变成 `empty="true"`（rcc 接受该属性，已实测）。

### 2.2 qmlcachegen AOT

逐文件命令（实测，可手工复现）：

```sh
qmlcachegen --bare \
  --resource-path /qt/qml/MyApp/src/Main.qml \
  -I <target-binary-dir> -I /usr/lib/qt6/qml \
  -i <build>/MyApp/qmldir \
  --resource <qmake_MyApp.qrc> --resource <app_raw_qml_0.qrc> --resource <app_raw_res_0.qrc> \
  --dump-aot-stats "--module-id=MyApp(app)" \
  -o <build>/.rcc/qmlcache/app_src_Main_qml.cpp \
  <abs>/src/Main.qml
```

关键点（均已实测）：

- `-o` 的后缀决定模式：`.cpp` → 生成 C++；其他后缀 → 生成二进制 QV4 字节码（坑，必须用 `.cpp`）。
- C++ 模式必须提供 `--resource-path`（或 `--resource`），否则报 `No resource path for file: ...`。
- 每个文件额外生成 `<output>.cpp.aotstats` sidecar JSON。
- AOT 缓存注册文件 `qmlcache_loader.cpp`：

  ```sh
  qmlcachegen --resource-name qmlcache_<target> \
    -o <build>/.rcc/qmlcache/<target>_qmlcache_loader.cpp @<rsp>
  ```

  rsp 内容为重复的 `--resource\n<qrc>`，随后每行一个 QML 资源路径（`/qt/qml/MyApp/...`）。输出文件名必须以 `qmlcache_loader.cpp` 结尾。
  > xmake 实现不生成该 rsp，loader 参数直接作为 argv 传入（超长时由 `winos.cmdargv` 生成临时参数文件），见 §0.4、§5.7。
- `--only-bytecode` 与 `--dump-aot-stats` 互斥；实测该模式仍会自动写空的 `.aotstats` sidecar。

### 2.3 AOT 统计报告（Qt 6.8+）

```sh
qmlaotstats aggregate <target>.aotstatslist <target>.aotstats
qmlaotstats format   <target>.aotstats <target>.aotstats.txt
```

`format` 输出 `############ AOT COMPILATION STATS ############` 与 SUMMARY。

### 2.4 qmltc

```sh
qmltc --bare --header <build>/.qmltc/app/main.h --impl <build>/.qmltc/app/main.cpp \
  --namespace MyApp --module MyApp \
  -i <build>/MyApp/qmldir -I /usr/lib/qt6/qml \
  --resource <app_raw_qml_0.qrc> <abs>/src/Main.qml
moc -o <build>/.qmltc/app/moc_main.cpp <build>/.qmltc/app/main.h   # 必须
```

- 生成头里有 `Q_OBJECT`，必须 moc；生成 cpp 含 `<private/...>` 私有头。
- 实测：用「`prefix="/qt/qml/MyApp/"` + source 相对 alias」的普通 qrc 作为 `--resource` 即可满足 qmltc 的 resource mapper；跨文件 `import MyApp` 也通过，暂不需要 `--meta-resource`。
- xmake 的 `qt.quickapp`/`load.lua` 会自动加 `QtQml/<ver>/QtQml`、`QtQuick/<ver>/QtQuick` 等私有 include 目录，需在 type_compiler 示例工程验证。

### 2.5 Qt5/Qt6 工具差异（实测 5.15.19 / 6.12.0）

| 能力 | Qt 5.15.19 | Qt 6.12.0 |
|---|---|---|
| qmlcachegen | `/usr/bin`（bindir） | `/usr/lib/qt6`（**libexecdir**，不在 bindir） |
| qmlimportscanner | `/usr/bin`（bindir，无 `-output-file`） | `/usr/lib/qt6`（**libexecdir**，支持 `-output-file`） |
| `--bare/-i/-I/--only-bytecode/--dump-aot-stats/--resource-name` | 无 | 有 |
| qmltc | 无 | `/usr/lib/qt6/bin/qmltc` |
| qmlaotstats | 无 | `/usr/lib/qt6/qmlaotstats`（6.8+） |

=> 工具查找必须**只在当前选中 SDK 的目录**（bindir/libexecdir，含 host 变体）里进行，不能走 PATH。

---

## 3. 总体架构

### 3.1 xmake 规则机制约束（实测结论）

1. 仅通过 `add_files(..., {rules = ...})` 绑定的规则：build 钩子会执行，**`on_load`/`on_config` 不会执行**（规则不在 `target:orderules()`）。
2. 通过 `add_rules(...)` 加进 target 的规则：`on_load`/`on_config`/build 钩子都会执行。
3. `on_prepare_files(fn, {jobgraph = true})` 的回调 `(target, jobgraph, sourcebatch, opt)` 在 **prepare 阶段任务图扫描时**执行，此时可以向 jobgraph 添加 prepare 任务；prepare 任务执行完后进入 build 阶段，xmake 在 prepare 与 build 之间会**重新扫描一次任务图**。
4. 生成物进入编译的两种方式：
   - 在 prepare 回调里 `target:add("files", generated_cpp, {always_added = true})`，build 阶段重扫后由 `c++.build` 正常编译（本实现采用，Qt 私有 include 由 `qt.env` 提供）；
   - 手工 `target:objectfiles()`（旧做法，需要自己生成编译命令，已不再使用）。
5. `jobgraph:group(name, fn)` + `jobgraph:add_orders(a, b)` 给 prepare 任务分组/排序；两组之间没有边时并行执行（组→组依赖用 bridge 节点）。`add_orders` 的 `nil` 参数会被跳过，但不要传入「已声明却没有任何 job」的空组（会断言）。
6. `batchcmds:lua(scriptfile, argv)` 在**独立原生线程**里跑脚本；`batchcmds:call(func, argv)` 在 job 协程里 fork 沙箱执行函数。实测：多个 `batchcmds:lua` 线程**与其它起子进程的任务并发**时，脚本里 `os.iorunv()` 捕获子进程输出会**随机失败且不报错**（纯 lua 线程之间未复现；8 个 lua 任务 + 8 个 `cmds:vrunv` 并发，每轮 40 个结果丢 1–3 个），所以需要捕获输出的命令必须用 `batchcmds:call`；纯文件读写的生成脚本（qrcgen/aotstatsgen）用 `batchcmds:lua`。
7. `batchcmds:call(func, argv)` 会把 `opt` 表追加到 argv 末尾，函数签名不要用变参 `...`；fork 后模块级 `import()` 的全局不可见，需要的 `import()` 要写在函数体内。
8. 每个 prepare 任务用 `cmds:add_depfiles/add_depvalues/set_depmtime/set_depcache` + `cmds:runcmds({changed = target:is_rebuilt(), dryrun = ...})`，依赖未变化时整条命令跳过。
9. `set_extensions` **不支持 `.*` 通配**，`qt.qml.resource` 只登记 QML 常用资源后缀；`qt_add_qml_module` 逐项 `add_files(arg)`，不再显式 `{rules = ...}` 绑定。

### 3.2 规则激活方式

- `qt_add_qml_module()` 内部 `add_rules("qt.qml", "qt.qml.resource", "qt.qrc")`；`qt.qml` 静态 `add_deps("qt.env", "qt.qrc", "qt.moc")`：
  - `qt.qml`：获得 `on_load`（values 类型/URI/版本/矛盾检查，§0.9）、`before_preparecmd_files`/`on_preparecmd_file`/`after_preparecmd_files`；当同时需要 qmlcachegen 和 qmltc 时，`on_config` 给当前 target 克隆规则并附加 `on_prepare_files`（jobgraph）。实现分布在 `prepare_qml.lua`（setup 缓存/qrc/任务编排）、`config.lua`（工具断言与 jobgraph 启用）、`cachegen.lua`、`qmltc.lua`、`aotstats.lua`（§0.14、§0.15、§0.16）。
  - `qt.qrc`：提供 rcc 探测（`target:data("qt.rcc")`），并在 build 阶段编译生成的 qrc。
  - `qt.moc`：提供 moc 探测（`target:data("qt.moc")`），并在 build 阶段处理 qmltc 生成的头文件。
  - `qt.qml.resource` 用 `set_extensions(...)` 按 QML 常用资源后缀分派，资源 qrc 在 `before_preparecmd_files` 阶段生成，编译复用 `qt.qrc`。
  - QML/资源文件直接 `add_files(...)`，由规则的 `set_extensions` 分派（`.qml/.js/.mjs` → `qt.qml`，常用资源后缀 → `qt.qml.resource`）；`qt_add_qml_module()` 逐项调用 `add_files(arg)`，不再展平或显式 `{rules = ...}` 绑定。
- `qt.qml` 声明 `add_deps("qt.env", "qt.qrc", "qt.moc")`（保证 `target:data("qt")`/rcc/moc 在 prepare 前可用）。规则之间不再需要 `add_orders`：qrc/map 在 prepare 回调里同步生成，qmlcachegen/qmltc 任务执行时已存在。

### 3.3 生命周期时序

```
load:
  qt.qml.on_load -> values 类型/URI/版本/矛盾检查（不读 sourcebatch、不探测工具，§0.9）
config:
  qt.env.on_config -> 探测 Qt SDK；qt.qml.on_config -> 探测所需工具（§0.15）；
                      若同时需要 qmlcachegen/qmltc，给当前 target 附加 on_prepare_files（§0.16）
prepare:
  qt.qml.before_preparecmd_files -> _get_setup()：首次调用构造并缓存完整 setup；
                                    写 qml qrc/qmltc file map/qmldir（depend 增量）；加入 qml qrc；生成 loader
  qt.qml.on_preparecmd_file     -> 默认路径：逐文件把命令加入 batchcmds（cachegen-only / qmltc-only / 命令收集）
  qt.qml.on_prepare_files       -> 双工具路径：jobgraph 直接执行，qmlcachegen 组、qmltc 组独立并行
  qt.qml.after_preparecmd_files  -> 加入已生成的 cpp/qmltc header；生成 AOT 报告
  qt.qml.resource.before_preparecmd_files -> 生成资源 qrc 并加入 target
build:
  c++.build 编译生成的 cpp；qt.qrc 编译 qrc；qt.moc 处理 qmltc header
```

工具相关实现：`cachegen.lua`（qmlcachegen/loader，含 batchcmds 与直接执行两套入口）、`qmltc.lua`（qmltc/qmldir/file map）、`aotstats.lua`（AOT 报告）；`config.lua` 负责 on_config 工具断言和双工具 jobgraph 启用，`prepare_qml.lua` 负责 setup 缓存、qrc 和任务编排（§0.14、§0.15、§0.16）。

### 3.4 qrc 生成与增量

- qrc 在 prepare 阶段用 `qrc.write_if_changed(qrcfile, qrcdata)` 同步写入：depend 比较 qrcdata 的 depvalues 和输出 mtime，**内容未变不写**，不产生无关的 mtime 抖动。
- qml 内容变化（文件列表不变）时 qrc 内容/mtime 不变；rcc 的重编译由 `qt.qrc` 规则保证——它把 `rcc -list` 得到的资源文件（qrc 内实际引用的 `.qml/.js/.mjs/qmldir`）加入 depfiles，任一资源内容变化都会触发 rcc 重编译并重新链接。
- 文件增删/URI/discard 等变化会改变 qrc 内容 → qrc 被重写（mtime 前进）→ rcc 重编译。
- qmlcachegen/qmltc 的重生成由**每个 QML 文件自己的依赖图**决定（§5.12），不会「任一 qml 变化全部重生成」。
- 资源 qrc（`qt.qml.resource`）同样在 prepare 阶段生成；资源内容变化由 `qt.qrc` 规则的 depfiles 触发 rcc 重编译。

---

## 4. API 设计

### 4.1 `qt_add_qml_module(...)`（与 `add_files` 对齐的可变参数）

```lua
includes("@builtin/qt")

target("myapp")
    add_rules("qt.quickapp")
    add_files("main.cpp")

    -- 与 add_files 一致的变参风格，最后一个字典是 opt
    qt_add_qml_module("*.qml", "*.js", "assets/*.svg", {uri = "MyApp"})

    -- 也支持显式列表
    -- qt_add_qml_module({"Main.qml", "MyButton.qml", "assets/logo.svg"}, {uri = "MyApp"})
```

解析规则：

```lua
function qt_add_qml_module(...)
    local args = table.pack(...)
    local opt = {}
    if args.n > 0 and table.is_dictionary(args[args.n]) then
        opt = table.remove(args)
        args.n = args.n - 1
    end
    -- 展平每个参数（string 或 table）
    ...
end
```

### 4.2 文件分类与兜底（本轮反馈 1）

按 pattern 的**后缀**分类，无法识别的项直接交给 xmake 原生机制处理：

| pattern 后缀 | 处理方式 |
|---|---|
| `.qml` / `.js` / `.mjs` / `.qmldir` | `add_files(..., {rules = "qt.qml"})` |
| 其他明确后缀（`.png`、`.svg`、`.json`、`.txt`、`.ui` ...，且后缀中无 `*`） | `add_files(..., {rules = "qt.qml.resource"})` |
| 空后缀 / 后缀含 `*`（如 `src/*`、`*`、`*.*`、无扩展名文件） | **原样 `add_files(...)`（不带 rules），由 xmake 自带机制处理** |

实现要点：

- 函数只做「分类 + 交给对应规则/普通 add_files」，不做自定义 raise、不引入内部 value、不中止后续参数处理。
- xmake 原生行为（已实测）：
  - 无法识别但能匹配到文件的 pattern：`xmake f`/`xmake` 在 config 阶段报
    `error: unknown source file: <匹配到的文件>`；
  - 匹配不到任何文件的 pattern：`warning: cannot match add_files("<pattern>") in target(...)`。
- 注意：`src/*` 即使只匹配到 `.qml` 文件，也会因未绑定规则而报 `unknown source file`（原生机制）；这是预期行为，用户需要写成 `src/*.qml` 才能被 `qt.qml` 接收。

解析规则示例：

```lua
function qt_add_qml_module(...)
    local args = table.pack(...)
    local opt = {}
    if args.n > 0 and table.is_dictionary(args[args.n]) then
        opt = table.remove(args)
        args.n = args.n - 1
    end
    local qmlfiles, resfiles, unknown = {}, {}, {}
    for _, file in ipairs(table.wrap(args)) do
        local ext = path.extension(file):lower()
        if ext == ".qml" or ext == ".js" or ext == ".mjs" or ext == ".qmldir" then
            table.insert(qmlfiles, file)
        elseif ext ~= "" and not ext:find("*", 1, true) then
            table.insert(resfiles, file)
        else
            table.insert(unknown, file)
        end
    end
    ...
    add_rules("qt.qml")
    add_values(...)
    if #qmlfiles > 0 then add_files(qmlfiles, {rules = "qt.qml"}) end
    if #resfiles > 0 then add_files(resfiles, {rules = "qt.qml.resource"}) end
    if #unknown > 0 then add_files(unknown) end   -- 交给 xmake 自带校验
end
```

### 4.3 注入的 values

用户可见（`add_values`，规则端读取，默认值在规则端兜底）：

| value | 默认 | 含义/消费方 |
|---|---|---|
| `qt.qml.uri` | `target:name()` | 模块 URI；资源前缀 `/qt/qml/<uri 点换/>`、qmltc `--module`、AOT `--module-id` |
| `qt.qml.cachegen` | `true` | 是否启用 qmlcachegen AOT + loader |
| `qt.qml.only_bytecode` | `false` | qmlcachegen 的 `--only-bytecode`（要求 cachegen） |
| `qt.qml.type_compiler` | `false` | 是否额外用 qmltc 编译 `.qml` |
| `qt.qml.namespace` | `nil` | qmltc `--namespace`：nil=按 uri 自动生成（`MyApp.components` → `MyApp::components`），`""`=不传 `--namespace`（匿名命名空间），其他字符串原样使用；未开 type_compiler 时 warning 忽略 |
| `qt.qml.import` | `{}` | 额外 QML 模块搜索路径（qmlcachegen/qmltc 的 `-I`） |
| `qt.qml.discard` | `false` | true 时 qml qrc 条目加 `empty="true"` |
| `qt.qml.aot_stats` | `nil` | AOT 报告：nil=按 SDK 能力自动；true=必须生成否则 assert；false=跳过 |

约定：

- 多值用 `target:values(name)` 读取，取最后一个；列表值展平。
- 一个 target 视为一个 QML 模块；多次调用合并文件；URI 冲突在 `on_load` assert。
- `only_bytecode=true` 要求 `cachegen=true`（默认就是 true）；显式 `cachegen=false` 时忽略 `only_bytecode` 并在 load 阶段 warning（§0.4）。

---

## 5. 规则实现细节

### 5.1 `qt.qml`

```lua
rule("qt.qml")
    add_deps("qt.env", "qt.qrc", "qt.moc")
    set_extensions(".qml", ".js", ".mjs")
    on_load("load")                 -- values 类型/URI/版本/矛盾检查（不读 sourcefiles）
    before_preparecmd_files(...)    -- 按需探测工具/能力，写 qrc/map/qmldir
    on_prepare_files(..., {jobgraph = true, batch = true}) -- on_prepare(jobgraph)
    on_preparecmd_files(...)        -- on_prepare(batchcmds)，批量添加/收集命令
    after_preparecmd_files(...)     -- 注册生成物、AOT 报告
```

`on_load("load")`：

- 校验 `qt.qml.uri`（非空、无 `/`、无空白）、opt 类型、`namespace` 与 `type_compiler` 组合、每个 target 只允许一个 URI。
- 只做不依赖 Qt SDK 的廉价检查（load 阶段不执行 qmake、不探测工具）。
- 只检查 values 本身（类型、URI、版本、`only_bytecode`/`cachegen`/`aot_stats`/`namespace` 矛盾），不读取 `sourcebatch`，也不探测工具（§0.9）。

`on_config("config")`（§0.15）：

1. 读取 values/默认值（`utils.get_setting()`）。
2. 直接根据 `setting.cachegen` / `setting.type_compiler` 判断是否需要生成器，不再检查源文件（§0.17）。
3. 查找工具并做版本断言（§5.3、§6）：
   - `setting.cachegen` → `cachegen.get_tool()`：`assert(sdkver >= 6.2)`、找到 `qmlcachegen`、检查 `--only-bytecode` 能力；
   - `setting.type_compiler` → `qmltc.get_tool()`：`assert(sdkver >= 6.4)` 且找到 `qmltc`。
4. `aotstats.get_aot(target, setting, tools.cachegen)` 解析 `aot_stats` 语义（§5.9）；`aot_stats=true` 被 values 关闭的 warning 已在 load 打印。
5. 结果存入 `target:data("qt.qml.tools")` / `target:data("qt.qml.aot")`，prepare 阶段只读取，不再探测工具。

`prepare_qml.lua::before_prepare` 回调（`before_preparecmd_files`）：

1. 从回调的 `sourcebatch` 收集 qml 文件（不再从 `target:data` 读取），计算 alias/资源路径；目录外文件 warning（§5.4）。`setup.qmls` 是 `sourcefile -> entry` 的字典（§0.15）。
2. 用 `qrc.write_if_changed(qrcfile, qrcdata)` 同步写 qml qrc；`type_compiler` 时调用 `qmltc.write_files()` 写 file map、build-time/runtime qmldir。两者都用 `core.project.depend` 增量（§0.8），loader 的参数不再写文件，见 §5.7。
3. `target:add("files", qrcfile)`，build 阶段由 `qt.qrc` 规则编译。
4. `prepare_qml.lua::after_prepare` 中直接 `target:add("files", <cachegen cpp + loader cpp + qmltc cpp/header>)`；cachegen/qmltc 的生成物分别由 `cachegen.get_generated_files()` / `qmltc.get_generated_files()` 收集；qmltc 的 header 由 `qt.qml` 静态依赖的 `qt.moc` 规则处理（§5.8），不再使用 `always_added`。
5. §0.15 起不再有 importscanner 组；`cachegen` 时每个 `.qml/.js/.mjs` 一个 qmlcachegen job（§5.6）；loader 在 before 阶段由 `cachegen.add_loader()` 生成（§5.7）。
6. `aot_stats` 生效时，`after_prepare` 调用 `aotstats.add_report()`（§5.9）；报告在 qmlcachegen 完成后执行。
7. `type_compiler` 且存在 `.qml`：qmltc 独立组（§5.8），命令由 `qmltc.add_generate()` 生成，与 qmlcachegen 组无公共边。
8. qmlcachegen 组与 qmltc 组之间**没有边**，可并行。
9. 每个任务记录自己的 depfiles/depvalues/depcache/depmtime（depvalues 直接传 Lua table）；depfiles 只包含当前文件（以及 type_compiler 下的 qmldir/map），不做 import 级联。

### 5.2 `qt.qml.resource`（保持文件绑定）

```lua
rule("qt.qml.resource")
    add_deps("qt.qrc")              -- 直接 add_rules("qt.qml.resource") 时注入 rcc 探测
    set_extensions(...)
    add_orders("qt.qml.resource", "qt.qml")
    before_preparecmd_files("prepare_resource") -- 同步生成，qmlcachegen/qmltc 启动时一定存在
```

`prepare_resource.lua::main(target, batchcmds, sourcebatch, opt)` 流程（`batchcmds`、`opt` 未使用）：

1. 从 sourcebatch 取资源文件；计算 alias/资源路径；目录外 warning。
2. 生成资源 qrc：`<autogendir>/rules/qt/qml/qml_resource.qrc`（prefix `/qt/qml/<URI 点换/>/`，绝对路径 payload + alias），调用 `qrc.write_if_changed(qrcfile, qrcdata)`，由 `core.project.depend` 判断是否重写。qrc 由 `qrc.generate_qrc()` 基于 `core.base.xml` 渲染（§5.5、§0.8）。
3. `target:add("files", qrcfile)`；不再兜底探测 rcc，而是断言 `target:data("qt.rcc")` 存在并提示用户 `add_rules("qt.qrc")`（`qt_add_qml_module`/`qt.qml` 已注入）。
4. 编译复用 `qt.qrc` 规则；资源内容变化由 rcc depfiles 触发重编译。

### 5.3 工具查找与版本断言

- 搜索目录（去重、host 优先，逐个判断非 nil 后再加入）：`qt.libexecdir_host, qt.bindir_host, qt.libexecdir, qt.bindir`。
- 统一用 `lib.detect.find_tool(name, {paths = <SDK 目录>})`：`qmlcachegen`/`qmltc` 用 `version = true` 取版本，版本号直接取 `tool.version`；`qmlaotstats` 不支持 `--version`，用 `check = "--help"` 探测。结果由 xmake detectcache 缓存，不写 `target:data`；不覆盖 cachekey，探测失败时由用户执行 `xmake f -c` 重新探测。
- `find_program` 在 paths 找不到时会回退到 PATH，因此查找结果还要校验 `tool.program` 位于 SDK 目录内，否则视为「SDK 中没有该工具」（避免混用另一个 Qt 版本的工具）。
- 按 settings 查找：`cachegen.get_tool()`（qmlcachegen/`--only-bytecode`）、`qmltc.get_tool()`（qmltc）、`aotstats.get_aot()`（qmlaotstats/`--dump-aot-stats`）；§0.15 起这些断言在 `qt.qml` 的 `on_config` 中执行，§0.17 起不再根据源文件过滤；rcc/moc 分别由 `qt.qrc`/`qt.moc` 规则提供。
- 能力探测用 `lib.detect.has_flags`：`--only-bytecode`；`--dump-aot-stats` 和 `--module-id=...` 一起探测（单独传会以非 0 退出）。为使 `has_flags` 能解析工具名，新增 `xmake/modules/detect/tools/find_qmlcachegen.lua`。
- 版本断言位置：`qt.qml.version` 在 `qt.qml.on_load` 用 `core.base.semver`；qmlcachegen/qmltc 版本在各自 `get_tool()` 中检查，并在 on_config 阶段失败。
- §0.15 起不再查找/使用 `qmlimportscanner`。

### 5.4 资源路径与告警

- 目录内文件：`alias = path.relative(target:scriptdir(), abs_file)`。
- 目录外文件：`wprint` 警告（警告文本包含最终 alias）；alias 使用相对工程根目录的路径（`path.relative(os.projectdir(), abs_file)`），保证 qrc 合法。
- 资源路径 = `/qt/qml/<uri 点换/>/<alias>`。
- qmldir：§0.7 起，`type_compiler` 下由规则生成 build-time qmldir（qmltc/qmlcachegen 的 `-i` 输入）和 runtime qmldir（打包进 qml qrc，`alias="qmldir"`，不受 `discard` 影响）；不再有多个 qmldir 的 warning。非 `type_compiler` 的用户 qmldir 兜底见 §10。

### 5.5 qml qrc 生成（prepare 阶段）

- `xmake/rules/qt/qml/qrc.lua`：共享渲染模块；`generate_qrc()` 用 `core.base.xml` 构建 `<RCC>` 节点树并 `xml.encode()`（转义与属性排序交给 xml 模块，见 §0.2），`write_if_changed(filepath, qrcdata)` 用 `core.project.depend` 判断是否写盘（§0.8）。
- prepare 回调里直接从 sourcebatch 得到 qrcdata 并调用 `write_if_changed`；不再有 manifest 文件和 `qrcgen.lua` 脚本。
- 源文件列表先 `table.sort()` 再渲染（qrc/file map），保证生成内容与顺序稳定，不会因文件枚举顺序变化触发无谓的重编译。
- 增量语义（§3.4）：qrc 内容变化（文件增删/URI/discard）才重写并触发 rcc；qml 内容变化由 `qt.qrc` 的 depfiles（rcc -list 的资源文件）触发 rcc 重编译。
- `discard=true` 时 qrc 条目加 `empty="true"`。

### 5.6 qmlcachegen 命令模板

```sh
<qmlcachegen> --bare \
  --resource-path /qt/qml/<URI path>/<alias> \
  -I <qt.qmldir> [-I <qt.qml.import>...] [-i <qmldir>...] \
  [--resource <qml.qrc>] [--resource <resource.qrc>] \
  [--only-bytecode] \
  [--dump-aot-stats "--module-id=<URI>(<target>)"] \
  -o <autogendir>/rules/qt/qmlcachegen/<mangled>.cpp \
  <abs qml/js/mjs file>
```

- `<name>`：保留相对目录结构和源文件名（`src/Main.qml` → `src/Main.qml.cpp`）；目录外文件用 `<hash32>_<basename>.cpp`。§0.19 起不再把扩展名的 `.` 换成 `_`。
- 输出目录：`target:autogendir()/rules/qt/qmlcachegen/`。
- 每个文件独立记录增量信息：
  - **depfiles**：该 QML/JS 文件自身（`type_compiler` 下再加模块 qmldir 文件）；不再包含 import 目标（§5.12）；
  - **depvalues**：`qmlcachegen` 路径 + 完整 argv（`-I/-i/--resource/--module-id` 等，工具或参数变化即重生成）；
  - **depcache**：`target:dependfile(<生成的 cpp>)` → `<mangled>.cpp.d`（每个工具独立缓存，见 §0.12）；
  - **depmtime**：生成 cpp 的 mtime；cpp 被删除时为 0，强制重生成（§0.13）。
- 生成 cpp 由 `c++.build` 编译（不手工插 `target:objectfiles()`）。

### 5.7 loader

```sh
<qmlcachegen> --resource-name qmlcache_<target> \
  -o <autogendir>/rules/qt/qmlcachegen/<target>_qmlcache_loader.cpp \
  --resource <qml.qrc> [--resource <resource.qrc> ...] \
  <qml resource path>...
```

- 不再生成 `<target>_qml_loader_file_list.rsp`（§0.4）：重复的 `--resource` + qrc 路径、每个 QML 资源路径都直接作为 argv 传给 qmlcachegen，参数顺序与旧 rsp 内容一致。
- Windows 下 argv 可能超过命令行长度限制，`cachegen.add_loader()` 用 `winos.cmdargv(args, {raw = true})` 自动把它转成 `@<os.tmpfile()>.args.txt`；`raw` 模式逐行原样写入（不合并 `--opt value`、不加引号、UTF-8 编码），因为 qmlcachegen 的 `@file` 是逐行解析、不会去引号（Qt `argumentsFromCommandLineAndFile()`）。其它平台直接传 argv。
- 增量：depfiles = 生成的 qrc 文件（`setup.resources`，文件列表不变时它们不被重写，loader 因此可跳过），depvalues = 工具 + 完整 argv（Lua table，含 qrc 路径与资源路径），depcache = `target:dependfile(<loader cpp>)`，depmtime = loader cpp mtime；临时参数文件不参与依赖判断。
- loader cpp 由 `c++.build` 编译；输出文件名必须以 `qmlcache_loader.cpp` 结尾。

### 5.8 qmltc + moc

> §0.7 / §0.14：qmltc 相关实现集中在 `xmake/rules/qt/qml/qmltc.lua`（工具、输出命名、file map/qmldir、命令、生成物收集）；`-i` 的 qmldir 由规则生成在 `<autogendir>/rules/qt/qmltc/qmldir`，并同时传给 qmlcachegen。

```sh
<qmltc> --bare \
  --header <autogendir>/rules/qt/qmltc/<rel>.h \
  --impl   <autogendir>/rules/qt/qmltc/<rel>.cpp \
  --module <URI> [--namespace <namespace>] \
  -i <autogendir>/rules/qt/qmltc/qmldir -I <qt.qmldir> [-I <qt.qml.import>...] \
  [--resource <qml.qrc>] [--resource <resource.qrc>] \
  <abs qml file>

# qmltc header 在 build 阶段交给 qt.moc 规则处理（生成 moc_<rel>.h.cpp 并编译）
```

- 输出目录：`target:autogendir()/rules/qt/qmltc/`；`--header/--impl` 用绝对路径。
- `namespace` 语义（需求 10）：默认 nil → 用 uri 生成（`MyApp.components` → `MyApp::components`）；`""` → 不传 `--namespace`，保持 qmltc 匿名命名空间行为；其他字符串原样传入。
- moc 不再由 qml 规则自己执行：qmltc 生成的 header 在 `after_preparecmd_files` 中普通加入 target（§0.6，不再用 `always_added`），build 阶段由 `qt.qml` 静态依赖的 `qt.moc` 规则生成 moc 源并编译；prepare 阶段把 `<autogendir>/rules/qt/qmltc` 加入 `includedirs`，供 moc 源 `#include "<header>"` 使用。
- 增量：qmltc 任务 depfiles = 该 QML 的依赖图结果（§5.12）+ qmltc file map，depvalues = 工具 + argv（Lua table），depcache = `target:dependfile(<生成的 header>)`；depmtime = `max(header mtime, dependfile mtime)`，两者缺失时为 0（Qt 会保留未变化输出的 mtime，§0.13）。
- moc 任务的增量由 `qt.moc` 规则负责（depfiles = qmltc header，depcache = `target:dependfile(<moc object/cpp>)`）。
- qmltc 输出文件名把路径分隔符展平；嵌套路径（如 `a/b.qml`）会追加路径哈希，避免与 `a_b.qml` 等展平后同名的文件冲突。
- 类型注册（qmltyperegistrar/plugin）不在本次范围。

### 5.9 AOT 统计报告

- 生效条件：`setting.cachegen=true` **且** `only_bytecode=false` **且** `aot_stats` 解析为真；`aot_stats=true` 但 AOT 被 values 关闭时的 warning 只在 `load.lua` 打印一次（§0.9）。
- `aot_stats` 语义：
  - `nil`（默认）：SDK 支持（找到 `qmlaotstats` 且 qmlcachegen 支持 `--dump-aot-stats`）则生成，否则静默跳过；
  - `true`：不支持则 `assert` 报错（提示需要 Qt 6.8+ 或设置 `aot_stats=false`）；
  - `false`：跳过。
- `only_bytecode=true`：不生成/更新报告，已有报告保留；若显式 `aot_stats=true` → **warning** 并忽略。
- 流程：逐文件加 `--dump-aot-stats --module-id=<URI>(<target>)` → `batchcmds:call` 内联函数在 cachegen 完成后只列出**当前存在**的 sidecar，并依次执行 `qmlaotstats aggregate` → `qmlaotstats format` → 输出到 `.../rules/qt/qmlcachegen/<target>.aotstats[.txt]`。
- 任务排在 qmlcachegen 组之后（`qmlcachegen -> aotstats`）；`.mjs`/纯 `.js` 模块可能没有 sidecar；没有 sidecar 时保留旧报告并且不调用 `qmlaotstats`（§0.14）。
- `qmlaotstats` 没有 `--version`，用 `check = "--help"` 探测；detectcache 的失败结果不会自动失效，需要时执行 `xmake f -c` 重新探测。

### 5.10 目录与命名汇总

实现归属：qml/资源 qrc 由 `prepare_qml.lua`/`prepare_resource.lua` 写，cachegen/loader 输出由 `cachegen.lua`，qmltc 输出由 `qmltc.lua`，AOT 报告由 `aotstats.lua` 生成。

| 产物 | 路径 |
|---|---|
| qml qrc | `<autogendir>/rules/qt/qml/qml_module.qrc` |
| 资源 qrc | `<autogendir>/rules/qt/qml/qml_resource.qrc` |
| loader 参数文件 | Windows 下参数过长时由 `winos.cmdargv()` 生成在系统临时目录（`@<os.tmpfile()>.args.txt`），不在工程目录、不参与增量判断 |
| qmlcachegen 输出 | `<autogendir>/rules/qt/qmlcachegen/<mangled>.cpp` |
| loader | `<autogendir>/rules/qt/qmlcachegen/<target>_qmlcache_loader.cpp` |
| AOT 报告 | `<autogendir>/rules/qt/qmlcachegen/<target>.aotstats[.txt]`、`<target>.aotstatslist` |
| qmltc 输出 | `<autogendir>/rules/qt/qmltc/<rel>.h/.cpp`；moc 产物由 `qt.moc` 规则生成在 `<autogendir>/gens/...` 下 |
| qmlcachegen 依赖缓存 | `<dependir>/gens/.../rules/qt/qmlcachegen/<mangled>.cpp.d` |
| qmltc 依赖缓存 | `<dependir>/gens/.../rules/qt/qmltc/<mangled>.h.d` |

### 5.11 增量与生成器

- prepare 阶段每个任务都有独立的 depfiles/depvalues/depcache；依赖未变化时整条命令跳过（无改动的再次构建只有依赖检查开销，实测 ~0.05s）。
- 每文件依赖缓存命名：qmlcachegen `<mangled>.cpp.d`（`target:dependfile(<生成的 cpp>)`）；qmltc `<mangled>.h.d`（`target:dependfile(<生成的 header>)`）；loader/aotstats 按各自产物命名；moc 由 `qt.moc` 规则按 moc 产物命名。
- **project 生成器（make/ninja/vs/cmake）**：`xmake project` 会真实执行一次 prepare 阶段（生成产物被写出来），但 `batchcmds:call` 的命令无法导出到生成器文件，因此生成器工程**不包含重生成规则**——生成器工程里修改 QML 后需要重新执行 `xmake project`（与 verilator 把生成放在 prepare 阶段的模型一致）。生成的 cpp 的编译规则会正常导出，`compile_commands` 也包含这些 cpp。
- `build.jobgraph` 策略默认 true。关闭该策略时 **prepare 阶段仍按 jobgraph 执行**（`xmake/actions/build/build.lua` 的 `_prepare()` 在策略判断之前调用），所以生成与编译仍可用，只有 build 阶段回退到旧的批处理流程。
- 已知既有问题（与本次改动无关）：新生成的 makefile 直接 `make` 仍受 `qt.qrc` 产物无 make 规则的 HEAD 问题影响。

### 5.12 增量决策（无依赖图）

§0.15 起不再使用 `qmlimportscanner` 建立依赖图：

- 每个 qmlcachegen/qmltc 任务只依赖自己的 QML 文件；`type_compiler` 下额外依赖生成的 qmldir，qmltc 还依赖 file map（文件增删/版本变化会触发 qmltc 重生成）。
- 修改一个 QML 文件只重新生成该文件，不再级联重生成 importer。
- C++ 编译阶段仍由编译器 depfiles 处理 qmltc 生成头文件的 `#include`，以及 qmlcachegen 生成源对其他生成头的包含。
- 目录 import 和 JS import 不再被构建系统追踪；qmlcachegen/qmltc 仍按 Qt 自身语义处理 import，只是不会据此建立增量依赖。
- 已知限制：如果 qmltc 生成代码依赖被导入 QML 的类型接口变化，仅修改被导入文件不会重新运行 importer 的 qmltc，需要清理/强制重建该文件。

---

## 6. 版本支持矩阵

| 功能 | Qt 5.15 | Qt 6.2–6.3 | Qt 6.4+ | Qt 6.8+ |
|---|---|---|---|---|
| `qt.qml.resource` / `cachegen=false` 的 qrc 打包 | ✅ | ✅ | ✅ | ✅ |
| `qt.qml` cachegen（默认 true） | ❌ config assert（提示 `{cachegen=false}`） | ✅ | ✅ | ✅ |
| `only_bytecode` | ❌（cachegen 需 6.2+；`cachegen=false` 时忽略并 warning） | 能力探测 | 能力探测 | 能力探测 |
| `type_compiler` | ❌ assert | ❌ assert（需 6.4+） | ✅ | ✅ |
| AOT 报告 | — | 自动跳过 / `aot_stats=true` 报错 | 同左 | ✅ |

- 版本/values 断言位于 `qt.qml.on_load`（`qt.qml.version` 用 `core.base.semver` 校验）；工具版本/能力断言位于 `qt.qml` 的 `on_config`（`cachegen.get_tool()`/`qmltc.get_tool()`/`aotstats.get_aot()`）。
- `qt.qml.resource` 与 `cachegen=false` 的 QML 打包不依赖 Qt6 工具，可在 Qt5.15 使用。

---

## 7. 示例工程（每个特性一个）

```
tests/projects/qt/
├── qml_module/                 # cachegen 默认：打包 + AOT + loader + AOT 报告
├── qml_module_rule/            # 直接使用 qt.qml 规则：add_rules + add_files + add_values
├── qml_module_no_cachegen/     # {cachegen = false}
├── qml_module_type_compiler/   # {type_compiler = true, version = "2.3.4", namespace = "MyAppNs"}（类型登记为 2.3）；main.cpp 直接创建生成的 C++ 对象
├── qml_module_only_bytecode/   # {only_bytecode = true}（不生成 AOT 报告，旧报告保留）
└── qml_module_discard/         # {discard = true}
```

每个工程结构类似：

```
xmake.lua
main.cpp              # QGuiApplication + QQmlApplicationEngine，load qrc:/qt/qml/MyApp/Main.qml，
                      # rootObjects 为空则返回非 0（用于 xmake run 验收）
                      # qmltc 工程（qml_module_type_compiler）例外：包含生成的 Main.qml.h，
                      # 直接构造 MyAppNs::Main，不使用 engine.load，见 §0.5
Main.qml              # import QtQuick + typed JS；type_compiler 工程额外 import MyApp，以验证同模块类型
MyButton.qml          # 跨文件组件（type_compiler 工程用它验证 qmltc 类型解析，见 §0.7）
utils.js              # 带类型标注的 JS（.pragma library）
assets/logo.svg       # 资源文件
assets/config.json    # qml_module_rule 中演示按后缀分派的 JSON 资源
```

`utils.js`（类型标注以允许 qmlcachegen AOT 生成 C++）：

```js
.pragma library

function greeting(name: string): string {
    return "Hello, " + name
}

function sum(a: int, b: int): int {
    return a + b
}
```

`Main.qml`：

```qml
import QtQuick
import "utils.js" as Utils

Window {
    width: 320; height: 200; visible: true
    title: Utils.greeting("QML")
    MyButton { anchors.centerIn: parent; text: "sum=" + Utils.sum(1, 2) }
}
```

target 示例：

```lua
add_rules("mode.debug", "mode.release")
includes("@builtin/qt")

target("qml_module")
    add_rules("qt.quickapp")
    add_files("main.cpp")
    qt_add_qml_module("*.qml", "*.js", "assets/*.svg", {uri = "MyApp"})
    set_runenv("QT_QPA_PLATFORM", "offscreen")
```

不用 `qt_add_qml_module`、直接使用规则（`qml_module_rule`）示例：

```lua
target("qml_module_rule")
    add_rules("qt.quickapp", "qt.qml", "qt.qml.resource")
    add_files("main.cpp", "*.qml", "*.js", "src/*.mjs")
    add_files("assets/*.svg")
    add_values("qt.qml.uri", "MyApp")
    set_runenv("QT_QPA_PLATFORM", "offscreen")
```

---

## 8. 验收测试矩阵

1. **构建**：每个工程 `xmake f -c -y --qt_sdkver=6 && xmake -y` 成功。
2. **运行**：`xmake run`（offscreen）返回 0，`import MyApp`/资源加载正常。
3. **产物检查**：
   - `.../rules/qt/qmlcachegen/*.cpp`、`<target>_qmlcache_loader.cpp`、`<target>.aotstats[.txt]` 存在；不再有 qmlimportscanner JSON；
   - 默认工程的 AOT 报告包含实际编译条目；js-only 工程不调用 `qmlaotstats`，旧报告保留；
   - qml qrc/qmltc/moc 产物路径符合 §5.10（moc 产物由 `qt.moc` 规则生成）；
   - qrc 文本由 `core.base.xml` 渲染：普通路径下与手写渲染逐字节一致，含 `&`/`<` 的 alias/path 也能正确转义并被 rcc 解析。
4. **增量（重点）**：
   - 不改文件再构建：qmlcachegen/qmltc/rcc 全部跳过（~0.05s）。
   - touch/修改 `Main.qml`：只重生成 `Main.qml`、rcc 重编译、重新链接；其它 cachegen 源文件不变。
   - touch/修改 `MyButton.qml`：只重生成 `MyButton.qml`，不级联重生成 import 它的文件；C++ 编译阶段仍按头文件依赖重新编译受影响的生成源。
   - 只被其它文件 import 的 JS（`utils.js`）：只有 `utils.js` 自己重生成；import 它的文件不重生成。
   - 目录 import：§0.15 起不再被构建系统追踪；qmlcachegen/qmltc 仍按 Qt 语义解析 import。
   - 删除文件：qrc 随文件列表变化重写、loader 随资源列表（depvalues）变化重生成、qmldir/file map 重写，构建不残留旧对象。
   - 依赖缓存命名：qmlcachegen `<mangled>.cpp.d`，qmltc `<mangled>.h.d`。
5. **生成阶段并行（重点）**：qmlcachegen 与 qmltc 两组交错执行（`-j8` 日志可见）；两组之间没有顺序边。
6. **生成物进入编译（重点）**：生成 cpp 出现在 `xmake -v` 编译命令与 `xmake project -k compile_commands` 中；不再手工插 `target:objectfiles()`。
7. **no_cachegen**：不调用 qmlcachegen；qrc 正常编译；程序可运行。
8. **type_compiler**：qmltc 的 `.h/.cpp` 生成，header 由 `qt.moc` 规则生成 moc 源并编译链接（验证 Qt 私有 include）；`main.cpp` 直接构造 qmltc 生成的 `MyAppNs::Main`（不使用 `engine.load`），`xmake run` 返回 0；`Main.qml` 通过 `import MyApp 2.3` 使用同模块的 `MyButton`（模块 `version = "2.3.4"`，类型登记为 `2.3`），验证自动 qmldir、qmlcachegen `-i`、runtime qmldir；touch 后 qmltc 输出不变时不重跑 moc，再次构建为真空转。
9. **only_bytecode**：不生成/更新 AOT 报告（旧报告保留）；`--only_bytecode` 生效；`only_bytecode=true` 且 `cachegen=false` 时忽略 `only_bytecode`，load 阶段给出 warning，构建按无 cachegen 流程继续。
10. **discard**：qml qrc 条目带 `empty="true"`；AOT 仍生效。
11. **Qt5 回归**：`qml_module_no_cachegen` 用 `--qt_sdkver=5` 能构建；默认工程在 Qt5 下有清晰 cachegen assert 报错。
12. **直接规则用法**：`qml_module_rule`（`add_rules("qt.qml", "qt.qml.resource") + add_files("*.qml", "*.js", "assets/*.svg") + add_values("qt.qml.uri", ...)`）能构建并运行；无法识别扩展名的文件（如 `qt_add_qml_module("src/*", ...)` 匹配到的非 qml 文件）仍由 xmake 原生机制报 `unknown source file`；匹配不到文件的 pattern → 原生 `cannot match ...` warning。
13. **目录外文件**：引用 `../shared/X.qml`，warning 中出现最终 alias（相对工程根目录）。
13.1 **qmldir**：`type_compiler` 工程的 build-time/runtime qmldir 类型条目、版本、`prefer` 正确；新增/删除 `.qml` 后 qmldir 与 qmltc/qmlcachegen 重生成；路径含空格和嵌套目录 alias 时可解析。
14. **aot_stats 组合**：`only_bytecode=true, aot_stats=true` → 仅 warning，不生成/更新报告（旧报告保留）；Qt < 6.8 环境 `aot_stats=true` → assert；`aot_stats=false` 不生成/更新报告。
15. **namespace 语义**：默认 nil → qmltc 生成 `namespace <URI 点换 ::>`；`""` → 不传 `--namespace`（匿名命名空间）；显式字符串原样使用。
16. **多 target / 子目录**：两个 target 各自一个 QML 模块可并行构建；touch 一个 target 的 qml 不影响另一个；子目录 qml 不再建立目录 import 依赖。
17. **健壮性**：qml 语法错误时构建失败并报 qmlcachegen 的真实错误；修复后只重生成受影响文件；`--dry-run` 不执行 qmlcachegen/qmltc（qrc/qmldir 仍会同步写入，§0.13）；`xmake clean`/`xmake -r` 正常。
17. **策略/生成器**：`xmake f --policies=build.jobgraph:false`（策略参数只能传给 `xmake f`）时 prepare 阶段仍执行生成、构建成功；`xmake project -k makefile/compile_commands` 成功且生成 cpp 的编译规则已导出（不导出重生成命令，属预期限制）。
18. **生成物增量**：连续构建时 qrc/qmldir 的 mtime 不变；touch qml 内容只触发 rcc，不改 qrc/qmldir；新增/删除 QML 或修改 version 时 qrc/qmldir 重写；删除生成物后重建。
19. **version 校验**：`qt.qml.version = "foo"` 在 load 阶段报 semver 错误；`"2.3"`/`"2.3.4"` 分别生成 `2.3` 的类型条目。
20. **load 值检查**：`aot_stats=true` + `cachegen=false`/`only_bytecode=true` 只在 load 阶段打印 warning，不读取 sourcebatch；§0.15 起 `on_config` 负责工具断言。

---

## 9. 实施步骤

初版：

1. `xmake/includes/qt/qt_add_qml_module.lua` + 在 `xmake/includes/qt/xmake.lua` 注册：变参解析、后缀分类、无法识别的项用普通 `add_files` 兜底、values 注入、`add_rules("qt.qml")`、两条规则化 `add_files` 绑定。
2. `xmake/rules/qt/qml/` 基础框架：`xmake.lua`、`utils.lua`（values/路径/Qt 环境/工具查找）、`qrc.lua`（qrc 渲染）、`qrcgen.lua`。
3. `qt.qml.resource`（`resource.lua`，`on_prepare_files`）：先跑通 cachegen=false 的「资源 qrc + qml qrc + qt.qrc 编译 + 运行」。
4. `qt.qml` 的 `load.lua`（参数校验）与 `config.lua`（版本/工具检查）。
5. `build.lua`：`on_prepare_files(jobgraph)` 生成阶段——qmlcachegen、loader、qmltc、AOT 报告（§0.15 前还包含 importscanner）；生成 cpp 用 `target:add("files", ..., {always_added = true})` 注册。
6. AOT 报告、`only_bytecode`（含 aot_stats warning）、`discard`、`aot_stats` 语义。
7. 创建测试工程 + typed JS；执行 §8 验收矩阵。

第二轮优化：

8. `qt.qml` 静态依赖 `qt.env`/`qt.qrc`/`qt.moc`，删除 rcc/moc 自行探测；qmltc 头文件由 `qt.moc` 规则在 build 阶段处理；`qt_add_qml_module` 只注入 `qt.qml`/`qt.qml.resource`/`qt.qrc`（§0.8）。
9. `qt.qml` 增加 `set_extensions`，`qmldir` 在 load 阶段按文件名绑定；新增 `qml_module_rule` 示例。
10. config 只探测环境；qrc/rsp/qmltc file map 移到 prepare 阶段同步生成；删除 `qrcgen.lua`/`aotstatsgen.lua`/manifest。
11. 源文件列表改从 prepare 的 sourcebatch 获取，删除 `target:data("qt.qml.setup")`（§0.16 重新引入 setup 缓存）。
12. 工具查找改 `lib.detect.find_tool`（version = true），选项能力改 `lib.detect.has_flags`，新增 `detect/tools/find_qmlcachegen.lua`；depvalues 直接传 table。
13. `namespace` 默认 nil 语义；合并冗余函数；`on_prepare_files` 使用 `{jobgraph = true, batch = true}`（§0.12，不加 distcc）。
14. 代码风格收尾（Apache header、`@file`、英文注释说明 CMake 对应行为与描述域限制）、`git diff` 检查、最终全量验证。

第三轮优化：

15. qrc 自动生成改用 `core.base.xml`：`qrc.lua` 的 `generate_qrc()` 用 `xml.new()`/`xml.text()` 构建 `<RCC>` 节点树后 `xml.encode()`，删除手写 XML 转义；按 §8 重跑构建/运行/增量回归。

第四轮优化：

16. `only_bytecode` 在 `cachegen` 关闭时改为忽略并 warning，删除 `get_setting()` 的强制开启逻辑。
17. 删除 loader rsp：`cachegen.add_loader()` 直接用 argv 调用 qmlcachegen，Windows 下用 `winos.cmdargv(args, {raw = true})` 自动转成临时参数文件；`core.base.winos::cmdargv()` 增加 `raw` 模式（逐行原样、UTF-8），按 §8 重跑构建/运行/增量回归（含含空格路径的工程）。

第五轮优化（当前实现）：

18. qmltc 测试工程改为直接创建生成的 C++ 对象：`tests/projects/qt/qml_module_type_compiler/main.cpp` 包含 `Main.qml.h` 并构造 `MyAppNs::Main`，不再使用 `engine.load`；按 §8 重跑干净构建与运行回归。

---

## 10. 范围与使用约定

- **一个 target 一个 QML 模块**；多次调用合并文件；不需要用户提供 qmldir，`type_compiler` 下由规则生成 build-time + runtime qmldir（§0.7），其它场景仍可用显式 `add_files("qmldir", {rules = "qt.qml.resource"})` 打包。
- `qt.qml.resource` 适用于任意后缀的资源文件（显式 `{rules = "qt.qml.resource"}` 绑定）。
- 静态库 target 的资源可能被链接器丢弃：**不由 qt 规则处理**，用户自行通过 `add_linkgroups("xxx", {whole = true})` 解决。
- 不在本次范围：plugin 目标/qmltypes 自动生成、`qmllint`、`qmlsc` static/direct-calls、部署、Qt5 qmlcachegen 流程、qmltc C++ 类型注册。
- §0.15 起不使用 `qmlimportscanner`；QML 插件/静态导入链接（`qt_import_qml_plugins`）不在本规则范围。
- qmltc 在本实现中只负责「编译成 C++ 并参与构建」；runtime qmldir 只登记 QML composite type 的资源 URL，不生成 qmltypes，也不注册 C++ 类型。

---

## 11. 风险与待确认

1. **无法识别项的报错信息来自 xmake 原生机制**：为 `unknown source file: <file>` / `cannot match ...`，不包含 `qt_add_qml_module` 上下文；这是本轮要求的「由 xmake 自带机制处理」的直接结果。写法上应使用带明确后缀的 pattern（如 `src/*.qml`、`assets/*.png`）。
2. **qmltc 私有 include**：依赖 `qt.quickapp` 的 `load.lua` 提供；type_compiler 示例工程验证，不足则按 `Qt<模块>Private` framework 方式补齐。
3. **AOT 报告版本**：`qmlaotstats`/`--dump-aot-stats` 需 Qt 6.8+；`aot_stats` 的 auto/true/false 语义已按反馈实现；`only_bytecode` 组合 warning。
4. **生成器**：prepare 阶段的重生成命令（`batchcmds:call`/`batchcmds:lua`）无法导出到 make/ninja/VS/CMake 工程文件，生成器工程里修改 QML 后需要重新执行 `xmake project`；生成的 cpp 编译规则会正常导出，`compile_commands` 包含生成 cpp（`xmake project` 期间已生成）。与 verilator 等「prepare 阶段生成」的规则模型一致。
5. **跨平台**：Windows（`.exe`、路径/引号）、macOS（framework 路径）本次未实测，工具查找与 qrc 路径处理按现有 qt 规则风格实现。
6. **生成脚本路径**：第二轮已删除 `qrcgen.lua`/`aotstatsgen.lua`（改为 prepare 内同步写入与 `batchcmds:call` 内联函数），不再有运行期 xmake 安装位置依赖。
7. **并发 `batchcmds:lua` + 捕获子进程输出不可靠**：`batchcmds:lua` 线程与其它会起子进程的任务并发时，脚本里调用 `os.iorunv()` 会随机失败（实测 8 个 lua 任务 + 8 个 `cmds:vrunv` 并发，每轮 40 个结果丢 1–3 个且无报错）；当前实现不使用 `batchcmds:lua` 执行 QML 生成命令，AOT 报告用 `batchcmds:call` 内联生成。
8. **无 import 级联**：§0.15 起不解析 import；修改被导入文件只重生成该文件，不重生成 importer。qmltc 的生成代码若依赖被导入类型的接口变化，可能需要手工清理/强制重建。
9. **跨 target QML 模块**：通过 `qt.qml.import` 引用的其它模块不参与本 target 的增量判断，其文件变化不触发生成。
10. **`find_program` 的 PATH 兜底**：`lib.detect.find_tool` 在给出的 SDK 目录找不到时会回落到系统 PATH；`find_sdk_tool` 会校验 `tool.program` 必须位于 SDK 目录内，否则按未找到处理；不覆盖 detectcache 的 cachekey，探测失败后需要执行 `xmake f -c` 让 xmake 重新探测。
11. **`has_flags` 的工具名**：`has_flags` 依赖 `find_tool` 返回的 `tool.name`（内部会拼 `core.tools.<name>.has_flags`）；Qt 工具名默认无法解析，因此新增 `detect/tools/find_qmlcachegen.lua`。`--dump-aot-stats` 需与 `--module-id` 一起探测，否则 qmlcachegen 会以非 0 退出导致误判；`has_flags` 调用带 `version = true`，SDK 就地升级后缓存会失效。`qmlaotstats` 没有 `--version`，用 `check = "--help"` 探测。
12. **dry-run**：当前工具命令通过 `runcmds(dryrun=...)` 跳过执行；qrc/qmldir 的同步写入没有 dry-run 参数，仍会发生（§0.13）。Windows 下 `winos.cmdargv()` 的临时参数文件在系统临时目录，不影响工程。
13. **qmlcachegen 的 URL 展平命名**：同一模块中 `a/b.qml` 与 `a_b.qml` 的资源 URL 展平后相同，qmlcachegen 生成的 loader 会重复定义同一 C++ 命名空间而编译失败；Qt CMake 6.12 对同样的文件组合也会在 configure 阶段报重复 custom rule。qmltc 输出文件名已加路径哈希规避自身冲突，但该限制来自 Qt 工具，不由本规则修复。
14. **qrc 渲染由 `core.base.xml` 生成**：属性按渲染后的属性串排序输出，文本节点中的 `"`/`'` 与属性值中的 `'` 不再转义（属性值内的 `"` 仍转义），均为合法 XML；普通路径下生成内容与手写渲染逐字节一致，含 `'`/`"` 的路径只在首次构建时重写一次 qrc（多一次 rcc 编译），之后稳定。
15. **loader 参数文件**：Windows 下 argv 超过 4096 字符时 `winos.cmdargv()` 才生成临时参数文件，内容为逐行原样参数（`raw` 模式），因为 qmlcachegen 的 `@file` 按行解析、不做 MSVC 式去引号/合并；临时文件在系统临时目录，不参与增量判断（argv 本身是 depvalues），也不受 `xmake clean` 管理。macOS/Windows 实机未验证，Linux 上已用 `@file` 手工模拟验证 qmlcachegen 能正确读取 raw 行。

---

## 12. 需求映射

| 需求 | 落点 |
|---|---|
| 1. `qt_add_qml_module(files, opt)`，`add_values` 注入、`add_files` 绑定、QML/资源分开；`add_rules("qt.qml")` 激活 config 钩子；无法识别的项交给 xmake 原生机制 | §3.2、§4 |
| 2. `qt.qml`：values、qmldir `-i`、qrc/cachegen 分支、qmltc、输出目录、AOT 报告、外部文件 warning | §5.1、§5.5–5.9 |
| 3. `qt.qml.resource`：任意后缀、QTP0001=NEW 路径、qrc + 复用 qt.qrc | §5.2 |
| 4. 正确查找 qmlcachegen/qmltc、Qt5/Qt6 共存 | §2.5、§5.3 |
| 5. `assert` 版本/values 检查、load 阶段 | §0.9、§5.3、§6（`qt.qml.on_load`） |
| 6. 遵循 xmake 风格 | 文件/命名/钩子/import 方式对齐现有 qt、protobuf、c++ modules 规则 |
| 7. 钩子阶段不冲突、留扩展空间 | §0.9、§3.3、§3.4（`on_load` + 三个 prepare 阶段；资源规则 `before_preparecmd_files`；qrc/map 在 prepare 回调里同步生成，不再需要 `add_orders`） |
| 8. 示例工程 | §7（每个特性一个） |
| 9. 参考 CMake | §2（命令/布局/loader/AOT 流程均按 CMake 实测实现） |
| 10. cachegen/qmltc 基于 jobgraph、两组并行、生成 cpp 交给 c++ 规则 | §3.1–§3.3、§5.1 |
| 11. ~~恢复 qrcgen/aotstatsgen 独立脚本并用 batchcmds:lua 调用~~ | 已被第二轮需求 8 取代（§0.1 第 8 条），脚本已删除 |
| 12. ~~qmlimportscanner 依赖图~~（§0.15 移除）；每个 QML 源文件一套 depfiles/depvalues | §5.12、§0.15 |
| 13. depcache 命名、depmtime 取值结论 | §5.6、§0.13 |
| 14. 注入 qt.qrc/qt.moc 规则，复用已有工具探测 | §0.1-1、§3.2、§5.2、§5.3、§5.8 |
| 15. `qt.qml` 文件后缀支持、直接 add_rules+add_files+add_values | §0.1-2、§3.2、§5.1、§7（`qml_module_rule`） |
| 16. config 只探测环境，qrc 在 prepare 生成 | §0.1-3、§3.3、§3.4、§5.1、§5.5 |
| 17. 源文件列表不写 `target:data`，prepare 用 sourcebatch | §0.1-4、§5.1 |
| 18. `on_prepare_files` 的 batch/distcc 评估 | §0.1-5、§5.1（规则定义处有注释） |
| 19. `lib.detect.find_tool` 按工具使用 version/check，不设置 cachekey；失败后 `xmake f -c` 重新探测 | §0.1-6、§5.3、§0.14 |
| 20. depvalues 直接支持 Lua table | §0.1-7、§5.6、§5.8、§5.9 |
| 21. 合并冗余函数/脚本 | §0.1-8 |
| 22. `lib.detect.has_flags` 探测选项能力 | §0.1-9、§5.3 |
| 23. qmltc namespace 默认 nil / `""` 语义 | §0.1-10、§5.8 |
| 24. qrc 自动生成使用 xmake 自带 `core.base.xml` | §0.2、§5.2、§5.5 |
| 25. `only_bytecode` 在 `cachegen` 关闭时忽略并 warning；loader 不生成 rsp，改用 `winos.cmdargv`（raw 模式）处理超长参数 | §0.4、§5.1、§5.7 |
| 26. qmltc 测试用例不再 `engine.load`，直接创建生成的 C++ 对象 | §0.5、§7、§8 |
| 27. 第六轮：资源后缀匹配、去掉 qmldir、文件按规则后缀分派、标准 prepare 钩子与去 `always_added`；qt.moc 依赖在 §0.8 改为静态 | §0.6、§0.8 |
| 28. 第七轮：`type_compiler` 下自动生成 build-time/runtime qmldir，qmlcachegen/qmltc 传 `-i`，新增 `qt.qml.version` | §0.7 |
| 29. 第八轮：qrc/qmldir 改用 `core.project.depend` 增量（`qrc.write_if_changed` 接收 qrcdata），version 走 `core.base.semver`，去防卫代码，qt.moc 改为静态依赖 | §0.8 |
| 30. 第九轮：`qt.qml` 的 `on_config` 合并到 `load.lua`，只按 values 检查矛盾，不读 sourcefiles；删除 `aot.ignored` | §0.9 |
| 31. 第十四轮：按工具拆分 cachegen/qmltc/aotstats 模块；qmlaotstats 用 `--help` 探测，没有 sidecar 时保留旧报告 | §0.14 |
| 32. 第十五轮：on_config 工具断言、`setup.qmls` 字典、去掉 filemap/_find_file、移除 qmlimportscanner 和目录 import 依赖 | §0.15 |
| 33. 第十六轮：setup 缓存、单工具走 `on_preparecmd_file`、双工具才附加 jobgraph、jobgraph 直接执行、AOT 报告按存在的 sidecar 聚合 | §0.16 |
| 34. 第十七轮：去掉 `get_needs()`，工具选择直接看 settings，即使没有对应源文件 | §0.17 |
| 35. 第十八轮：私有函数去掉 `local`、拒绝 `discard + cachegen=false`、合并 `get_mangled_name()`、qrc 文件名加 target 哈希、按 CMake 对齐 QML 增量粒度 | §0.18 |
| 36. 第十九轮：保留源文件名、过滤 nil SDK 目录、find_program 使用 SDK cachekey、相对 import 路径按 target scriptdir 解析 | §0.19 |

---

## 13. 参考

- Qt 官方文档：
  - <https://doc.qt.io/qt-6/qt-add-qml-module.html>
  - <https://doc.qt.io/qt-6/qt-cmake-policy-qtp0001.html>
  - <https://doc.qt.io/qt-6/cmake-variable-qt-qml-generate-aotstats.html>
- xmake 自定义规则文档（增量/batchcmds）：<https://xmake.io/zh/api/description/custom-rule.html>
  - `batchcmds:call`：<https://xmake.io/zh/api/description/custom-rule.html#batchcmds-call>
  - jobgraph：<https://xmake.io/zh/api/scripts/extension-modules/async/jobgraph.html>
- xmake 工具探测：
  - `lib.detect.find_tool`：<https://xmake.io/zh/api/scripts/extension-modules/lib/detect.html>
  - `lib.detect.has_flags`：<https://xmake.io/zh/api/scripts/extension-modules/lib/detect.html>
  - `find_program` 缓存与 PATH 兜底行为、`find_programver` 版本解析
- xmake 内置 `core.base.semver`（版本校验/解析）：<https://xmake.io/zh/api/scripts/extension-modules/core/base/semver.html>
- xmake 内置 `core.base.xml`（qrc 渲染）：<https://xmake.io/zh/api/scripts/extension-modules/core/base/xml.html>
  - 实现：`xmake/core/base/xml.lua`（`xml.new`/`xml.text`/`xml.encode`）；沙箱适配：`xmake/core/sandbox/modules/import/core/base/xml.lua`
- Qt `qmlimportscanner`：<https://doc.qt.io/qt-6/qtqml-tooling-qmlimportscanner.html>
- 本机 Qt 6.12.0 的 CMake 宏：`/usr/lib/cmake/Qt6Qml/Qt6QmlMacros.cmake`
- 本机工具：`/usr/lib/qt6/qmlcachegen`、`/usr/lib/qt6/qmlimportscanner`、`/usr/lib/qt6/bin/qmltc`、`/usr/lib/qt6/qmlaotstats`、`/usr/lib/qt6/moc`、`/usr/lib/qt6/rcc`；Qt 5.15.19：`/usr/bin/qmlcachegen`
- xmake 现有实现参考：
  - `xmake/rules/verilator/{xmake.lua,verilator.lua}`（prepare 阶段生成 + jobgraph 分组 + `batchcmds:call` 的参考写法）
  - `xmake/rules/qt/qrc/xmake.lua`（rcc 探测、生成 cpp + batchcmds + depfiles/depcache）
  - `xmake/rules/qt/moc/xmake.lua`（moc 探测、moc flags、生成文件处理；qmltc 的 header 复用此规则）
  - `xmake/rules/qt/qmltyperegistrar/xmake.lua`（`add_values` 读取、批量 buildcmd）
  - `xmake/rules/c++/modules/xmake.lua` + `config.lua`/`builder.lua`（规则拆分为 sibling 模块、`on_config("config")`）
  - `xmake/modules/detect/tools/find_ccache.lua`（新增 `find_qmlcachegen.lua` 的参考模板）
  - `xmake/includes/qt/qt_add_static_plugins.lua`（includes 中定义全局函数、`add_values`）
