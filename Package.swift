// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "OpenRouterForFoundationModels",
  // Every OS where Foundation Models supports server-side language models.
  // Spelled as strings because the .v27 constants require tools-version 6.4.
  platforms: [
    .iOS("27.0"), .macOS("27.0"), .visionOS("27.0"), .watchOS("27.0"),
  ],
  products: [
    .library(name: "OpenRouterForFoundationModels", targets: ["OpenRouterForFoundationModels"])
  ],
  targets: [
    // Internal chat-completions API client. No FoundationModels dependency.
    .target(name: "OpenRouterAPI"),

    // FoundationModels ↔ OpenRouter chat completions bridge.
    .target(
      name: "OpenRouterForFoundationModels",
      dependencies: ["OpenRouterAPI"]
    ),

    // Runnable usage example (`swift run OpenRouterExample`). Deliberately not
    // a product — it exists to document the SDK, not to be depended on.
    .executableTarget(
      name: "OpenRouterExample",
      dependencies: ["OpenRouterForFoundationModels"],
      path: "Examples/OpenRouterExample"
    ),

    .testTarget(
      name: "OpenRouterAPITests",
      dependencies: ["OpenRouterAPI"]
    ),
    .testTarget(
      name: "OpenRouterForFoundationModelsTests",
      dependencies: ["OpenRouterForFoundationModels"]
    ),
  ]
)
