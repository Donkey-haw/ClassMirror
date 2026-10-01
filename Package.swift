// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClassMirror",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ClassMirror", targets: ["ClassMirrorApp"]),
        .library(name: "ClassMirrorCore", targets: ["ClassMirrorCore"]),
        .library(name: "AirPlayCoreC", targets: ["AirPlayCoreC"])
    ],
    targets: [
        .systemLibrary(
            name: "CLibPlist",
            path: "Sources/CLibPlist",
            pkgConfig: "libplist-2.0",
            providers: [.brew(["libplist"])]
        ),
        .systemLibrary(
            name: "COpenSSL",
            path: "Sources/COpenSSL",
            pkgConfig: "openssl",
            providers: [.brew(["openssl@3"])]
        ),
        .target(
            name: "AirPlayCoreC",
            dependencies: ["CLibPlist", "COpenSSL"],
            path: "ThirdParty/AirPlayCoreTarget",
            exclude: [
                "Upstream/CMakeLists.txt",
                "Upstream/llhttp/CMakeLists.txt",
                "Upstream/llhttp/LICENSE-MIT",
                "Upstream/playfair/CMakeLists.txt",
                "Upstream/playfair/LICENSE.md"
            ],
            sources: [
                "ClassMirrorReceiver.c",
                "Upstream"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("Upstream"),
                .headerSearchPath("Upstream/llhttp"),
                .headerSearchPath("Upstream/playfair"),
                .define("EXTERNAL_DNS_SD"),
                .define("__STDC_CONSTANT_MACROS"),
                .define("__STDC_LIMIT_MACROS"),
                .define("TARGET_POSIX"),
                .define("_REENTRANT"),
                .define("UXPLAY_HAVE_APPLE_P2P", .when(platforms: [.macOS])),
                .define("PLIST_210"),
                .define("PLIST_230")
            ]
        ),
        .target(
            name: "ClassMirrorCore",
            dependencies: ["AirPlayCoreC"],
            path: "Sources/ClassMirrorCore"
        ),
        .executableTarget(
            name: "ClassMirrorApp",
            dependencies: ["ClassMirrorCore"],
            path: "Sources/ClassMirrorApp"
        ),
        .testTarget(
            name: "ClassMirrorCoreTests",
            dependencies: ["ClassMirrorCore"],
            path: "Tests/ClassMirrorCoreTests"
        ),
        .testTarget(
            name: "AirPlayCoreCTests",
            dependencies: ["AirPlayCoreC"],
            path: "Tests/AirPlayCoreCTests"
        )
    ]
)
