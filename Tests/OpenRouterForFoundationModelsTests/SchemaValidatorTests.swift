// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import OpenRouterForFoundationModels
@testable import OpenRouterAPI

@Suite struct SchemaValidatorTests {
  static let schema: JSONValue = [
    "type": "object",
    "required": ["name", "days", "kind"],
    "properties": [
      "name": ["type": "string"],
      "days": ["type": "integer"],
      "kind": ["type": "string", "enum": ["a", "b"]],
      "nickname": ["type": ["string", "null"]],
      "inner": ["$ref": "#/$defs/Inner"],
      "tags": ["type": "array", "items": ["type": "string"]],
    ],
    "$defs": [
      "Inner": [
        "type": "object",
        "required": ["value"],
        "properties": ["value": ["type": "string"]],
      ]
    ],
  ]

  private func violation(_ json: String) -> String? {
    SchemaValidator.firstViolation(in: json, against: Self.schema)
  }

  @Test func `conforming JSON passes`() {
    #expect(violation(#"{"name":"x","days":3,"kind":"a"}"#) == nil)
  }

  @Test func `invalid JSON is reported`() {
    #expect(violation(#"{"name": "x", "#) != nil)
  }

  @Test func `missing required property is reported`() {
    let failure = violation(#"{"name":"x","days":3}"#)
    #expect(failure?.contains("kind") == true)
  }

  @Test func `wrong type is reported`() {
    let failure = violation(#"{"name":"x","days":"three","kind":"a"}"#)
    #expect(failure?.contains("days") == true)
  }

  @Test func `non-integer number is reported for integer type`() {
    #expect(violation(#"{"name":"x","days":3.5,"kind":"a"}"#) != nil)
  }

  @Test func `enum mismatch is reported`() {
    let failure = violation(#"{"name":"x","days":3,"kind":"z"}"#)
    #expect(failure?.contains("kind") == true)
  }

  @Test func `null is accepted for nullable types`() {
    #expect(violation(#"{"name":"x","days":3,"kind":"a","nickname":null}"#) == nil)
  }

  @Test func `references resolve through $defs`() {
    #expect(violation(#"{"name":"x","days":3,"kind":"a","inner":{"value":"v"}}"#) == nil)
    let failure = violation(#"{"name":"x","days":3,"kind":"a","inner":{}}"#)
    #expect(failure?.contains("value") == true)
  }

  @Test func `array items are validated`() {
    let failure = violation(#"{"name":"x","days":3,"kind":"a","tags":["ok",5]}"#)
    #expect(failure?.contains("tags[1]") == true)
  }

  @Test func `guide bounds are deliberately not enforced`() {
    // minItems/minimum are guidance; the framework decodes regardless.
    let bounded: JSONValue = [
      "type": "object",
      "required": ["tags"],
      "properties": [
        "tags": ["type": "array", "items": ["type": "string"], "minItems": 3]
      ],
    ]
    #expect(SchemaValidator.firstViolation(in: #"{"tags":["one"]}"#, against: bounded) == nil)
  }
}
