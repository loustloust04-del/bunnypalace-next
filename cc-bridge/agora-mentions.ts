import { AGORA_LIMITS, AgoraStoreError } from "./agora-types.ts"

const HANDLE_START = /[A-Za-z0-9]/
const HANDLE_CONTINUE = /[A-Za-z0-9_.-]/

function runLength(text: string, offset: number, character: string): number {
  let length = 0
  while (text[offset + length] === character) length += 1
  return length
}

function closingBacktickOffset(line: string, offset: number, delimiterLength: number): number {
  let cursor = offset
  while (cursor < line.length) {
    if (line[cursor] !== "`") {
      cursor += 1
      continue
    }
    const length = runLength(line, cursor, "`")
    if (length === delimiterLength) return cursor
    cursor += length
  }
  return -1
}

function maskFencedCode(content: string): string {
  const lines = content.split(/\r?\n/)
  let fenceCharacter = ""
  let fenceLength = 0
  return lines.map(line => {
    const fence = line.match(/^ {0,3}(`{3,}|~{3,})/)
    if (fenceCharacter) {
      if (
        fence
        && fence[1][0] === fenceCharacter
        && fence[1].length >= fenceLength
        && line.slice(fence[0].length).trim().length === 0
      ) {
        fenceCharacter = ""
        fenceLength = 0
      }
      return " ".repeat(line.length)
    }
    if (fence) {
      fenceCharacter = fence[1][0]
      fenceLength = fence[1].length
      return " ".repeat(line.length)
    }
    return line
  }).join("\n")
}

export function normalizeAgoraHandle(handle: string): string {
  const normalized = handle.toLowerCase()
  if (
    normalized.length < 1
    || normalized.length > AGORA_LIMITS.handleCharacters
    || !/^[a-z0-9][a-z0-9_.-]*$/.test(normalized)
  ) {
    throw new AgoraStoreError("invalid_handle", `Invalid Agora handle: ${handle}`, { handle })
  }
  return normalized
}

export function parseExplicitMentionHandles(content: string): string[] {
  const handles: string[] = []
  const seen = new Set<string>()
  const visibleContent = maskFencedCode(content)
  let cursor = 0
  while (cursor < visibleContent.length) {
    if (visibleContent[cursor] === "`") {
      const delimiterLength = runLength(visibleContent, cursor, "`")
      const closing = closingBacktickOffset(visibleContent, cursor + delimiterLength, delimiterLength)
      if (closing >= 0) {
        cursor = closing + delimiterLength
        continue
      }
      cursor += delimiterLength
      continue
    }

    if (visibleContent[cursor] !== "@" || (cursor > 0 && !/\s/.test(visibleContent[cursor - 1]))) {
      cursor += 1
      continue
    }
    const start = cursor + 1
    if (!HANDLE_START.test(visibleContent[start] ?? "")) {
      cursor += 1
      continue
    }
    let end = start + 1
    while (end < visibleContent.length && HANDLE_CONTINUE.test(visibleContent[end])) end += 1
    const raw = visibleContent.slice(start, end)
    if (raw.length <= AGORA_LIMITS.handleCharacters) {
      const normalized = raw.toLowerCase()
      if (!seen.has(normalized)) {
        seen.add(normalized)
        handles.push(normalized)
      }
    }
    cursor = end
  }

  return handles
}

export function validateExplicitMentionHandles(
  handles: readonly string[],
  selfHandle: string,
  enabledHandles: ReadonlySet<string>,
): string[] {
  const normalizedSelf = normalizeAgoraHandle(selfHandle)
  const normalizedEnabled = new Set(Array.from(enabledHandles, normalizeAgoraHandle))
  if (handles.length > AGORA_LIMITS.mentionsPerMessage) {
    throw new AgoraStoreError(
      "mention_limit_exceeded",
      `A message can target at most ${AGORA_LIMITS.mentionsPerMessage} members`,
      { limit: AGORA_LIMITS.mentionsPerMessage },
    )
  }
  const normalized = handles.map(normalizeAgoraHandle)
  if (normalized.includes(normalizedSelf)) {
    throw new AgoraStoreError("self_mention_not_allowed", `Cannot mention @${normalizedSelf}`)
  }
  const unknown = normalized.filter(handle => !normalizedEnabled.has(handle))
  if (unknown.length > 0) {
    throw new AgoraStoreError("unknown_handle", `Unknown Agora handle: @${unknown[0]}`, {
      unknown_handles: unknown,
    })
  }
  return normalized
}
