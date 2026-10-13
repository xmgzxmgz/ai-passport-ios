#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 PassportSlot.xcodeproj/project.pbxproj

用法： python make_xcodeproj.py
生成后会立刻用 pbxproj 库回读校验一遍，确保 Xcode 能打开。
"""
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                     # ios-app/
PROJ_NAME = "PassportSlot"
SRC_DIR = os.path.join(ROOT, PROJ_NAME)          # ios-app/PassportSlot/
XCODEPROJ = os.path.join(ROOT, PROJ_NAME + ".xcodeproj")

# 参与编译的 Swift 源文件（顺序无关）
SWIFT_FILES = [
    "PassportSlotApp.swift",
    "Models.swift",
    "PassportProtocol.swift",
    "PassportBleClient.swift",
    "FirmwareStore.swift",
    "ContentView.swift",
]
RESOURCE_FILES = ["Assets.xcassets"]

BUNDLE_ID = "cn.folotoy.passportslot"
DISPLAY_NAME = "AI Passport 安装器"
DEPLOY_TARGET = "17.0"
SWIFT_VERSION = "5.0"


def oid(*parts):
    """稳定的 24 位十六进制对象 ID"""
    h = hashlib.sha1("::".join(parts).encode("utf-8")).hexdigest()
    return h[:24].upper()


def q(value):
    """pbxproj 字符串：含特殊字符就加双引号并转义"""
    if value == "":
        return '""'
    safe = all(c.isalnum() or c in "._/$-+" for c in value)
    if safe:
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def build():
    ids = {}

    def i(key):
        if key not in ids:
            ids[key] = oid(PROJ_NAME, key)
        return ids[key]

    # ---------- 对象 ID ----------
    product_ref      = i("product")
    main_group       = i("maingroup")
    src_group        = i("srcgroup")
    products_group   = i("productsgroup")
    project_obj      = i("project")
    target           = i("target")
    sources_phase    = i("sources")
    frameworks_phase = i("frameworks")
    resources_phase  = i("resources")
    proj_cfg_list    = i("projcfglist")
    proj_debug       = i("projdebug")
    proj_release     = i("projrelease")
    tgt_cfg_list     = i("tgtcfglist")
    tgt_debug        = i("tgtdebug")
    tgt_release      = i("tgtrelease")

    file_refs = {n: i("fileref:" + n) for n in SWIFT_FILES + RESOURCE_FILES}
    build_files = {n: i("buildfile:" + n) for n in SWIFT_FILES + RESOURCE_FILES}

    L = []
    add = L.append

    add("// !$*UTF8*$!")
    add("{")
    add("\tarchiveVersion = 1;")
    add("\tclasses = {")
    add("\t};")
    add("\tobjectVersion = 56;")
    add("\tobjects = {")
    add("")

    # ---------- PBXBuildFile ----------
    add("/* Begin PBXBuildFile section */")
    for n in SWIFT_FILES:
        add(f"\t\t{build_files[n]} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[n]} /* {n} */; }};")
    for n in RESOURCE_FILES:
        add(f"\t\t{build_files[n]} /* {n} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_refs[n]} /* {n} */; }};")
    add("/* End PBXBuildFile section */")
    add("")

    # ---------- PBXFileReference ----------
    add("/* Begin PBXFileReference section */")
    add(f'\t\t{product_ref} /* {PROJ_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {PROJ_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    for n in SWIFT_FILES:
        add(f'\t\t{file_refs[n]} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(n)}; sourceTree = "<group>"; }};')
    for n in RESOURCE_FILES:
        add(f'\t\t{file_refs[n]} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {q(n)}; sourceTree = "<group>"; }};')
    add("/* End PBXFileReference section */")
    add("")

    # ---------- PBXFrameworksBuildPhase ----------
    add("/* Begin PBXFrameworksBuildPhase section */")
    add(f"\t\t{frameworks_phase} /* Frameworks */ = {{")
    add("\t\t\tisa = PBXFrameworksBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXFrameworksBuildPhase section */")
    add("")

    # ---------- PBXGroup ----------
    add("/* Begin PBXGroup section */")
    # 主组
    add(f"\t\t{main_group} = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{src_group} /* {PROJ_NAME} */,")
    add(f"\t\t\t\t{products_group} /* Products */,")
    add("\t\t\t);")
    add('\t\t\tsourceTree = "<group>";')
    add("\t\t};")
    # 源码组
    add(f"\t\t{src_group} /* {PROJ_NAME} */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for n in SWIFT_FILES + RESOURCE_FILES:
        add(f"\t\t\t\t{file_refs[n]} /* {n} */,")
    add("\t\t\t);")
    add(f"\t\t\tpath = {PROJ_NAME};")
    add('\t\t\tsourceTree = "<group>";')
    add("\t\t};")
    # 产物组
    add(f"\t\t{products_group} /* Products */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{product_ref} /* {PROJ_NAME}.app */,")
    add("\t\t\t);")
    add("\t\t\tname = Products;")
    add('\t\t\tsourceTree = "<group>";')
    add("\t\t};")
    add("/* End PBXGroup section */")
    add("")

    # ---------- PBXNativeTarget ----------
    add("/* Begin PBXNativeTarget section */")
    add(f"\t\t{target} /* {PROJ_NAME} */ = {{")
    add("\t\t\tisa = PBXNativeTarget;")
    add(f"\t\t\tbuildConfigurationList = {tgt_cfg_list} /* Build configuration list for PBXNativeTarget \"{PROJ_NAME}\" */;")
    add("\t\t\tbuildPhases = (")
    add(f"\t\t\t\t{sources_phase} /* Sources */,")
    add(f"\t\t\t\t{frameworks_phase} /* Frameworks */,")
    add(f"\t\t\t\t{resources_phase} /* Resources */,")
    add("\t\t\t);")
    add("\t\t\tbuildRules = (")
    add("\t\t\t);")
    add("\t\t\tdependencies = (")
    add("\t\t\t);")
    add(f"\t\t\tname = {PROJ_NAME};")
    add("\t\t\tproductName = " + PROJ_NAME + ";")
    add(f"\t\t\tproductReference = {product_ref} /* {PROJ_NAME}.app */;")
    add('\t\t\tproductType = "com.apple.product-type.application";')
    add("\t\t};")
    add("/* End PBXNativeTarget section */")
    add("")

    # ---------- PBXProject ----------
    add("/* Begin PBXProject section */")
    add(f"\t\t{project_obj} /* Project object */ = {{")
    add("\t\t\tisa = PBXProject;")
    add("\t\t\tattributes = {")
    add("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    add("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    add("\t\t\t\tLastUpgradeCheck = 1500;")
    add("\t\t\t\tTargetAttributes = {")
    add(f"\t\t\t\t\t{target} = {{")
    add("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    add("\t\t\t\t\t};")
    add("\t\t\t\t};")
    add("\t\t\t};")
    add(f"\t\t\tbuildConfigurationList = {proj_cfg_list} /* Build configuration list for PBXProject \"{PROJ_NAME}\" */;")
    add('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    add("\t\t\tdevelopmentRegion = en;")
    add("\t\t\thasScannedForEncodings = 0;")
    add("\t\t\tknownRegions = (")
    add("\t\t\t\ten,")
    add("\t\t\t\tBase,")
    add('\t\t\t\t"zh-Hans",')
    add("\t\t\t);")
    add(f"\t\t\tmainGroup = {main_group};")
    add(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
    add('\t\t\tprojectDirPath = "";')
    add('\t\t\tprojectRoot = "";')
    add("\t\t\ttargets = (")
    add(f"\t\t\t\t{target} /* {PROJ_NAME} */,")
    add("\t\t\t);")
    add("\t\t};")
    add("/* End PBXProject section */")
    add("")

    # ---------- PBXResourcesBuildPhase ----------
    add("/* Begin PBXResourcesBuildPhase section */")
    add(f"\t\t{resources_phase} /* Resources */ = {{")
    add("\t\t\tisa = PBXResourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    for n in RESOURCE_FILES:
        add(f"\t\t\t\t{build_files[n]} /* {n} in Resources */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXResourcesBuildPhase section */")
    add("")

    # ---------- PBXSourcesBuildPhase ----------
    add("/* Begin PBXSourcesBuildPhase section */")
    add(f"\t\t{sources_phase} /* Sources */ = {{")
    add("\t\t\tisa = PBXSourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    for n in SWIFT_FILES:
        add(f"\t\t\t\t{build_files[n]} /* {n} in Sources */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXSourcesBuildPhase section */")
    add("")

    # ---------- XCBuildConfiguration ----------
    add("/* Begin XCBuildConfiguration section */")

    # 工程级 Debug
    add(f"\t\t{proj_debug} /* Debug */ = {{")
    add("\t\t\tisa = XCBuildConfiguration;")
    add("\t\t\tbuildSettings = {")
    for line in [
        "ALWAYS_SEARCH_USER_PATHS = NO;",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;",
        "CLANG_ANALYZER_NONNULL = YES;",
        "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;",
        "CLANG_CXX_LANGUAGE_STANDARD = \"gnu++20\";",
        "CLANG_ENABLE_MODULES = YES;",
        "CLANG_ENABLE_OBJC_ARC = YES;",
        "CLANG_ENABLE_OBJC_WEAK = YES;",
        "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;",
        "CLANG_WARN_BOOL_CONVERSION = YES;",
        "CLANG_WARN_COMMA = YES;",
        "CLANG_WARN_CONSTANT_CONVERSION = YES;",
        "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;",
        "CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;",
        "CLANG_WARN_DOCUMENTATION_COMMENTS = YES;",
        "CLANG_WARN_EMPTY_BODY = YES;",
        "CLANG_WARN_ENUM_CONVERSION = YES;",
        "CLANG_WARN_INFINITE_RECURSION = YES;",
        "CLANG_WARN_INT_CONVERSION = YES;",
        "CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;",
        "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;",
        "CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;",
        "CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;",
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;",
        "CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;",
        "CLANG_WARN_STRICT_PROTOTYPES = YES;",
        "CLANG_WARN_SUSPICIOUS_MOVE = YES;",
        "CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;",
        "CLANG_WARN_UNREACHABLE_CODE = YES;",
        "CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;",
        "COPY_PHASE_STRIP = NO;",
        "DEBUG_INFORMATION_FORMAT = dwarf;",
        "ENABLE_STRICT_OBJC_MSGSEND = YES;",
        "ENABLE_TESTABILITY = YES;",
        "ENABLE_USER_SCRIPT_SANDBOXING = YES;",
        "GCC_C_LANGUAGE_STANDARD = gnu17;",
        "GCC_DYNAMIC_NO_PIC = NO;",
        "GCC_NO_COMMON_BLOCKS = YES;",
        "GCC_OPTIMIZATION_LEVEL = 0;",
        "GCC_PREPROCESSOR_DEFINITIONS = (",
        "\t\t\t\t\t\"DEBUG=1\",",
        "\t\t\t\t\t\"$(inherited)\",",
        "\t\t\t\t);",
        "GCC_WARN_64_TO_32_BIT_CONVERSION = YES;",
        "GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;",
        "GCC_WARN_UNDECLARED_SELECTOR = YES;",
        "GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;",
        "GCC_WARN_UNUSED_FUNCTION = YES;",
        "GCC_WARN_UNUSED_VARIABLE = YES;",
        f"IPHONEOS_DEPLOYMENT_TARGET = {DEPLOY_TARGET};",
        "LOCALIZATION_PREFERS_STRING_CATALOGS = YES;",
        "MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;",
        "MTL_FAST_MATH = YES;",
        "ONLY_ACTIVE_ARCH = YES;",
        "SDKROOT = iphoneos;",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\";",
        "SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";",
    ]:
        add("\t\t\t\t" + line)
    add("\t\t\t};")
    add("\t\t\tname = Debug;")
    add("\t\t};")

    # 工程级 Release
    add(f"\t\t{proj_release} /* Release */ = {{")
    add("\t\t\tisa = XCBuildConfiguration;")
    add("\t\t\tbuildSettings = {")
    for line in [
        "ALWAYS_SEARCH_USER_PATHS = NO;",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;",
        "CLANG_ANALYZER_NONNULL = YES;",
        "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;",
        "CLANG_CXX_LANGUAGE_STANDARD = \"gnu++20\";",
        "CLANG_ENABLE_MODULES = YES;",
        "CLANG_ENABLE_OBJC_ARC = YES;",
        "CLANG_ENABLE_OBJC_WEAK = YES;",
        "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;",
        "CLANG_WARN_BOOL_CONVERSION = YES;",
        "CLANG_WARN_COMMA = YES;",
        "CLANG_WARN_CONSTANT_CONVERSION = YES;",
        "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;",
        "CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;",
        "CLANG_WARN_DOCUMENTATION_COMMENTS = YES;",
        "CLANG_WARN_EMPTY_BODY = YES;",
        "CLANG_WARN_ENUM_CONVERSION = YES;",
        "CLANG_WARN_INFINITE_RECURSION = YES;",
        "CLANG_WARN_INT_CONVERSION = YES;",
        "CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;",
        "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;",
        "CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;",
        "CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;",
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;",
        "CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;",
        "CLANG_WARN_STRICT_PROTOTYPES = YES;",
        "CLANG_WARN_SUSPICIOUS_MOVE = YES;",
        "CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;",
        "CLANG_WARN_UNREACHABLE_CODE = YES;",
        "CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;",
        "COPY_PHASE_STRIP = NO;",
        "DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";",
        "ENABLE_NS_ASSERTIONS = NO;",
        "ENABLE_STRICT_OBJC_MSGSEND = YES;",
        "ENABLE_USER_SCRIPT_SANDBOXING = YES;",
        "GCC_C_LANGUAGE_STANDARD = gnu17;",
        "GCC_NO_COMMON_BLOCKS = YES;",
        "GCC_WARN_64_TO_32_BIT_CONVERSION = YES;",
        "GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;",
        "GCC_WARN_UNDECLARED_SELECTOR = YES;",
        "GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;",
        "GCC_WARN_UNUSED_FUNCTION = YES;",
        "GCC_WARN_UNUSED_VARIABLE = YES;",
        f"IPHONEOS_DEPLOYMENT_TARGET = {DEPLOY_TARGET};",
        "LOCALIZATION_PREFERS_STRING_CATALOGS = YES;",
        "MTL_ENABLE_DEBUG_INFO = NO;",
        "MTL_FAST_MATH = YES;",
        "SDKROOT = iphoneos;",
        "SWIFT_COMPILATION_MODE = wholemodule;",
        "VALIDATE_PRODUCT = YES;",
    ]:
        add("\t\t\t\t" + line)
    add("\t\t\t};")
    add("\t\t\tname = Release;")
    add("\t\t};")

    # 目标级公共设置
    target_settings = [
        "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;",
        "CODE_SIGN_STYLE = Automatic;",
        "CURRENT_PROJECT_VERSION = 1;",
        "ENABLE_PREVIEWS = YES;",
        "GENERATE_INFOPLIST_FILE = YES;",
        f"INFOPLIST_KEY_CFBundleDisplayName = {q(DISPLAY_NAME)};",
        f'INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription = {q("需要蓝牙权限，才能连接 AI Passport 并把固件写入设备的玩法槽。")};',
        f'INFOPLIST_KEY_NSBluetoothPeripheralUsageDescription = {q("需要蓝牙权限，才能连接 AI Passport 并把固件写入设备的玩法槽。")};',
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;",
        "INFOPLIST_KEY_UILaunchScreen_Generation = YES;",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations = \"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\";",
        "INFOPLIST_KEY_UIUserInterfaceStyle = Automatic;",
        "LD_RUNPATH_SEARCH_PATHS = (",
        "\t\t\t\t\t\"$(inherited)\",",
        "\t\t\t\t\t\"@executable_path/Frameworks\",",
        "\t\t\t\t);",
        "MARKETING_VERSION = 1.0;",
        f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};",
        "PRODUCT_NAME = \"$(TARGET_NAME)\";",
        "SWIFT_EMIT_LOC_STRINGS = YES;",
        f"SWIFT_VERSION = {SWIFT_VERSION};",
        "TARGETED_DEVICE_FAMILY = \"1,2\";",
    ]

    for cfg_id, cfg_name in ((tgt_debug, "Debug"), (tgt_release, "Release")):
        add(f"\t\t{cfg_id} /* {cfg_name} */ = {{")
        add("\t\t\tisa = XCBuildConfiguration;")
        add("\t\t\tbuildSettings = {")
        for line in target_settings:
            add("\t\t\t\t" + line)
        add("\t\t\t};")
        add(f"\t\t\tname = {cfg_name};")
        add("\t\t};")

    add("/* End XCBuildConfiguration section */")
    add("")

    # ---------- XCConfigurationList ----------
    add("/* Begin XCConfigurationList section */")
    add(f"\t\t{proj_cfg_list} /* Build configuration list for PBXProject \"{PROJ_NAME}\" */ = {{")
    add("\t\t\tisa = XCConfigurationList;")
    add("\t\t\tbuildConfigurations = (")
    add(f"\t\t\t\t{proj_debug} /* Debug */,")
    add(f"\t\t\t\t{proj_release} /* Release */,")
    add("\t\t\t);")
    add("\t\t\tdefaultConfigurationIsVisible = 0;")
    add("\t\t\tdefaultConfigurationName = Release;")
    add("\t\t};")
    add(f"\t\t{tgt_cfg_list} /* Build configuration list for PBXNativeTarget \"{PROJ_NAME}\" */ = {{")
    add("\t\t\tisa = XCConfigurationList;")
    add("\t\t\tbuildConfigurations = (")
    add(f"\t\t\t\t{tgt_debug} /* Debug */,")
    add(f"\t\t\t\t{tgt_release} /* Release */,")
    add("\t\t\t);")
    add("\t\t\tdefaultConfigurationIsVisible = 0;")
    add("\t\t\tdefaultConfigurationName = Release;")
    add("\t\t};")
    add("/* End XCConfigurationList section */")
    add("")

    add("\t};")
    add(f"\trootObject = {project_obj} /* Project object */;")
    add("}")
    add("")

    return "\n".join(L)


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "%(TARGET_ID)s"
               BuildableName = "%(PROJ)s.app"
               BlueprintName = "%(PROJ)s"
               ReferencedContainer = "container:%(PROJ)s.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "%(TARGET_ID)s"
            BuildableName = "%(PROJ)s.app"
            BlueprintName = "%(PROJ)s"
            ReferencedContainer = "container:%(PROJ)s.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "%(TARGET_ID)s"
            BuildableName = "%(PROJ)s.app"
            BlueprintName = "%(PROJ)s"
            ReferencedContainer = "container:%(PROJ)s.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def main():
    # 源文件必须都在
    missing = [n for n in SWIFT_FILES + RESOURCE_FILES
               if not os.path.exists(os.path.join(SRC_DIR, n))]
    if missing:
        print("缺少源文件：" + ", ".join(missing))
        return 1

    content = build()

    os.makedirs(XCODEPROJ, exist_ok=True)
    pbx_path = os.path.join(XCODEPROJ, "project.pbxproj")
    with open(pbx_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)
    print("已写出 " + pbx_path)

    # 共享 scheme，保证 Xcode 一打开就能直接 Run（也方便 CI 用 -scheme）
    scheme_dir = os.path.join(XCODEPROJ, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    target_id = oid(PROJ_NAME, "target")
    scheme_path = os.path.join(scheme_dir, PROJ_NAME + ".xcscheme")
    with open(scheme_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(SCHEME % {"TARGET_ID": target_id, "PROJ": PROJ_NAME})
    print("已写出 " + scheme_path)

    # 回读校验
    from pbxproj import XcodeProject
    try:
        project = XcodeProject.load(pbx_path)
    except Exception as exc:                       # noqa: BLE001
        print("！！回读失败：" + repr(exc))
        return 2

    targets = project.get_target_by_name(PROJ_NAME)
    if targets is None:
        print("！！回读成功但找不到目标 " + PROJ_NAME)
        return 3
    if isinstance(targets, list):
        targets = targets[0] if targets else None
    if targets is None:
        print("！！目标列表为空")
        return 3

    t = targets
    print("校验通过：")
    print("  目标        " + str(t.name))
    print("  产物类型    " + str(t.get("productType", "")))
    phases = t.get("buildPhases", []) or []
    print("  构建阶段数  " + str(len(phases)))
    refs = project.objects.get_objects_in_section("PBXFileReference")
    names = sorted(os.path.basename(str(getattr(p, "path", ""))) for p in refs if getattr(p, "path", None))
    print("  文件引用    " + ", ".join(names))
    srcs = project.objects.get_objects_in_section("PBXBuildFile")
    print("  编译条目数  " + str(len(srcs)))
    print("  Bundle ID   " + BUNDLE_ID)
    return 0


if __name__ == "__main__":
    sys.exit(main())
