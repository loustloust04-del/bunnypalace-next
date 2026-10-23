import { describe, expect, test } from "bun:test"
import {
  normalizeAgoraHandle,
  parseExplicitMentionHandles,
  validateExplicitMentionHandles,
} from "./agora-mentions.ts"
import { AgoraStoreError, type AgoraErrorCode } from "./agora-types.ts"

function expectCode(action: () => void, code: AgoraErrorCode): void {
  try {
    action()
    throw new Error(`Expected ${code}`)
  } catch (error) {
    expect(error).toBeInstanceOf(AgoraStoreError)
    expect((error as AgoraStoreError).code).toBe(code)
  }
}

describe("parseExplicitMentionHandles", () => {
  test("recognizes line-start and whitespace-delimited handles with trailing punctuation", () => {
    expect(parseExplicitMentionHandles("@Alice, please ask\n  @bob! Then\t@carol."))
      .toEqual(["alice", "bob", "carol."])
  })

  test("normalizes case and de-duplicates while preserving first-seen order", () => {
    expect(parseExplicitMentionHandles("@BOB @Alice @bob @ALICE @carol-2"))
      .toEqual(["bob", "alice", "carol-2"])
  })

  test("does not recognize email addresses, embedded at signs, or escaped mentions", () => {
    expect(parseExplicitMentionHandles("mail alice@example.com x@bob @@carol \\@dave but @eve"))
      .toEqual(["eve"])
  })

  test("ignores inline code spans including multi-backtick delimiters", () => {
    const content = "Ask `@alice` and ``code `\n@bob`` but notify @carol"
    expect(parseExplicitMentionHandles(content)).toEqual(["carol"])
  })

  test("ignores backtick and tilde fenced code blocks", () => {
    const content = [
      "@alice",
      "```ts",
      "@bob",
      "```",
      "~~~",
      "@carol",
      "~~~",
      "@dave",
    ].join("\n")
    expect(parseExplicitMentionHandles(content)).toEqual(["alice", "dave"])
  })

  test("does not parse a valid prefix from an overlong handle", () => {
    expect(parseExplicitMentionHandles(`@${"a".repeat(33)} @ok`)).toEqual(["ok"])
  })

  test("supports the complete ASCII handle grammar", () => {
    expect(normalizeAgoraHandle("A_1.B-C")).toBe("a_1.b-c")
    expectCode(() => normalizeAgoraHandle("_alice"), "invalid_handle")
    expectCode(() => normalizeAgoraHandle("álîce"), "invalid_handle")
  })
})

describe("validateExplicitMentionHandles", () => {
  test("rejects self mentions", () => {
    expectCode(
      () => validateExplicitMentionHandles(["Alice"], "alice", new Set(["alice", "bob"])),
      "self_mention_not_allowed",
    )
  })

  test("returns every unknown handle in source order", () => {
    try {
      validateExplicitMentionHandles(["alice", "missing", "other"], "susu", new Set(["alice"]))
      throw new Error("Expected unknown_handle")
    } catch (error) {
      expect(error).toBeInstanceOf(AgoraStoreError)
      const storeError = error as AgoraStoreError
      expect(storeError.code).toBe("unknown_handle")
      expect(storeError.details.unknown_handles).toEqual(["missing", "other"])
    }
  })

  test("rejects more than eight distinct targets", () => {
    const handles = Array.from({ length: 9 }, (_, index) => `a${index}`)
    expectCode(
      () => validateExplicitMentionHandles(handles, "susu", new Set(handles)),
      "mention_limit_exceeded",
    )
  })
})
