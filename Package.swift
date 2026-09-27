// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [.library(name: "AgentCore", targets: ["AgentCore"])]
var targets: [Target] = [
    .target(name: "AgentCore"),
    .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"])
]

#if os(macOS)
products += [
    .executable(name: "MacAgent", targets: ["MacAgent"]),
    .executable(name: "RealtimeLiveCanary", targets: ["RealtimeLiveCanary"]),
    .executable(name: "MacControlCanary", targets: ["MacControlCanary"])
]
targets += [
    .target(name: "MacRuntime", dependencies: ["AgentCore"]),
    .executableTarget(name: "MacAgent", dependencies: ["AgentCore", "MacRuntime"]),
    .executableTarget(name: "RealtimeLiveCanary", dependencies: ["AgentCore", "MacRuntime"]),
    .executableTarget(name: "MacControlCanary", dependencies: ["AgentCore", "MacRuntime"]),
    .testTarget(name: "MacRuntimeTests", dependencies: ["AgentCore", "MacRuntime"])
]
#endif

let package = Package(
    name: "MetaAIGlasses",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
