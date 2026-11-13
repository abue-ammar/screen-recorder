// swift-tools-version: 6.4
//
//  Package.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/6/26.
//

import PackageDescription

let package = Package(
    name: "SliceCore",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "SliceCore", targets: ["SliceCore"]),
    ],
    targets: [
        .target(name: "SliceCore", resources: [
            .copy("Resources/Shaders/ClickRipple.metal.txt"),
            .copy("Resources/Shaders/LiquidGlass.metal.txt"),
            .copy("Resources/Shaders/ZoomBlur.metal.txt"),
            .copy("Resources/Shaders/CameraBlur.metal.txt"),
            .copy("Resources/Shaders/ScreenTilt.metal.txt"),
            .copy("Resources/Cursors"),
            .copy("Resources/Sounds"),
        ]),
        .testTarget(name: "SliceCoreTests", dependencies: ["SliceCore"]),
    ],
    swiftLanguageModes: [.v6]
)
