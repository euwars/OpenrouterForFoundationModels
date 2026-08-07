// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenRouterForFoundationModels

// MARK: - Structured output types

/// The example's deliverable: guided generation into a nested `@Generable`
/// graph — an enum, a nested struct with `@Guide` constraints, and an array
/// of nested values. The model cannot return anything that doesn't decode
/// into this type.
@Generable(description: "A complete trip plan")
struct TripPlan {
  @Guide(description: "Destination city and country")
  var destination: String

  @Guide(description: "Trip length in days", .range(1...14))
  var days: Int

  @Guide(description: "The best season to take this trip")
  var season: Season

  @Guide(description: "Must-see sights and activities", .count(3))
  var highlights: [Highlight]

  @Guide(description: "Rough cost expectations for one traveler")
  var budget: Budget
}

@Generable(description: "A season of the year")
enum Season {
  case spring
  case summer
  case autumn
  case winter
}

@Generable(description: "One sight or activity worth the trip")
struct Highlight {
  @Guide(description: "Name of the sight or activity")
  var name: String

  @Guide(description: "One sentence on why it's worth it")
  var reason: String
}

@Generable(description: "Cost expectations for one traveler")
struct Budget {
  @Guide(description: "Estimated total in US dollars", .range(100...20000))
  var totalUSD: Int

  @Guide(description: "Overall cost level of the trip")
  var level: CostLevel
}

@Generable(description: "How expensive the trip is overall")
enum CostLevel {
  case shoestring
  case moderate
  case luxury
}

// MARK: - Example

/// Runs one guided-generation turn against an OpenRouter model through
/// `LanguageModelSession` and prints the decoded ``TripPlan``, with token
/// usage on a trailing line.
///
///     OPENROUTER_API_KEY=<key> swift run OpenRouterExample "a long weekend in Kyoto"
///
/// Pass `--model <id>` to pick any OpenRouter model, and `--reasoning <level>`
/// (`low`/`medium`/`high`/`xhigh`/…) to pin a reasoning effort:
///
///     OPENROUTER_API_KEY=<key> swift run OpenRouterExample \
///       --model anthropic/claude-sonnet-4.5 --reasoning high "two weeks in Patagonia"
@main
struct OpenRouterExample {
  static func main() async {
    guard
      let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"],
      !key.isEmpty
    else {
      fail("Set OPENROUTER_API_KEY to run this example.")
    }

    var arguments = Array(CommandLine.arguments.dropFirst())
    func flagValue(_ flag: String) -> String? {
      guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count
      else { return nil }
      let value = arguments[index + 1]
      arguments.removeSubrange(index...(index + 1))
      return value
    }

    let modelID = flagValue("--model") ?? "openai/gpt-5.6-luna"
    let reasoning = flagValue("--reasoning").flatMap(ReasoningPolicy.Effort.init(rawValue:))
    let searchEnabled = arguments.contains("--search")
    arguments.removeAll { $0 == "--search" }
    let wish =
      arguments.isEmpty
      ? "a 4-day trip to Buenos Aires"
      : arguments.joined(separator: " ")

    let model = OpenRouterLanguageModel(
      name: OpenRouterModel(id: modelID),
      auth: .apiKey(key),
      reasoning: reasoning.map { .effort($0) },
      serverTools: searchEnabled ? [.webSearch(maxResults: 3)] : [],
      attribution: Attribution(appName: "OpenRouterExample")
    )

    let session = LanguageModelSession(
      model: model,
      instructions: "You are a pragmatic travel planner."
    )

    // With --search, run a plain grounded turn and print the citations the
    // server-side web search attached; without it, demo guided generation.
    if searchEnabled {
      await runSearchTurn(session: session, prompt: wish, modelID: modelID)
      return
    }

    do {
      let response = try await session.respond(
        to: "Plan \(wish).",
        generating: TripPlan.self
      )
      print(rendered(response.content))

      let usage = session.usage
      print(
        "\n— \(usage.input.totalTokenCount) tokens in"
          + " (\(usage.input.cachedTokenCount) cached),"
          + " \(usage.output.totalTokenCount) out"
          + " (\(usage.output.reasoningTokenCount) reasoning)"
      )
    } catch let error as OpenRouterError {
      // Provider errors with no LanguageModelError equivalent surface as
      // OpenRouterError — pattern-match the ones your product recovers from.
      switch error {
      case .missingCredential, .invalidCredential:
        fail("No usable OpenRouter credential. Check OPENROUTER_API_KEY.")
      case .insufficientCredits:
        fail("Out of OpenRouter credits.")
      case .noProviderAvailable:
        fail(
          "No provider for \(modelID) supports structured output. "
            + "Try another model, e.g. --model openai/gpt-5-mini."
        )
      default:
        fail(error.localizedDescription)
      }
    } catch let error as LanguageModelError {
      switch error {
      case .rateLimited:
        fail("Rate limited. Try again later.")
      case .contextSizeExceeded:
        fail("The conversation no longer fits the model's context window.")
      default:
        fail(error.localizedDescription)
      }
    } catch {
      // Transport errors and anything else.
      fail("\(error)")
    }
  }

  static func runSearchTurn(
    session: LanguageModelSession,
    prompt: String,
    modelID: String
  ) async {
    do {
      var printed = ""
      for try await snapshot in session.streamResponse(to: prompt) {
        print(snapshot.content.dropFirst(printed.count), terminator: "")
        #if canImport(Darwin)
        fflush(stdout)
        #endif
        printed = snapshot.content
      }
      print()

      let citations = session.transcript
        .flatMap { entry -> [Transcript.Segment] in
          if case .response(let response) = entry { return response.segments }
          return []
        }
        .compactMap { segment -> OpenRouterCitationSegment? in
          if case .custom(let custom) = segment {
            return custom as? OpenRouterCitationSegment
          }
          return nil
        }
      if !citations.isEmpty {
        print("\nSources:")
        for citation in citations {
          print("  • \(citation.content.title ?? citation.content.url) — \(citation.content.url)")
        }
      }

      let usage = session.usage
      print(
        "\n— \(usage.input.totalTokenCount) tokens in, \(usage.output.totalTokenCount) out"
      )
    } catch {
      fail("\(error)")
    }
  }

  static func rendered(_ plan: TripPlan) -> String {
    var lines = [
      "✈️  \(plan.destination) — \(plan.days) day\(plan.days == 1 ? "" : "s"), best in \(plan.season)",
      "",
      "Highlights:",
    ]
    for highlight in plan.highlights {
      lines.append("  • \(highlight.name): \(highlight.reason)")
    }
    lines.append("")
    lines.append("Budget: ~$\(plan.budget.totalUSD) (\(plan.budget.level))")
    return lines.joined(separator: "\n")
  }
}

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}
