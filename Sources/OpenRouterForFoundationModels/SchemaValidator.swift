// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenRouterAPI

/// Structural validation of a model's structured-output text against the
/// request schema, run before an attempt is handed to the framework.
///
/// Providers vary in how strictly they enforce `json_schema`; some return
/// JSON missing required properties or with mistyped values. This checks
/// structure — parseability, required properties, types, enum membership —
/// and deliberately not `@Guide` bounds (`minItems`, `minimum`, …), which
/// the framework treats as guidance rather than decode requirements.
enum SchemaValidator {
  /// The first structural violation, or nil when the text conforms.
  static func firstViolation(in jsonText: String, against schema: JSONValue) -> String? {
    guard let value = JSONValue.parsed(jsonText) else {
      return "response is not valid JSON"
    }
    return violation(value, schema: schema, root: schema, path: "$")
  }

  private static func violation(
    _ value: JSONValue,
    schema: JSONValue,
    root: JSONValue,
    path: String
  ) -> String? {
    guard case .object(let s) = schema else { return nil }

    if case .string(let ref)? = s["$ref"] {
      guard let resolved = resolve(ref, in: root) else { return nil }
      return violation(value, schema: resolved, root: root, path: path)
    }

    if case .array(let variants)? = s["anyOf"] ?? s["oneOf"] {
      let matches = variants.contains {
        violation(value, schema: $0, root: root, path: path) == nil
      }
      return matches ? nil : "\(path) matches no schema variant"
    }

    if case .array(let allowed)? = s["enum"], !allowed.contains(value) {
      return "\(path) is not one of the allowed values"
    }

    if let typeSpec = s["type"], !matchesType(value, spec: typeSpec) {
      return "\(path) has the wrong type (expected \(typeSpec.jsonText))"
    }

    if case .object(let object) = value {
      if case .array(let required)? = s["required"] {
        for name in required.compactMap(\.stringValue) where object[name] == nil {
          return "\(path) is missing required property '\(name)'"
        }
      }
      if case .object(let properties)? = s["properties"] {
        for (name, propertySchema) in properties {
          guard let propertyValue = object[name] else { continue }
          if let failure = violation(
            propertyValue, schema: propertySchema, root: root, path: "\(path).\(name)"
          ) {
            return failure
          }
        }
      }
    }

    if case .array(let items) = value, let itemSchema = s["items"] {
      for (index, item) in items.enumerated() {
        if let failure = violation(
          item, schema: itemSchema, root: root, path: "\(path)[\(index)]"
        ) {
          return failure
        }
      }
    }

    return nil
  }

  /// `#/$defs/Name` or `#/definitions/Name` → the referenced schema.
  private static func resolve(_ ref: String, in root: JSONValue) -> JSONValue? {
    let parts = ref.split(separator: "/").map(String.init)
    guard parts.first == "#", parts.count == 3 else { return nil }
    return root[parts[1]]?[parts[2]]
  }

  private static func matchesType(_ value: JSONValue, spec: JSONValue) -> Bool {
    switch spec {
    case .string(let type):
      return matchesType(value, type: type)
    case .array(let types):
      return types.compactMap(\.stringValue).contains { matchesType(value, type: $0) }
    default:
      return true
    }
  }

  private static func matchesType(_ value: JSONValue, type: String) -> Bool {
    switch (type, value) {
    case ("object", .object), ("array", .array), ("string", .string),
      ("boolean", .bool), ("number", .number), ("null", .null):
      true
    case ("integer", .number(let n)):
      n == n.rounded()
    default:
      false
    }
  }
}
