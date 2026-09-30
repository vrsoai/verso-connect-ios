// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VersoConnect",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "VersoConnect", targets: ["VersoConnect"]),
    ],
    targets: [
        .target(name: "VersoConnect", path: "Sources/VersoConnect"),
    ]
)
