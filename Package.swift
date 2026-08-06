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
  traits: [
    // Compile the bridge against ServerFoundationModels — the open-source,
    // runs-anywhere reimplementation of the FoundationModels surface —
    // instead of Apple's framework. Off by default: Apple platforms link
    // the system framework exactly as before. Enable from a consumer with
    //   .package(url: …, traits: ["ServerFoundationModels"])
    .trait(
      name: "ServerFoundationModels",
      description: "Use euwars/ServerFoundationModels instead of Apple's FoundationModels."
    )
  ],
  dependencies: [
    .package(
      url: "https://github.com/euwars/ServerFoundationModels.git",
      from: "0.6.0"
    )
  ],
  targets: [
    // Internal chat-completions API client. No FoundationModels dependency.
    .target(name: "OpenRouterAPI"),

    // FoundationModels ↔ OpenRouter chat completions bridge.
    .target(
      name: "OpenRouterForFoundationModels",
      dependencies: [
        "OpenRouterAPI",
        .product(
          name: "ServerFoundationModels",
          package: "ServerFoundationModels",
          condition: .when(traits: ["ServerFoundationModels"])
        ),
      ]
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
