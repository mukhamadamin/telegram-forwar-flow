# Telegram-iOS: submodules/ForwardFlow/BUILD
#   Sources/ForwardFlowTimeline.swift, Sources/ForwardFlowAnimator.swift
#   Resources/ForwardFlow.metal
# A top-level submodule (not under TelegramUI): ShareController depends on it and cannot depend on TelegramUI.
# apple_resource_bundle compiles the .metal file into default.metallib inside the bundle.
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle")
load("//build-system/bazel-utils:plist_fragment.bzl", "plist_fragment")

filegroup(
    name = "ForwardFlowResources",
    srcs = glob(["Resources/**/*"]),
    visibility = ["//visibility:public"],
)

plist_fragment(
    name = "ForwardFlowResourcesBundleInfoPlist",
    extension = "plist",
    template = """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.ForwardFlowResources</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>ForwardFlow</string>
    """,
)

apple_resource_bundle(
    name = "ForwardFlowResourcesBundle",
    infoplists = [":ForwardFlowResourcesBundleInfoPlist"],
    resources = [":ForwardFlowResources"],
)

swift_library(
    name = "ForwardFlow",
    module_name = "ForwardFlow",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    data = [":ForwardFlowResourcesBundle"],
    deps = [],
    visibility = ["//visibility:public"],
)
