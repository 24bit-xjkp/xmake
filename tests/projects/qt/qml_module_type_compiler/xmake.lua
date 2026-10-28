add_rules("mode.debug", "mode.release")

includes("@builtin/qt")

target("qml_module_type_compiler")
    add_rules("qt.quickapp")
    add_files("main.cpp")
    qt_add_qml_module("*.qml", "*.js", "qmldir", "assets/*.svg", {uri = "MyApp", type_compiler = true, namespace = "MyAppNs"})
    set_runenv("QT_QPA_PLATFORM", "offscreen")
