import { expect, test } from "bun:test"
import { agoraMentionPushContent } from "./hub.ts"

test("Agora owner mention push always names the room and mentioning actor", () => {
  const push = agoraMentionPushContent({
    roomId: "0a79ecdb-779c-4aa0-ae09-fb160012bd3c",
    roomTitle: "方案评审",
    senderHandle: "alice",
    senderDisplayName: "Alice",
    content: "请看一下   这个方案\n尤其是第二节",
  })

  expect(push).toEqual({
    title: "中庭 · 方案评审",
    fullBody: "Alice (@alice)：请看一下 这个方案 尤其是第二节",
    hiddenBody: "Alice 在中庭提到了你",
    contextId: "0a79ecdb-779c-4aa0-ae09-fb160012bd3c",
    metadata: { agora_room_id: "0a79ecdb-779c-4aa0-ae09-fb160012bd3c" },
  })
})
