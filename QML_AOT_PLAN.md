# 在 xmake 中实现 `qt_add_qml_module` 的计划

- 分支：`QML_AOT`
- 目标：在 `xmake/includes/qt/` 提供 `qt_add_qml_module(...)`，在 `xmake/rules/qt/` 提供 `qt.qml` 与 `qt.qml.resource` 两条规则，实现与 Qt CMake 集成 `qt_add_qml_module()` 中「QML 资源打包 + qmlcachegen AOT + qmltc + AOT 统计报告」等价的核心能力。
- 依据：本机 Qt 6.12.0 / Qt 5.15.19 工具实测、`/usr/lib/cmake/Qt6Qml/Qt6QmlMacros.cmake`（Qt 6.12 发行版，6027 行）以及当前 xmake checkout 的规则机制实测。

---

## 0. 关键修订与决策（最终版）

> 本实现经历五轮反馈。§0.1（第二轮）、§0.2（第三轮，只覆盖 qrc 渲染）、§0.4（第四轮）与 §0.5（第五轮，当前）是**当前实现**的最终决策；§3–§13 保留初版设计说明，与它们冲突处以 §0.1、§0.2、§0.4、§0.5 为准。

### 0.1 第二轮：实现后的优化（qrc 渲染已由 §0.2 更新）

| # | 要求 | 落实 |
|---|------|------|
| 1 | `qt_add_qml_module` 给 target 注入 `qt.qrc`，不再探测 rcc；qmltc 用到的 moc 同理，尽量复用已有规则的工具探测 | `qt_add_qml_module` 注入 `qt.qml`/`qt.qrc`/`qt.moc` 三条规则；rcc 来自 `qt.qrc.on_config` 的 `target:data("qt.rcc")`，moc 来自 `qt.moc.on_config` 的 `target:data("qt.moc")`；删除 `find_rcc`/`get_moc_flags`，qmltc 生成的头文件直接以 `qt.moc` 规则加入 target，在 build 阶段由 `qt.moc` 规则 moc + 编译 |
| 2 | `qt.qml` 增加文件后缀支持，`add_rules("qt.qml") + add_files("*.qml") + add_values(...)` 即可使用 | `set_extensions(".qml", ".js", ".mjs", ".qmldir")`；无后缀的 `qmldir` 在 `load.lua` 中按文件名绑定（`add_files("qmldir")` 即可）；示例工程 `tests/projects/qt/qml_module_rule`。`qt_add_qml_module` 仍用 `add_files(..., {rules = {"qt.qml", override = true}})` 显式绑定，避免扩展名规则重复加入同一 sourcebatch |
| 3 | 不在 config 阶段生成 qrc；config 只探测环境，prepare 时生成 | `qt.qml.on_config`（在 `xmake.lua` 内联，原 `config.lua` 已合并删除）只做版本/工具/能力检查并调用 `get_aot`，不写任何文件；qrc/qmltc file map 在 `on_prepare_files`（prepare 阶段）用 `qrc.write_if_changed` 生成；qrc 交给 build 阶段的 `qt.qrc` 规则编译（loader 的 rsp 已在 §0.4 移除，参数改由 `winos.cmdargv` 处理） |
| 4 | 不往 `target:data` 塞源文件列表，prepare 时通过 sourcebatch 处理 | prepare 回调签名 `(target, jobgraph, sourcebatch, opt)`，源文件取自 `sourcebatch.sourcefiles`；资源文件取自 `target:sourcebatches()["qt.qml.resource"]`；所有中间数据只放在 prepare 的局部 `setup` 表里，qml 规则不再 `target:data_set` |
| 5 | 看 `on_prepare_files` 是否要加 `batch = true, distcc = true` | 不添加：`batch` 是已废弃的非 jobgraph 模式（声明 `jobgraph = true` 时无效），`distcc` 只作用于生成物被编译的阶段，而生成 cpp 由 `c++.build` 在 build 阶段编译并自带 distcc 支持；原因已注释在 `xmake/rules/qt/qml/xmake.lua` |
| 6 | 工具查找用 `lib.detect.find_tool`，用 `version = true` 取版本，xmake 自带探测缓存，不在 `target:data` 重复缓存 | `utils.find_sdk_tool()` 统一调用 `find_tool(name, {paths = <SDK bindir/libexecdir>, version = true, cachekey = <SDK 目录哈希>})`；版本号直接用 `tool.version`；`qmlimportscanner`/`qmlaotstats` 不支持 `--version`，用 `norun = true` 探测；config/prepare 各自通过 detectcache 复用结果 |
| 7 | depvalues 支持 Lua table，不要强行转成字符串数组 | 所有 `cmds:add_depvalues()` 直接传 table（工具 argv、`-I` 目录列表等）；删除初版 config 中 `"key=value"` 形式的字符串 depvalues |
| 8 | 合并冗余函数（函数体短且只调用一次） | 删除 `qrcgen.lua`/`aotstatsgen.lua` 两个单函数脚本（qrc 直接写入、aotstats 列表用 `batchcmds:call` 内联）；合并 `_get_cppfiles`/`_add_cppfiles`；删除 `get_resource_path`/`get_tool_version`/`find_rcc`/`get_moc_flags` |
| 9 | 用 `lib.detect.has_flags` 判断工具是否支持某个选项 | `--only-bytecode` 直接探测；`--dump-aot-stats` 必须和 `--module-id=...` 一起探测（单独传入会以非 0 退出）；新增 `xmake/modules/detect/tools/find_qmlcachegen.lua`，使 `find_toolname` 能解析 `qmlcachegen`（`has_flags` 需要 `tool.name` 非空，否则会拼接 nil） |
| 10 | qmltc namespace 默认 nil：nil 时按 uri 自动生成；`""` 表示不传 `--namespace`（保持匿名命名空间） | `utils.get_setting()` 的 `namespace` 默认 nil；`prepare_qml.lua::_add_qmltc()`：nil → `uri:gsub("%.", "::")`，`""` → 不追加 `--namespace`，其他字符串原样传入 |

实现评审后的补充修复：

- 工具查找修正 `ipairs({qt.libexecdir_host, ...})` 在首个 nil 处截断的问题；`find_program` 的 PATH 兜底结果会被丢弃（工具必须位于选中的 SDK 目录内），cachekey 追加 `qt.sdkver`，`has_flags` 带 `version = true`。
- 资源 qrc 改为在 prepare 任务图构建阶段同步生成（`qt.qml.resource` 的 `on_prepare_files` 使用 `{jobgraph = true}`），保证 qmlcachegen/qmltc 任务启动时 `--resource` 指向的 qrc 一定存在，不再依赖规则顺序。
- `qt.qml.on_config` 在没有 `qt.qml` 源文件时直接返回（纯资源模块在 Qt5 下不再被 cachegen 版本断言拦截）。
- `--dry-run` 不写任何生成文件、不把 qrc 加入 target（否则 `qt.qrc` 在 dry-run 下读取 qrc 会失败），也不把 qmltc 生成的头文件注册给 `qt.moc`（`qt.moc` 会读取头文件判断 Q_PRIVATE_SLOT，文件尚未生成会报错），不加 qmltc include 目录。
- importscanner 失败时输出 warning；AOT 关闭时清理旧报告；删除 `has_resources`/`cachegendir` 等未使用字段。
- 工具/版本断言按需触发：`get_needs()` 根据源文件（qmldir-only、仅 js、仅 .qml 等）决定是否探测 qmlcachegen/qmltc/importscanner；无任何生成器时 `get_tools()` 直接返回，不要求可解析的 SDK 版本；`aot_stats=false` 时不再探测 qmlaotstats / `--dump-aot-stats`。
- `aot_stats=true` 但 AOT 被关闭（`only_bytecode`/无生成器）时的 warning 只在 `on_config` 打印一次，prepare 任务不再重复。
- qmlimportscanner 失败或输出为空时删除旧 JSON（下次构建重扫，避免依赖图冻结）；qrc/file map（以及 §0.4 之前的 loader rsp）按排序后的文件列表渲染。
- qmltc 生成文件名对嵌套路径追加哈希，避免展平后同名（`a/b.qml` vs `a_b.qml`）；moc 归属与 include 不受影响。

### 0.2 第三轮：qrc 自动生成改用 `core.base.xml`

| # | 要求 | 落实 |
|---|------|------|
| 1 | qrc 的自动生成（QML 模块 qrc、资源 qrc、qmltc file map）不再手写 XML 字符串，改用 xmake 自带的 `core.base.xml` 模块 | `xmake/rules/qt/qml/qrc.lua`：删除手写 `_escape()`，`generate_qrc()` 用 `xml.new()`/`xml.text()` 构建 `<RCC>` 节点树，再用 `xml.encode(doc, {pretty = true, indent = 2})` 生成文本；`write_if_changed()` 保持不变（内容变化才写盘，避免 mtime 抖动）；`prepare_qml.lua`/`prepare_resource.lua` 的调用点改为 `generate_qrc()`（参数不变） |

要点：

- 转义交给 xml 模块（文本内容转义 `& < >`，属性值再转义 `"`），路径/alias 含 `&`、`<` 等字符时 qrc 仍然合法。
- 属性由 xml 模块输出并按渲染后的属性串排序（`alias` 在 `empty` 之前），`<qresource prefix="...">`、`<file alias="...">path</file>` 的排版（2 空格缩进、文本节点与标签同行）与手写渲染逐字节一致；普通路径下生成内容不变，不会引入额外的 rcc 重编译。
- 参考文档：<https://xmake.io/zh/api/scripts/extension-modules/core/base/xml.html>；实现：`xmake/core/base/xml.lua`（`xml.encode`），沙箱适配：`xmake/core/sandbox/modules/import/core/base/xml.lua`。

### 0.3 第一轮决策（保留，供参考）

| # | 反馈 | 计划落实 |
|---|------|----------|
| 1 | `qt_add_qml_module` 遇到无法按后缀分类的直接调用 `add_files` 添加，由 xmake 自带机制处理 | §4.2：在函数内按 pattern 后缀分类；`.qml/.js/.mjs/.qmldir` → `qt.qml`，其他明确后缀 → `qt.qml.resource`，**无法识别的 pattern 原样交给普通 `add_files(...)`（不带 rules）**，由 xmake 在 config 阶段以原生 `unknown source file: ...` / `cannot match ...` 机制报错或告警；不引入内部 value，也不做自定义 raise。注意：由于 `qt.qml` 现在带 `set_extensions`，`src/*` 这类 pattern 匹配到的 `.qml` 会按扩展名正常进入 `qt.qml`，只有无法识别扩展名的文件才会报 `unknown source file` |
| 2 | 使用 xmake 规则自带增量机制：qml 源文件变化时重新生成 qrc，从而自动触发 qrc 重新编译 | **已被 §0.1 第 3/8 条取代**：qrc 在 prepare 阶段用 `write_if_changed` 同步写入，不再有 `qrcgen` job；qml 内容变化时 qrc 内容与 mtime 不变，但 `qt.qrc` 规则会把 `rcc -list` 得到的资源文件加入 depfiles，rcc 仍会正确重编译；文件增删导致 qrc 内容变化时 qrc 被重写并触发 rcc |
| 3 | `aot_stats=true` 且 `only_bytecode=true` 时报 warning | §5.9：该组合输出 warning 并忽略 AOT 报告（不报错、不生成报告） |
| 4 | cachegen/qmltc 也基于 jobgraph；两步用不同 jobgraph 分组并行；生成 cpp 直接加入 target，由 c++ 规则编译 | §3.1–§3.3、§5.1：`qt.qml` 改为 `on_prepare_files(..., {jobgraph = true})`；qmlcachegen 与 qmltc 分属两组、组间无边；生成 cpp 用 `target:add("files", ..., {always_added = true})` 注册，build 阶段重扫任务图后由 `c++.build` 编译（qmltc 头文件改为用 `qt.moc` 规则注册，见 §0.1 第 1 条） |
| 5 | 恢复 aotstatsgen/qrcgen 独立脚本，并通过 `batchcmds:lua` 调用 | **已被 §0.1 第 8 条取代**：两个脚本已删除，qrc 直接写文件；aotstats 列表用 `batchcmds:call` 在 job 内联函数中生成，避免 lua 线程与其它子进程并发的问题 |
| 6 | 用 qmlimportscanner 建依赖图，按图决定重编译哪些 QML；每个 QML 源文件一套 depfiles/depvalues | §5.12：每个 `.qml/.js/.mjs` 一个扫描任务（结果 JSON 缓存），cachegen/qmltc 读取该 JSON 解析出**该文件自己**的依赖集，分别记录 depfiles/depvalues |
| 7 | C++ 源文件生成的 depcache 命名 `<qmlfile>.d`；判断 depmtime 是否该用 QML 源文件 mtime | §5.12：cachegen 的 depcache=`target:dependfile(<qml 源文件>)`；结论是 **depmtime 仍用生成产物的 mtime**（qmltc 用 dependfile mtime），用 QML 源 mtime 会导致「改了自己不重建」/「永远重建」 |

### 其它已确认的决策（保持不变）

- `qt_add_qml_module` 通过 `add_rules("qt.qml", "qt.qrc", "qt.moc")` 激活规则；`qt.qml` 自身 `add_deps("qt.env", "qt.qrc", "qt.moc")`，因此直接 `add_rules("qt.qml")` 也能获得 rcc/moc 探测。`qt.qml.resource` 保持仅文件绑定 + `on_prepare_files`。
- 新增 options：`qt.qml.discard`（默认 false）、`qt.qml.aot_stats`（默认 nil）。
- 默认打包原始 QML；`discard=true` 时 qrc 条目加 `empty="true"`。
- Qt 版本分层支持：cachegen 需 Qt ≥ 6.2、type_compiler 需 Qt ≥ 6.4，qrc-only 路径可用于 Qt5.15。
- 目录外文件警告，alias 使用相对工程根目录的路径并在 warning 中报告。
- 文件分类按后缀；示例工程每个特性一个；示例 JS 需要类型标注。
- 静态库资源被链接器丢弃的问题由用户 `add_linkgroups(..., {whole = true})` 解决，不由 qt 规则处理。

### 0.4 第四轮：评审反馈

| # | 要求 | 落实 |
|---|------|------|
| 1 | `qt.qml.only_bytecode` 依赖 qmlcachegen 时不再强制开启 `qt.qml.cachegen`，改为忽略 `only_bytecode` 并警告 | `utils.get_setting()` 删除「`only_bytecode` 把 `cachegen` 强制为 true」的逻辑，改为在 `cachegen` 未启用时把 `only_bytecode` 置为 false（所有消费方都看到忽略后的值）；`load.lua` 在 config 阶段对用户显式设置的 `only_bytecode` 打印一次 warning：`qt.qml: qt.qml.only_bytecode is ignored because qt.qml.cachegen is disabled` |
| 2 | 不再生成 `setup.paths.loaderrsp`，改用 `core.base.winos` 的 `winos.cmdargv` 自动处理 loader 参数过长 | `utils.get_paths()` 删除 `loaderrsp`，`prepare_qml.lua::_write_files()` 不再写 rsp；`_add_loader()` 把 `--resource`/`--resource-name`/`-o` 与全部 QML 资源路径直接放进 argv，Windows 下用 `winos.cmdargv(args, {raw = true})` 在超过命令行长度限制时自动转成 `@<临时参数文件>`。`core.base.winos` 为此增加 `raw` 模式：逐行原样写入（不做 MSVC 式 `--opt value` 合并、不加引号/转义、按 UTF-8 写盘），因为 `qmlcachegen` 的 `@file` 是逐行解析且不会去引号（`argumentsFromCommandLineAndFile()`），保留旧 rsp 的语义 |

要点：

- loader 的 argv 仍然完整记录为 depvalues（qrc 路径 + 每个资源路径），不依赖临时参数文件做增量判断；depfiles 用生成的 qrc 文件，qrc 内容不变（文件列表不变）时 loader 任务照常跳过。
- 临时参数文件由 `winos.cmdargv()` 写到系统临时目录（`os.tmpfile()`），不落在工程目录，因此 `xmake clean`/`--dry-run` 不受影响；Windows 之外不调用 `winos.cmdargv()`，直接传 argv。
- `cachegen` 关闭时 `only_bytecode` 被忽略（§0.4），因此 `get_needs()`/`get_aot()` 无需再处理该组合，也不会出现「以为开了 only_bytecode 但实际没开」的静默行为。

### 0.5 第五轮：qmltc 测试用例直接创建 C++ 对象（当前）

| # | 要求 | 落实 |
|---|------|------|
| 1 | 工作区中开启 qmltc 的测试用例不再用 `engine.load()` 加载 QML，而是直接创建 qmltc 生成的 C++ 对象 | `tests/projects/qt/qml_module_type_compiler/main.cpp`：包含 qmltc 生成的头文件 `Main_qml.h`，在 `QQmlEngine` 就绪后直接构造 `MyAppNs::Main window(&engine)`，以 `window.isVisible()` 作为运行验收；删除 `<QQmlApplicationEngine>` 与 `engine.load(QUrl("qrc:/qt/qml/MyApp/Main.qml"))` |

要点：

- qmltc 生成的类在构造函数里通过 `QML_init()` 完成对象树创建、属性初始化与 QML 绑定建立，绑定求值依赖 qmlcachegen 生成单元在静态初始化时注册的 `QQmlPrivate::QmlUnitCacheHookRegistration`（loader cpp），因此直接构造不需要 `engine.load()`。
- `main.cpp` 能包含生成头，是因为 `qt.qml.on_prepare_files` 把 `<autogendir>/rules/qt/qmltc` 加入了 `includedirs`，Qt 私有头则由 `qt.quickapp` 提供；prepare 阶段先于 build 阶段，干净构建时头文件已生成（已用 `xmake clean` + 删除 `build/.gens`、`build/.deps` 的干净构建验证）。
- 该用例的运行时路径从「engine.load + qmlcachegen」变为「qmltc 生成的 C++ 对象」，从而真正校验 qmltc 产物参与编译、moc、链接与运行，而不只是检查生成文件是否存在。

---

## 1. 背景与目标

Qt 6 的 CMake 集成中，`qt_add_qml_module()` 负责：

1. 校验模块 URI，按 `QTP0001` 策略决定资源前缀（NEW：`/qt/qml/`）；
2. 把 `.qml/.js/.mjs` 与 `RESOURCES` 打包进 qrc，并在 NEW 策略下映射到 `:/qt/qml/<URI 点换斜杠>/...`；
3. 对 `.qml/.js/.mjs` 调用 `qmlcachegen` 做 AOT 编译并注册编译单元缓存（`qmlcache_loader.cpp`）；
4. 可选地对 `.qml` 调用 `qmltc` 生成 C++（需要 moc 与私有头）；
5. 可选地收集 AOT 编译统计（`qmlaotstats`，Qt 6.8+）；
6. 生成 qmldir/qmltypes/plugin 等模块元数据。

本计划实现 xmake 侧的 **打包 + AOT + qmltc + AOT 报告**，不实现 plugin/qmltypes/qmldir 自动生成、qmllint、部署等（见 §10）。`qmlimportscanner` 仅用于构建期依赖图（§5.12），不用于插件/静态导入扫描。

> 注意：以下 §2–§13 是初版设计记录，其中涉及的 `qrcgen.lua`、`aotstatsgen.lua`、`target:data("qt.qml.setup")`、config 阶段生成 qrc/manifest 等做法已在第二轮优化中移除；qrc 渲染已改为 `core.base.xml`（§0.2），loader 的 rsp 生成已移除（§0.4），qmltc 测试用例改为直接创建生成的 C++ 对象（§0.5），当前实现以 §0.1、§0.2、§0.4、§0.5 为准。

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
9. `add_files` 的显式 `{rules = ...}` 绑定绕过扩展名匹配；`set_extensions` **不支持 `.*` 通配**，因此 `qt.qml.resource` 不设 `set_extensions`，靠显式绑定接收任意后缀资源。

### 3.2 规则激活方式

- `qt_add_qml_module()` 内部 `add_rules("qt.qml", "qt.qrc", "qt.moc")`：
  - `qt.qml`：获得 `on_load`（廉价参数校验）、`on_config`（只探测 Qt SDK/工具版本与能力）、`on_prepare_files(..., {jobgraph = true})`（prepare 阶段：写 qrc/qmltc file map、注册生成物、importscanner、qmlcachegen、qmltc、AOT 报告）。
  - `qt.qrc`：提供 rcc 探测（`target:data("qt.rcc")`），并在 build 阶段编译生成的 qrc。
  - `qt.moc`：提供 moc 探测（`target:data("qt.moc")`），并在 build 阶段处理 qmltc 生成的头文件。
  - `qt.qml.resource` **不** `add_rules`，保持文件绑定；资源 qrc 生成放在 `on_prepare_files`，编译复用 `qt.qrc`。
  - QML/资源文件用 `add_files(..., {rules = {"qt.qml", override = true}})` 显式绑定；同时 `qt.qml` 设置 `set_extensions(".qml", ".js", ".mjs", ".qmldir")`，用户可以直接 `add_rules("qt.qml") + add_files("*.qml")`。
- `qt.qml` 声明 `add_deps("qt.env", "qt.qrc", "qt.moc")`（保证 `target:data("qt")`/rcc/moc 在 on_config 前可用）。规则之间不再需要 `add_orders`：qrc/map 在 prepare 回调里同步生成，qmlcachegen/qmltc 任务执行时已存在。

### 3.3 生命周期时序

```
config 阶段：
  qt.qml.on_load    -> 廉价参数校验（opt 类型、URI 格式）；把无后缀的 qmldir 文件绑定到 qt.qml
  qt.qml.on_config  -> 只探测环境：Qt SDK 版本、qmlcachegen/qmltc/qmlimportscanner/qmlaotstats
                       查找与版本检查、--only-bytecode/--dump-aot-stats 能力检查（不写任何文件）
prepare 阶段（qt.qml.on_prepare_files，任务图扫描时）：
  1. 从 sourcebatch 收集 qml/qmldir 文件，计算 alias/资源路径
  2. 同步写 qml qrc、qmltc file map（write_if_changed；loader 参数直接传给 qmlcachegen，超长时由 winos.cmdargv 写入临时参数文件）
  3. target:add("files", <qml qrc>, {always_added = true})（build 阶段由 qt.qrc 编译）
  4. target:add("files", <cachegen cpp + loader cpp>, {always_added = true})
     target:add("files", <qmltc header>, {rules = {"qt.moc", override = true}, always_added = true})
     target:add("files", <qmltc impl cpp>, {always_added = true})；加 qmltc include 目录
  5. 添加 prepare 任务（分组）：
       importscanner group  -> 逐文件 qmlimportscanner（batchcmds:call）
       qmlcachegen group    -> 逐文件 qmlcachegen + loader
       qmltc group          -> 逐文件 qmltc
       aotstats             -> qmlaotstats aggregate/format（列表用 batchcmds:call 内联生成）
     边：importscanner -> qmlcachegen、importscanner -> qmltc、qmlcachegen -> aotstats
     （qmlcachegen 与 qmltc 两组之间无边，可并行；moc 由 build 阶段的 qt.moc 规则执行）
prepare 阶段（qt.qml.resource.on_prepare_files，`{jobgraph = true}`）：在任务图构建时生成资源 qrc 并注入
  （复用 qt.qrc 编译；同步生成保证 qmlcachegen/qmltc 启动时资源 qrc 一定存在）
```

### 3.4 qrc 生成与增量

- qrc 在 prepare 阶段用 `qrc.write_if_changed()` 同步写入：**内容变化才写**，不产生无关的 mtime 抖动。
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
    qt_add_qml_module("*.qml", "*.js", "qmldir", "assets/*.svg", {uri = "MyApp"})

    -- 也支持显式列表
    -- qt_add_qml_module({"Main.qml", "MyButton.qml", "qmldir", "assets/logo.svg"}, {uri = "MyApp"})
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
- 一个 target 视为一个 QML 模块；多次调用合并文件；URI 冲突在 `on_load`/`on_config` assert。
- `only_bytecode=true` 要求 `cachegen=true`（默认就是 true）；显式 `cachegen=false` 时忽略 `only_bytecode` 并在 load 阶段 warning（§0.4）。

---

## 5. 规则实现细节

### 5.1 `qt.qml`

```lua
rule("qt.qml")
    add_deps("qt.env", "qt.qrc", "qt.moc")
    set_extensions(".qml", ".js", ".mjs", ".qmldir")
    on_load("load")                 -- 廉价参数校验（opt 类型 / URI / qmldir 绑定）
    on_config(function (target)     -- 只探测 SDK/工具版本与能力（内联，不写文件）
        import("utils")
        ...
    end)
    on_prepare_files("prepare_qml", {jobgraph = true})
                                    -- 写 qrc/map、importscanner、qmlcachegen、qmltc、AOT 报告
```

`on_load("load")`：

- 校验 `qt.qml.uri`（非空、无 `/`、无空白）、opt 类型、`namespace` 与 `type_compiler` 组合、每个 target 只允许一个 URI。
- 只做不依赖 Qt SDK 的廉价检查（load 阶段不执行 qmake、不探测工具）。
- 把 `add_files("qmldir")` 这类无后缀的 qmldir 文件按文件名绑定到 `qt.qml`（无后缀无法通过 `set_extensions` 分派）。

`on_config`（`xmake.lua` 内联回调，只探测环境，不写文件、不收集源文件列表）：

1. 读取 values/默认值（`utils.get_setting()`）。
2. `utils.get_tools(target, setting, needs)`：按需查找工具并做版本断言（§5.3、§6；`needs` 由 `utils.get_needs()` 根据源文件决定）：
   - `needs.cachegen` → `assert(sdkver >= 6.2)` 且找到 `qmlcachegen`；
   - `needs.type_compiler` → `assert(sdkver >= 6.4)` 且找到 `qmltc`；
   - 任一为真 → 找到 `qmlimportscanner`（依赖图需要）；两者都假（qmldir-only 模块）→ 不探测任何工具，也不要求可解析的 SDK 版本；
   - `only_bytecode=true` 且 `cachegen=false` → **忽略 `only_bytecode` 并 warning**（load 阶段，见 §0.4）；
   - `namespace` 非空但 `type_compiler=false` → warning（load 阶段）。
3. `utils.get_aot(target, setting, tools, needs)` 解析 `aot_stats` 语义（§5.9）。

`on_prepare_files(..., {jobgraph = true})` 回调（`prepare_qml.lua::main`）：

1. 从回调的 `sourcebatch` 收集 qml/qmldir 文件（不再从 `target:data` 读取），计算 alias/资源路径、qmldir 列表；目录外文件 warning（§5.4）。
2. 同步写 qml qrc、qmltc file map（`write_if_changed`，内容变化才写，§5.5）；loader 的参数不再写文件，见 §5.7。
3. `target:add("files", qrcfile, {always_added = true})`，build 阶段由 `qt.qrc` 规则编译。
4. `target:add("files", <cachegen cpp + loader cpp>, {always_added = true})`；qmltc 的 impl cpp 同样注册；qmltc 的 header 用 `{rules = {"qt.moc", override = true}, always_added = true}` 注册，由 build 阶段的 `qt.moc` 规则生成 moc 源并编译（§5.8）。
5. 添加 importscanner 组（逐文件扫描，§5.12）：`cachegen` 时扫描所有 qml/js/mjs，仅 `type_compiler` 时只扫描 `.qml`（qmltc 不处理 js）。
6. `cachegen` 且存在 qml/js/mjs：per-file qmlcachegen（§5.6）+ loader（§5.7）放在同一组；边 `importscanner -> qmlcachegen`。
7. `aot_stats` 生效时加 aotstats 任务，边 `qmlcachegen -> aotstats`（§5.9）。
8. `type_compiler` 且存在 `.qml`：qmltc 组（§5.8）；边 `importscanner -> qmltc`。
9. qmlcachegen 组与 qmltc 组之间**没有边**，可并行。
10. 每个任务记录自己的 depfiles/depvalues/depcache/depmtime（depvalues 直接传 Lua table）。

### 5.2 `qt.qml.resource`（保持文件绑定）

```lua
rule("qt.qml.resource")
    add_deps("qt.qrc")              -- 直接 add_rules("qt.qml.resource") 时注入 rcc 探测
    on_prepare_files("prepare_resource", {jobgraph = true}) -- 任务图构建阶段同步生成，不需要额外排序边
```

`prepare_resource.lua::main(target, jobgraph, sourcebatch, opt)` 流程（`jobgraph`、`opt` 未使用）：

1. 从 sourcebatch 取资源文件；计算 alias/资源路径；目录外 warning。
2. 生成资源 qrc：`<autogendir>/rules/qt/qml/qml_resource.qrc`（prefix `/qt/qml/<URI 点换/>/`，绝对路径 payload + alias），内容变化才写；`--dry-run` 时跳过写文件。qrc 由 `qrc.generate_qrc()` 基于 `core.base.xml` 渲染（§5.5）。
3. `target:add("files", qrcfile, {always_added = true})`；不再兜底探测 rcc，而是断言 `target:data("qt.rcc")` 存在并提示用户 `add_rules("qt.qrc")`（`qt_add_qml_module`/`qt.qml` 已注入）。
4. 编译复用 `qt.qrc` 规则；资源内容变化由 rcc depfiles 触发重编译。

### 5.3 工具查找与版本断言

- 搜索目录（去重、host 优先，逐个判断非 nil 后再加入）：`qt.libexecdir_host, qt.bindir_host, qt.libexecdir, qt.bindir`。
- 统一用 `lib.detect.find_tool(name, {paths = <SDK 目录>, version = true, cachekey = <SDK 版本 + 目录哈希>})`，版本号直接取 `tool.version`，不再自行执行 `--version`；结果由 xmake detectcache 缓存，不写 `target:data`。
- `find_program` 在 paths 找不到时会回退到 PATH，因此查找结果还要校验 `tool.program` 位于 SDK 目录内，否则视为「SDK 中没有该工具」（避免混用另一个 Qt 版本的工具）。
- `qmlimportscanner`/`qmlaotstats` 不支持 `--version`，用 `norun = true` 探测（存在即可）。
- 按需查找：`qmlcachegen`（cachegen）、`qmltc`（type_compiler）、`qmlimportscanner`（cachegen 或 type_compiler）、`qmlaotstats`（AOT 报告）；rcc/moc 分别由 `qt.qrc`/`qt.moc` 规则提供。
- `qt.qml.on_config` 在没有 `qt.qml` 源文件时直接返回；并且只有存在需要生成的源文件（非 qmldir 的 qml/js/mjs）时才断言/探测 cachegen、有 `.qml` 时才断言/探测 qmltc（qmldir-only 模块在 Qt5 下也可用）。
- 能力探测用 `lib.detect.has_flags`：`--only-bytecode`；`--dump-aot-stats` 和 `--module-id=...` 一起探测（单独传会以非 0 退出）。为使 `has_flags` 能解析工具名，新增 `xmake/modules/detect/tools/find_qmlcachegen.lua`。
- 版本断言位置：`qt.qml.on_config`（config 阶段）。

### 5.4 资源路径与告警

- 目录内文件：`alias = path.relative(target:scriptdir(), abs_file)`。
- 目录外文件：`wprint` 警告（警告文本包含最终 alias）；alias 使用相对工程根目录的路径（`path.relative(os.projectdir(), abs_file)`），保证 qrc 合法。
- 资源路径 = `/qt/qml/<uri 点换/>/<alias>`。
- `.qmldir`：排序后第一个作为模块 qmldir，用 `prefix="/qt/qml/<uripath>"` + `alias="qmldir"` 打包（不受 `discard` 影响）；所有 `.qmldir` 作为 `-i` 输入；多个时 warning。

### 5.5 qml qrc 生成（prepare 阶段）

- `xmake/rules/qt/qml/qrc.lua`：共享渲染模块；`generate_qrc()` 用 `core.base.xml` 构建 `<RCC>` 节点树并 `xml.encode()`（转义与属性排序交给 xml 模块，见 §0.2），`write_if_changed()` 按内容变化写盘。
- prepare 回调里直接从 sourcebatch 得到的文件信息渲染 qrc 并 `write_if_changed` 写盘；不再有 manifest 文件和 `qrcgen.lua` 脚本。
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

- `<mangled>`：保留相对目录结构、扩展名点转下划线（`src/Main.qml` → `src/Main_qml.cpp`）；目录外文件用 `<hash32>_<basename>.cpp`。
- 输出目录：`target:autogendir()/rules/qt/qmlcachegen/`。
- 每个文件独立记录增量信息：
  - **depfiles**：该 QML/JS 文件自身 + 依赖图解析出的模块内依赖（§5.12）+ 模块 qmldir 文件（去重排序）；
  - **depvalues**：`qmlcachegen` 路径 + 完整 argv（`-I/-i/--resource/--module-id` 等，工具或参数变化即重生成）；
  - **depcache**：`target:dependfile(<qml 源文件>)` → `<qmlfile>.d`（按 QML 源文件建立依赖缓存，不再用生成 cpp 命名）；
  - **depmtime**：生成 cpp 的 mtime（理由见 §5.12 第 5 条）。
- 生成 cpp 由 `c++.build` 编译（不手工插 `target:objectfiles()`）。

### 5.7 loader

```sh
<qmlcachegen> --resource-name qmlcache_<target> \
  -o <autogendir>/rules/qt/qmlcachegen/<target>_qmlcache_loader.cpp \
  --resource <qml.qrc> [--resource <resource.qrc> ...] \
  <qml resource path>...
```

- 不再生成 `<target>_qml_loader_file_list.rsp`（§0.4）：重复的 `--resource` + qrc 路径、每个 QML 资源路径都直接作为 argv 传给 qmlcachegen，参数顺序与旧 rsp 内容一致。
- Windows 下 argv 可能超过命令行长度限制，`_add_loader()` 用 `winos.cmdargv(args, {raw = true})` 自动把它转成 `@<os.tmpfile()>.args.txt`；`raw` 模式逐行原样写入（不合并 `--opt value`、不加引号、UTF-8 编码），因为 qmlcachegen 的 `@file` 是逐行解析、不会去引号（Qt `argumentsFromCommandLineAndFile()`）。其它平台直接传 argv。
- 增量：depfiles = 生成的 qrc 文件（`setup.resources`，文件列表不变时它们不被重写，loader 因此可跳过），depvalues = 工具 + 完整 argv（Lua table，含 qrc 路径与资源路径），depcache = `target:dependfile(<loader cpp>)`，depmtime = loader cpp mtime；临时参数文件不参与依赖判断。
- loader cpp 由 `c++.build` 编译；输出文件名必须以 `qmlcache_loader.cpp` 结尾。

### 5.8 qmltc + moc

```sh
<qmltc> --bare \
  --header <autogendir>/rules/qt/qmltc/<rel>.h \
  --impl   <autogendir>/rules/qt/qmltc/<rel>.cpp \
  --module <URI> [--namespace <namespace>] \
  -i <qmldir> -I <qt.qmldir> [-I <qt.qml.import>...] \
  [--resource <qml.qrc>] [--resource <resource.qrc>] \
  <abs qml file>

# qmltc header 在 build 阶段交给 qt.moc 规则处理（生成 moc_<rel>.h.cpp 并编译）
```

- 输出目录：`target:autogendir()/rules/qt/qmltc/`；`--header/--impl` 用绝对路径。
- `namespace` 语义（需求 10）：默认 nil → 用 uri 生成（`MyApp.components` → `MyApp::components`）；`""` → 不传 `--namespace`，保持 qmltc 匿名命名空间行为；其他字符串原样传入。
- moc 不再由 qml 规则自己执行：qmltc 生成的 header 以 `{rules = {"qt.moc", override = true}, always_added = true}` 加到 target，build 阶段由 `qt.moc` 规则（`target:data("qt.moc")`）生成 moc 源并编译；prepare 阶段把 `<autogendir>/rules/qt/qmltc` 加入 `includedirs`，供 moc 源 `#include "<header>"` 使用。
- 增量：qmltc 任务 depfiles = 该 QML 的依赖图结果（§5.12）+ qmltc file map，depvalues = 工具 + argv（Lua table），depcache = `target:dependfile(<生成的 header>)`；因 qmltc 对内容不变的输出会保留 mtime，depmtime 用该 dependfile 的 mtime 并检查 header/impl 是否存在。
- moc 任务的增量由 `qt.moc` 规则负责（depfiles = qmltc header，depcache = `target:dependfile(<moc object/cpp>)`）。
- qmltc 输出文件名把路径分隔符展平；嵌套路径（如 `a/b.qml`）会追加路径哈希，避免与 `a_b.qml` 等展平后同名的文件冲突。
- 类型注册（qmltyperegistrar/plugin）不在本次范围。

### 5.9 AOT 统计报告

- 生效条件：`needs.cachegen`（存在需要生成的 qml/js/mjs）**且** `only_bytecode=false` **且** `aot_stats` 解析为真；`aot_stats=true` 但 AOT 无法启用时的 warning 只在 `on_config` 打印一次。
- `aot_stats` 语义：
  - `nil`（默认）：SDK 支持（找到 `qmlaotstats` 且 qmlcachegen 支持 `--dump-aot-stats`）则生成，否则静默跳过；
  - `true`：不支持则 `assert` 报错（提示需要 Qt 6.8+ 或设置 `aot_stats=false`）；
  - `false`：跳过。
- `only_bytecode=true`：不生成任何报告；若显式 `aot_stats=true` → **warning** 并忽略。
- 流程：逐文件加 `--dump-aot-stats --module-id=<URI>(<target>)` → 列表文件（`batchcmds:call` 内联函数，在 cachegen 完成后只列出**当前存在**的 sidecar）→ `qmlaotstats aggregate` → `qmlaotstats format` → 输出到 `.../rules/qt/qmlcachegen/<target>.aotstats[.txt]`。
- 任务排在 qmlcachegen 组之后（`qmlcachegen -> aotstats`）；`.mjs`/纯 `.js` 模块可能没有 sidecar；没有 sidecar 时删除旧报告并且不调用 `qmlaotstats`。

### 5.10 目录与命名汇总

| 产物 | 路径 |
|---|---|
| qml qrc | `<autogendir>/rules/qt/qml/qml_module.qrc` |
| 资源 qrc | `<autogendir>/rules/qt/qml/qml_resource.qrc` |
| loader 参数文件 | Windows 下参数过长时由 `winos.cmdargv()` 生成在系统临时目录（`@<os.tmpfile()>.args.txt`），不在工程目录、不参与增量判断 |
| importscanner 输出 | `<autogendir>/rules/qt/qmlimportscanner/<mangled>.json` |
| qmlcachegen 输出 | `<autogendir>/rules/qt/qmlcachegen/<mangled>.cpp` |
| loader | `<autogendir>/rules/qt/qmlcachegen/<target>_qmlcache_loader.cpp` |
| AOT 报告 | `<autogendir>/rules/qt/qmlcachegen/<target>.aotstats[.txt]`、`<target>.aotstatslist` |
| qmltc 输出 | `<autogendir>/rules/qt/qmltc/<rel>.h/.cpp`；moc 产物由 `qt.moc` 规则生成在 `<autogendir>/gens/...` 下 |
| qmlcachegen 依赖缓存 | `<dependir>/<相对源目录>/<qmlfile>.d`（例如 `Main.qml.d`） |
| importscanner 依赖缓存 | `<dependir>/gens/.../rules/qt/qmlimportscanner/<mangled>.json.d` |

### 5.11 增量与生成器

- prepare 阶段每个任务都有独立的 depfiles/depvalues/depcache；依赖未变化时整条命令跳过（无改动的再次构建只有依赖检查开销，实测 ~0.05s）。
- 每文件依赖缓存命名：qmlcachegen `<qmlfile>.d`（`target:dependfile(<qml 源文件>)`）；qmltc `<qmltc header>.h.d`；importscanner `<json>.d`；loader/aotstats 按各自产物命名；moc 由 `qt.moc` 规则按 moc 产物命名。
- **project 生成器（make/ninja/vs/cmake）**：`xmake project` 会真实执行一次 prepare 阶段（生成产物被写出来），但 `batchcmds:call` 的命令无法导出到生成器文件，因此生成器工程**不包含重生成规则**——生成器工程里修改 QML 后需要重新执行 `xmake project`（与 verilator 把生成放在 prepare 阶段的模型一致）。生成的 cpp 的编译规则会正常导出，`compile_commands` 也包含这些 cpp。
- `build.jobgraph` 策略默认 true。关闭该策略时 **prepare 阶段仍按 jobgraph 执行**（`xmake/actions/build/build.lua` 的 `_prepare()` 在策略判断之前调用），所以生成与编译仍可用，只有 build 阶段回退到旧的批处理流程。
- 已知既有问题（与本次改动无关）：新生成的 makefile 直接 `make` 仍受 `qt.qrc` 产物无 make 规则的 HEAD 问题影响。

### 5.12 依赖图（qmlimportscanner）与增量决策

**目标**：一个 QML/JS 文件变化时，只重生成「依赖它」的 cachegen/qmltc 源文件，而不是整个模块。

1. **扫描任务**：为每个需要生成的 `.qml/.js/.mjs` 添加一个 importscanner 任务（同组、可并行；`cachegen` 时全部，仅 `type_compiler` 时只 .qml）：
   ```sh
   <qmlimportscanner> -importPath <qt.qmldir> [-importPath <qt.qml.import>...] -qmlFiles <absfile>
   ```
   原始 JSON 写入 `<autogendir>/rules/qt/qmlimportscanner/<mangled>.json`。
   - 用 `batchcmds:call()` 执行（job 协程里 `os.iorunv`），`batchcmds:lua` 线程与其它起子进程的任务并发时捕获输出会随机失败（§3.1 第 6 条）。
   - 增量：depfiles = 该源文件，depvalues = scanner 路径 + `-importPath` 列表，depmtime = JSON mtime，depcache = `<json>.d`；源文件未变时复用上次的 JSON，不重复扫描。
   - 扫描失败（`os.iorunv` 抛错）或输出为空时删除旧 JSON：depmtime=0 会在下次构建强制重扫，避免依赖图被冻结；`qmlimportscanner` 本身对语法错误返回 0 且输出 `[]`，真正的错误由后续 qmlcachegen/qmltc 报告。
2. **解析**（`prepare_qml.lua::_get_depfiles`，在 cachegen/qmltc 任务运行时读取 JSON）：把 scanner 的 import 条目映射为本模块文件：
   - `type == "javascript"`：JS 文件路径（相对路径按被扫描文件所在目录解析）→ 直接依赖；
   - `type == "directory"`：被导入目录（也可能是 `import "lib/x.mjs"` 这种文件路径）→ 目录内本模块的 qml/js/mjs；目录在本模块之外时用 `os.files("<dir>/**.qml|js|mjs")` 列出；
   - `type == "module"`：只有 name 等于本模块 URI（或 `<URI>.` 前缀的子模块）才映射为本模块文件（精确 URI → 全部模块文件；子模块 → alias 处于对应子目录的文件）；外部模块不产生文件依赖；
   - 固定加上模块 qmldir（类型注册影响解析结果）；
   - 去重 + 排序：xmake 会逐项比对记录的文件列表，顺序必须稳定；
   - JSON 缺失或解析失败 → 退化为「依赖全部模块文件」，宁可多编译也不产生陈旧产物。
3. **每个 QML 源文件一套 depfiles/depvalues**：qmlcachegen 与 qmltc 各自独立记录（§5.6、§5.8），互不影响；因此 touch `MyButton.qml` 只会重生成 `MyButton.qml` 与依赖它的文件。
4. **depcache 命名**：cachegen 按 QML 源文件命名（`<qmlfile>.d`）；qmltc 用生成 header 的 dependfile（避免与 cachegen 冲突）；其余任务按各自产物命名（§5.10）。
5. **depmtime 取值（结论：不要用 QML 源文件 mtime）**：
   - xmake 的语义是 `depend.on_changed` 用 `set_depmtime()` 作为「上一次成功生成的基准时间 `lastmtime`」，对每个 depfile 判断 `mtime > lastmtime` 即变化；基准必须是**每次生成后前进**、且**不随源文件时间变化**的时间戳。
   - 用生成 cpp 的 mtime 正好满足：生成成功即前进；cpp 被删时 mtime=0 会强制重生成（覆盖手工删产物的场景）。
   - 若改用 QML 源文件 mtime：QML 文件自己就在 depfiles 里，比较退化为「自己 > 自己」恒假（**修改源文件不会重生成**）；同时任何比该源文件新的依赖会每次都判为变化（**无限重生成**）。
   - 特例：qmltc 对内容未变的输出会保留 mtime，所以它的 depmtime 用 dependfile 的 mtime（每次成功执行后由 xmake 写入）+ header/impl 存在性检查。
   - 时间精度：xmake 的 `depend` 用秒级 mtime 比较（与 make 一致），同一秒内「改文件 + 构建」可能漏判；测试/脚本里应保证 ≥1s 间隔。
6. **已知近似**（大体与 Qt CMake 的 `DEPENDS` 语义一致）：
   - 同一目录下隐式可见的组件没有 import 语句，`qmlimportscanner` 不报告，也不做「同目录」推断（Qt CMake 的 qmlcachegen 也只 DEPENDS 自身 + qrc/qmltypes/qmldir）；
   - 只记录直接依赖，不做传递闭包；
   - JS 文件之间的 import 不在图里：`qmlimportscanner` 对 `.js/.mjs` 输入只返回 `[]`（实测），因此「QML → JS 入口 → 再 import JS」链路中后续 JS 的变化不会触发 QML 重生成；
   - 其它 target 提供的 QML 模块（跨 target import）不追踪。

---

## 6. 版本支持矩阵

| 功能 | Qt 5.15 | Qt 6.2–6.3 | Qt 6.4+ | Qt 6.8+ |
|---|---|---|---|---|
| `qt.qml.resource` / `cachegen=false` 的 qrc 打包 | ✅ | ✅ | ✅ | ✅ |
| `qt.qml` cachegen（默认 true） | ❌ config assert（提示 `{cachegen=false}`） | ✅ | ✅ | ✅ |
| `only_bytecode` | ❌（cachegen 需 6.2+；`cachegen=false` 时忽略并 warning） | 能力探测 | 能力探测 | 能力探测 |
| `type_compiler` | ❌ assert | ❌ assert（需 6.4+） | ✅ | ✅ |
| AOT 报告 | — | 自动跳过 / `aot_stats=true` 报错 | 同左 | ✅ |

- 断言使用 `assert` + `semver`，位于 `qt.qml.on_config`（config 阶段）。
- `qt.qml.resource` 与 `cachegen=false` 的 QML 打包不依赖 Qt6 工具，可在 Qt5.15 使用。

---

## 7. 示例工程（每个特性一个）

```
tests/projects/qt/
├── qml_module/                 # cachegen 默认：打包 + AOT + loader + AOT 报告
├── qml_module_rule/            # 直接使用 qt.qml 规则：add_rules + add_files + add_values
├── qml_module_no_cachegen/     # {cachegen = false}
├── qml_module_type_compiler/   # {type_compiler = true, namespace = "MyAppNs"}；main.cpp 直接创建生成的 C++ 对象
├── qml_module_only_bytecode/   # {only_bytecode = true}（无 AOT 报告）
└── qml_module_discard/         # {discard = true}
```

每个工程结构类似：

```
xmake.lua
main.cpp              # QGuiApplication + QQmlApplicationEngine，load qrc:/qt/qml/MyApp/Main.qml，
                      # rootObjects 为空则返回非 0（用于 xmake run 验收）
                      # qmltc 工程（qml_module_type_compiler）例外：包含生成的 Main_qml.h，
                      # 直接构造 MyAppNs::Main，不使用 engine.load，见 §0.5
Main.qml              # import QtQuick / MyApp；使用 typed JS
MyButton.qml          # 跨文件组件
utils.js              # 带类型标注的 JS（.pragma library）
qmldir                # module MyApp / prefer :/qt/qml/MyApp/ / 类型条目
assets/logo.svg       # 资源文件
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
import MyApp

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
    qt_add_qml_module("*.qml", "*.js", "qmldir", "assets/*.svg", {uri = "MyApp"})
    set_runenv("QT_QPA_PLATFORM", "offscreen")
```

不用 `qt_add_qml_module`、直接使用规则（`qml_module_rule`）示例：

```lua
target("qml_module_rule")
    add_rules("qt.quickapp", "qt.qml")
    add_files("main.cpp", "*.qml", "*.js", "src/*.mjs")
    add_files("qmldir")                                     -- 无后缀，load 阶段按文件名绑定
    add_files("assets/*.svg", {rules = "qt.qml.resource"})
    add_values("qt.qml.uri", "MyApp")
    set_runenv("QT_QPA_PLATFORM", "offscreen")
```

---

## 8. 验收测试矩阵

1. **构建**：每个工程 `xmake f -c -y --qt_sdkver=6 && xmake -y` 成功。
2. **运行**：`xmake run`（offscreen）返回 0，`import MyApp`/资源加载正常。
3. **产物检查**：
   - `.../rules/qt/qmlcachegen/*.cpp`、`<target>_qmlcache_loader.cpp`、`<target>.aotstats[.txt]`、`.../rules/qt/qmlimportscanner/*.json` 存在；
   - 默认工程的 AOT 报告包含实际编译条目；js-only 工程不调用 `qmlaotstats` 且旧报告被删除；
   - qml qrc/qmltc/moc 产物路径符合 §5.10（moc 产物由 `qt.moc` 规则生成）；
   - qrc 文本由 `core.base.xml` 渲染：普通路径下与手写渲染逐字节一致，含 `&`/`<` 的 alias/path 也能正确转义并被 rcc 解析。
4. **增量（重点）**：
   - 不改文件再构建：importscanner/qmlcachegen/qmltc/rcc 全部跳过（~0.05s）。
   - touch/修改 `Main.qml`：只重生成 `Main.qml`、rcc 重编译、重新链接；其它 cachegen 源文件不变。
   - touch/修改 `MyButton.qml`：`MyButton.qml` 与「import 了本模块 URI 的文件」重生成（示例工程的 `Main.qml` 有 `import MyApp`）。
   - 只被其它文件 import 的 JS（`utils.js`）：自身 + import 它的文件重生成，未被 import 的文件不动。
   - 目录 import（`import "components"`）：被导入目录内文件变化 → import 它的文件重生成；目录内新增文件后依赖列表变化并触发重生成。
   - 移除 import / 删除文件：依赖列表收缩、import 方重生成、qrc 随文件列表变化重写、loader 随资源列表（depvalues）变化重生成，构建不残留旧对象。
   - 依赖缓存命名：`<deps>/.../Main.qml.d`（不是 `Main_qml.cpp.d`）。
5. **生成阶段并行（重点）**：importscanner 组先完成，随后 qmlcachegen 与 qmltc 两组交错执行（`-j8` 日志可见）；两组之间没有顺序边。
6. **生成物进入编译（重点）**：生成 cpp 出现在 `xmake -v` 编译命令与 `xmake project -k compile_commands` 中；不再手工插 `target:objectfiles()`。
7. **no_cachegen**：不调用 qmlcachegen/importscanner；qrc 正常编译；程序可运行。
8. **type_compiler**：qmltc 的 `.h/.cpp` 生成，header 由 `qt.moc` 规则生成 moc 源并编译链接（验证 Qt 私有 include）；`main.cpp` 直接构造 qmltc 生成的 `MyAppNs::Main`（不使用 `engine.load`），`xmake run` 返回 0；touch 后 qmltc 输出不变时不重跑 moc，再次构建为真空转。
9. **only_bytecode**：无 AOT 报告；`--only_bytecode` 生效；`only_bytecode=true` 且 `cachegen=false` 时忽略 `only_bytecode`，config 阶段给出 warning，构建按无 cachegen 流程继续。
10. **discard**：qml qrc 条目带 `empty="true"`；AOT 仍生效。
11. **Qt5 回归**：`qml_module_no_cachegen` 用 `--qt_sdkver=5` 能构建；默认工程在 Qt5 下有清晰 cachegen assert 报错。
12. **直接规则用法**：`qml_module_rule`（`add_rules("qt.qml") + add_files("*.qml", "*.js", "qmldir") + add_values("qt.qml.uri", ...)`）能构建并运行；无法识别扩展名的文件（如 `qt_add_qml_module("src/*", ...)` 匹配到的非 qml 文件）仍由 xmake 原生机制报 `unknown source file`；匹配不到文件的 pattern → 原生 `cannot match ...` warning。
13. **目录外文件**：引用 `../shared/X.qml`，warning 中出现最终 alias（相对工程根目录）。
14. **aot_stats 组合**：`only_bytecode=true, aot_stats=true` → 仅 warning，不生成报告；Qt < 6.8 环境 `aot_stats=true` → assert；`aot_stats=false` 不生成报告。
15. **namespace 语义**：默认 nil → qmltc 生成 `namespace <URI 点换 ::>`；`""` → 不传 `--namespace`（匿名命名空间）；显式字符串原样使用。
16. **多 target / 子目录**：两个 target 各自一个 QML 模块可并行构建；touch 一个 target 的 qml 不影响另一个；子目录 qml 的相对目录 import 依赖正确。
17. **健壮性**：qml 语法错误时构建失败并报 qmlcachegen 的真实错误；修复后只重生成受影响文件；`--dry-run` 不执行生成；`xmake clean`/`xmake -r` 正常。
17. **策略/生成器**：`xmake f --policies=build.jobgraph:false`（策略参数只能传给 `xmake f`）时 prepare 阶段仍执行生成、构建成功；`xmake project -k makefile/compile_commands` 成功且生成 cpp 的编译规则已导出（不导出重生成命令，属预期限制）。

---

## 9. 实施步骤

初版：

1. `xmake/includes/qt/qt_add_qml_module.lua` + 在 `xmake/includes/qt/xmake.lua` 注册：变参解析、后缀分类、无法识别的项用普通 `add_files` 兜底、values 注入、`add_rules("qt.qml")`、两条规则化 `add_files` 绑定。
2. `xmake/rules/qt/qml/` 基础框架：`xmake.lua`、`utils.lua`（values/路径/Qt 环境/工具查找）、`qrc.lua`（qrc 渲染）、`qrcgen.lua`。
3. `qt.qml.resource`（`resource.lua`，`on_prepare_files`）：先跑通 cachegen=false 的「资源 qrc + qml qrc + qt.qrc 编译 + 运行」。
4. `qt.qml` 的 `load.lua`（参数校验）与 `config.lua`（版本/工具检查）。
5. `build.lua`：`on_prepare_files(jobgraph)` 生成阶段——importscanner、qmlcachegen、loader、qmltc、AOT 报告；生成 cpp 用 `target:add("files", ..., {always_added = true})` 注册。
6. AOT 报告、`only_bytecode`（含 aot_stats warning）、`discard`、`aot_stats` 语义。
7. 创建测试工程 + typed JS；执行 §8 验收矩阵。

第二轮优化：

8. 注入 `qt.qrc`/`qt.moc` 规则，删除 rcc/moc 自行探测；qmltc 头文件改由 `qt.moc` 规则在 build 阶段处理。
9. `qt.qml` 增加 `set_extensions`，`qmldir` 在 load 阶段按文件名绑定；新增 `qml_module_rule` 示例。
10. config 只探测环境；qrc/rsp/qmltc file map 移到 prepare 阶段同步生成；删除 `qrcgen.lua`/`aotstatsgen.lua`/manifest。
11. 源文件列表改从 prepare 的 sourcebatch 获取，删除 `target:data("qt.qml.setup")`。
12. 工具查找改 `lib.detect.find_tool`（version = true），选项能力改 `lib.detect.has_flags`，新增 `detect/tools/find_qmlcachegen.lua`；depvalues 直接传 table。
13. `namespace` 默认 nil 语义；合并冗余函数；`on_prepare_files` 维持 `{jobgraph = true}`（不加 batch/distcc）。
14. 代码风格收尾（Apache header、`@file`、英文注释说明 CMake 对应行为与描述域限制）、`git diff` 检查、最终全量验证。

第三轮优化：

15. qrc 自动生成改用 `core.base.xml`：`qrc.lua` 的 `generate_qrc()` 用 `xml.new()`/`xml.text()` 构建 `<RCC>` 节点树后 `xml.encode()`，删除手写 XML 转义；按 §8 重跑构建/运行/增量回归。

第四轮优化：

16. `only_bytecode` 在 `cachegen` 关闭时改为忽略并 warning，删除 `get_setting()` 的强制开启逻辑。
17. 删除 loader rsp：`_add_loader()` 直接用 argv 调用 qmlcachegen，Windows 下用 `winos.cmdargv(args, {raw = true})` 自动转成临时参数文件；`core.base.winos::cmdargv()` 增加 `raw` 模式（逐行原样、UTF-8），按 §8 重跑构建/运行/增量回归（含含空格路径的工程）。

第五轮优化（当前实现）：

18. qmltc 测试工程改为直接创建生成的 C++ 对象：`tests/projects/qt/qml_module_type_compiler/main.cpp` 包含 `Main_qml.h` 并构造 `MyAppNs::Main`，不再使用 `engine.load`；按 §8 重跑干净构建与运行回归。

---

## 10. 范围与使用约定

- **一个 target 一个 QML 模块**；多次调用合并文件；qmldir 由用户提供（含 `prefer :/qt/qml/<URI>/` 与类型条目）。
- `qt.qml.resource` 适用于任意后缀的资源文件（显式 `{rules = "qt.qml.resource"}` 绑定）。
- 静态库 target 的资源可能被链接器丢弃：**不由 qt 规则处理**，用户自行通过 `add_linkgroups("xxx", {whole = true})` 解决。
- 不在本次范围：plugin 目标/qmltypes/qmldir 自动生成、`qmllint`、`qmlsc` static/direct-calls、部署、Qt5 qmlcachegen 流程、qmltc 类型注册。
- `qmlimportscanner` 仅用于构建期依赖图（§5.12），不承担 QML 插件/静态导入链接（`qt_import_qml_plugins` 的职责不在本规则）。
- qmltc 在本实现中只负责「编译成 C++ 并参与构建」，不向 QML 引擎注册生成类型。

---

## 11. 风险与待确认

1. **无法识别项的报错信息来自 xmake 原生机制**：为 `unknown source file: <file>` / `cannot match ...`，不包含 `qt_add_qml_module` 上下文；这是本轮要求的「由 xmake 自带机制处理」的直接结果。写法上应使用带明确后缀的 pattern（如 `src/*.qml`、`assets/*.png`）。
2. **qmltc 私有 include**：依赖 `qt.quickapp` 的 `load.lua` 提供；type_compiler 示例工程验证，不足则按 `Qt<模块>Private` framework 方式补齐。
3. **AOT 报告版本**：`qmlaotstats`/`--dump-aot-stats` 需 Qt 6.8+；`aot_stats` 的 auto/true/false 语义已按反馈实现；`only_bytecode` 组合 warning。
4. **生成器**：prepare 阶段的重生成命令（`batchcmds:call`/`batchcmds:lua`）无法导出到 make/ninja/VS/CMake 工程文件，生成器工程里修改 QML 后需要重新执行 `xmake project`；生成的 cpp 编译规则会正常导出，`compile_commands` 包含生成 cpp（`xmake project` 期间已生成）。与 verilator 等「prepare 阶段生成」的规则模型一致。
5. **跨平台**：Windows（`.exe`、路径/引号）、macOS（framework 路径）本次未实测，工具查找与 qrc 路径处理按现有 qt 规则风格实现。
6. **生成脚本路径**：第二轮已删除 `qrcgen.lua`/`aotstatsgen.lua`（改为 prepare 内同步写入与 `batchcmds:call` 内联函数），不再有运行期 xmake 安装位置依赖。
7. **并发 `batchcmds:lua` + 捕获子进程输出不可靠**：`batchcmds:lua` 线程与其它会起子进程的任务并发时，脚本里调用 `os.iorunv()` 会随机失败（实测 8 个 lua 任务 + 8 个 `cmds:vrunv` 并发，每轮 40 个结果丢 1–3 个且无报错），因此 importscanner 用 `batchcmds:call`；aotstats 列表同样用 `batchcmds:call` 内联生成。
8. **隐式同目录依赖**：同一目录下被隐式引用（无 import 语句）的组件不在依赖图里，与 Qt CMake 的 DEPENDS 行为一致；修改这类文件不会触发引用方重生成。
9. **跨 target QML 模块**：通过 `qt.qml.import` 引用的其它模块不在本 target 的依赖图里，其文件变化不触发生成。
10. **`find_program` 的 PATH 兜底**：`lib.detect.find_tool` 在给出的 SDK 目录找不到时会回落到系统 PATH；`find_sdk_tool` 会校验 `tool.program` 必须位于 SDK 目录内，否则按未找到处理，cachekey 同时包含 `qt.sdkver` 与目录哈希，避免多 SDK/就地升级导致的缓存串用。
11. **`has_flags` 的工具名**：`has_flags` 依赖 `find_tool` 返回的 `tool.name`（内部会拼 `core.tools.<name>.has_flags`）；Qt 工具名默认无法解析，因此新增 `detect/tools/find_qmlcachegen.lua`。`--dump-aot-stats` 需与 `--module-id` 一起探测，否则 qmlcachegen 会以非 0 退出导致误判；`has_flags` 调用带 `version = true`，SDK 就地升级后缓存会失效。
12. **dry-run**：`xmake --dry-run` 不写 qrc/map（Windows 下 `winos.cmdargv()` 的临时参数文件在系统临时目录，不影响工程），也不把生成的 qrc 加入 target（`qt.qrc` 规则在 dry-run 下仍会读取 qrc 生成依赖列表，缺文件会报错），因此 dry-run 输出不含 qrc 的编译命令。
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
| 5. `assert` 版本检查、config 阶段 | §5.3、§6（`qt.qml.on_config`） |
| 6. 遵循 xmake 风格 | 文件/命名/钩子/import 方式对齐现有 qt、protobuf、c++ modules 规则 |
| 7. 钩子阶段不冲突、留扩展空间 | §3.3、§3.4（`on_load`/`on_config`/`on_prepare_files(jobgraph)`，资源规则 `on_prepare_files`；qrc/map 在 prepare 回调里同步生成，不再需要 `add_orders`） |
| 8. 示例工程 | §7（每个特性一个） |
| 9. 参考 CMake | §2（命令/布局/loader/AOT 流程均按 CMake 实测实现） |
| 10. cachegen/qmltc 基于 jobgraph、两组并行、生成 cpp 交给 c++ 规则 | §3.1–§3.3、§5.1 |
| 11. ~~恢复 qrcgen/aotstatsgen 独立脚本并用 batchcmds:lua 调用~~ | 已被第二轮需求 8 取代（§0.1 第 8 条），脚本已删除 |
| 12. qmlimportscanner 依赖图、每个 QML 源文件一套 depfiles/depvalues | §5.12 |
| 13. depcache 命名 `<qmlfile>.d`、depmtime 取值结论 | §5.6、§5.12 第 4/5 条 |
| 14. 注入 qt.qrc/qt.moc 规则，复用已有工具探测 | §0.1-1、§3.2、§5.2、§5.3、§5.8 |
| 15. `qt.qml` 文件后缀支持、直接 add_rules+add_files+add_values | §0.1-2、§3.2、§5.1、§7（`qml_module_rule`） |
| 16. config 只探测环境，qrc 在 prepare 生成 | §0.1-3、§3.3、§3.4、§5.1、§5.5 |
| 17. 源文件列表不写 `target:data`，prepare 用 sourcebatch | §0.1-4、§5.1 |
| 18. `on_prepare_files` 的 batch/distcc 评估 | §0.1-5、§5.1（规则定义处有注释） |
| 19. `lib.detect.find_tool` + version，不重复缓存 | §0.1-6、§5.3 |
| 20. depvalues 直接支持 Lua table | §0.1-7、§5.6、§5.8、§5.9 |
| 21. 合并冗余函数/脚本 | §0.1-8 |
| 22. `lib.detect.has_flags` 探测选项能力 | §0.1-9、§5.3 |
| 23. qmltc namespace 默认 nil / `""` 语义 | §0.1-10、§5.8 |
| 24. qrc 自动生成使用 xmake 自带 `core.base.xml` | §0.2、§5.2、§5.5 |
| 25. `only_bytecode` 在 `cachegen` 关闭时忽略并 warning；loader 不生成 rsp，改用 `winos.cmdargv`（raw 模式）处理超长参数 | §0.4、§5.1、§5.7 |
| 26. qmltc 测试用例不再 `engine.load`，直接创建生成的 C++ 对象 | §0.5、§7、§8 |

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
