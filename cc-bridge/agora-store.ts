import { Database } from "bun:sqlite"
import { createHash, randomBytes, randomUUID } from "node:crypto"
import { timedSyncFs, timeSqlite } from "./block-ledger"
const { mkdirSync } = timedSyncFs("agora ")
import { dirname, join } from "node:path"
import { normalizeAgoraHandle, parseExplicitMentionHandles } from "./agora-mentions.ts"
import {
  AGORA_DATABASE_FILENAME,
  AGORA_LIMITS,
  AGORA_OWNER_EXTERNAL_KEY,
  AGORA_SPEECH_MODES,
  AgoraStoreError,
  type AgoraActor,
  type AgoraActorKind,
  type AgoraBridge,
  type AgoraBridgeStartInput,
  type AgoraBridgeStartResult,
  type AgoraBridgeState,
  type AgoraBridgeStopResult,
  type AgoraBridgeTurn,
  type AgoraClaimResult,
  type AgoraCreateRoomInput,
  type AgoraMention,
  type AgoraMentionDispatch,
  type AgoraMentionKind,
  type AgoraMentionState,
  type AgoraMembership,
  type AgoraMessage,
  type AgoraMessageEdit,
  type AgoraMessageDeleteResult,
  type AgoraMessageWriteResult,
  type AgoraRoom,
  type AgoraPassResult,
  type AgoraRoomCreateResult,
  type AgoraRoomMemberSpec,
  type AgoraRoomOpenResult,
  type AgoraRoomSnapshot,
  type AgoraSpeechMode,
} from "./agora-types.ts"

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const SESSION_NAME_PATTERN = /^[A-Za-z0-9_.-]{1,32}$/

const ACTOR_COLUMNS = `
  id,
  kind,
  external_key AS externalKey,
  created_at_ms AS createdAtMs,
  disabled_at_ms AS disabledAtMs
`

const ROOM_COLUMNS = `
  id,
  floor_id AS floorId,
  title,
  owner_actor_id AS ownerActorId,
  client_request_id AS clientRequestId,
  is_dm AS isDM,
  dm_peer_actor_id AS dmPeerActorId,
  next_seq AS nextSeq,
  is_enabled AS isEnabled,
  created_at_ms AS createdAtMs,
  updated_at_ms AS updatedAtMs
`

const MEMBERSHIP_COLUMNS = `
  id,
  room_id AS roomId,
  actor_id AS actorId,
  handle,
  display_name AS displayName,
  avatar_ref AS avatarRef,
  role,
  executor_kind AS executorKind,
  executor_config_json AS executorConfigJson,
  is_enabled AS isEnabled,
  joined_at_ms AS joinedAtMs
`

const MESSAGE_COLUMNS = `
  id,
  room_id AS roomId,
  seq,
  actor_id AS actorId,
  client_message_id AS clientMessageId,
  content,
  created_at_ms AS createdAtMs,
  edited_at_ms AS editedAtMs,
  is_deleted AS isDeleted,
  deleted_at_ms AS deletedAtMs
`

const MENTION_COLUMNS = `
  id,
  room_id AS roomId,
  source_message_id AS sourceMessageId,
  target_membership_id AS targetMembershipId,
  state,
  kind,
  depth,
  claimed_at_ms AS claimedAtMs,
  lease_expires_at_ms AS leaseExpiresAtMs,
  completed_at_ms AS completedAtMs,
  result_message_id AS resultMessageId,
  attempt_count AS attemptCount,
  last_error AS lastError,
  created_at_ms AS createdAtMs
`

const BRIDGE_COLUMNS = `
  id,
  room_id AS roomId,
  owner_actor_id AS ownerActorId,
  client_request_id AS clientRequestId,
  first_actor_id AS firstActorId,
  second_actor_id AS secondActorId,
  prompt,
  status,
  max_turns AS maxTurns,
  turns_completed AS turnsCompleted,
  stop_reason AS stopReason,
  last_error AS lastError,
  created_at_ms AS createdAtMs,
  updated_at_ms AS updatedAtMs,
  completed_at_ms AS completedAtMs
`

const BRIDGE_TURN_COLUMNS = `
  id,
  bridge_id AS bridgeId,
  turn_index AS turnIndex,
  source_message_id AS sourceMessageId,
  mention_id AS mentionId,
  expected_actor_id AS expectedActorId,
  reply_message_id AS replyMessageId,
  state,
  error,
  created_at_ms AS createdAtMs,
  claimed_at_ms AS claimedAtMs,
  completed_at_ms AS completedAtMs
`

interface ActorRow extends AgoraActor {}
interface RoomRow extends Omit<AgoraRoom, "isEnabled" | "isDM"> { isEnabled: number; isDM: number }
interface MembershipRow extends Omit<AgoraMembership, "isEnabled"> { isEnabled: number }
interface MessageRow extends Omit<AgoraMessage, "isDeleted"> { isDeleted: number }
interface MessageEditRow extends AgoraMessageEdit {}
interface MentionRow extends AgoraMention {}
interface BridgeRow extends AgoraBridge {}
interface BridgeTurnRow extends AgoraBridgeTurn {}
interface CountRow { count: number }
interface SequenceRow { seq: number }
interface VersionRow { version: number }
interface StateCountRow { state: AgoraMentionState; count: number }
interface HashRow { claimTokenHash: string | null }
interface PragmaRow { value: string | number }
interface ForeignKeyViolationRow { table: string; rowid: number; parent: string; fkid: number }

export interface AgoraStoreOpenOptions {
  secretsDir?: string
  databasePath?: string
  clock?: () => number
}

export interface AgoraDatabaseHealth {
  foreignKeys: boolean
  journalMode: string
  synchronous: number
  busyTimeoutMs: number
  migrationVersions: number[]
  foreignKeyViolations: ForeignKeyViolationRow[]
}

function actorFromRow(row: ActorRow): AgoraActor {
  return row
}

function roomFromRow(row: RoomRow): AgoraRoom {
  return { ...row, isDM: row.isDM === 1, isEnabled: row.isEnabled === 1 }
}

function membershipFromRow(row: MembershipRow): AgoraMembership {
  return { ...row, isEnabled: row.isEnabled === 1 }
}

function messageFromRow(row: MessageRow): AgoraMessage {
  return { ...row, isDeleted: row.isDeleted === 1 }
}

function mentionFromRow(row: MentionRow): AgoraMention {
  return row
}

function bridgeFromRow(row: BridgeRow): AgoraBridge {
  return row
}

function bridgeTurnFromRow(row: BridgeTurnRow): AgoraBridgeTurn {
  return row
}

function characterCount(value: string): number {
  return Array.from(value).length
}

function requireUuid(value: string): string {
  if (!UUID_PATTERN.test(value)) {
    throw new AgoraStoreError("invalid_id", `Expected UUID identifier: ${value}`)
  }
  return value
}

function requireFloorId(value: string): string {
  const trimmed = value.trim()
  if (!UUID_PATTERN.test(trimmed)) {
    throw new AgoraStoreError("invalid_floor_id", `floor_id must be a UUID: ${value}`)
  }
  return trimmed
}

function requireTitle(value: string): string {
  const trimmed = value.trim()
  const length = characterCount(trimmed)
  if (length < 1 || length > AGORA_LIMITS.titleCharacters) {
    throw new AgoraStoreError("invalid_title", `Room title must be 1...${AGORA_LIMITS.titleCharacters} characters`)
  }
  return trimmed
}

function requireDisplayName(value: string): string {
  const trimmed = value.trim()
  const length = characterCount(trimmed)
  if (length < 1 || length > AGORA_LIMITS.displayNameCharacters) {
    throw new AgoraStoreError(
      "invalid_display_name",
      `Display name must be 1...${AGORA_LIMITS.displayNameCharacters} characters`,
    )
  }
  return trimmed
}

function requireMessageContent(value: string): string {
  const trimmed = value.trim()
  const length = characterCount(trimmed)
  if (length < 1 || length > AGORA_LIMITS.messageCharacters) {
    throw new AgoraStoreError(
      "invalid_message",
      `Message must be 1...${AGORA_LIMITS.messageCharacters} characters after trimming`,
    )
  }
  return trimmed
}

function requirePageLimit(limit: number): number {
  if (!Number.isInteger(limit) || limit < 1 || limit > AGORA_LIMITS.messagePageSize) {
    throw new AgoraStoreError("invalid_limit", `Page limit must be 1...${AGORA_LIMITS.messagePageSize}`)
  }
  return limit
}

function requireSessionName(sessionName: string): string {
  if (!SESSION_NAME_PATTERN.test(sessionName)) {
    throw new AgoraStoreError("invalid_session_name", `Invalid CC session name: ${sessionName}`)
  }
  return sessionName
}

function hashClaimToken(token: string): string {
  return createHash("sha256").update(token).digest("hex")
}

function conciseError(error: string): string {
  return error.trim().replace(/\s+/g, " ").slice(0, 500) || "executor delivery failed"
}

function isUniqueConstraint(error: Error, columns: string): boolean {
  return error.message.includes("UNIQUE constraint failed") && error.message.includes(columns)
}

export class AgoraStore {
  private readonly messageRateTimestamps = new Map<string, number[]>()
  private readonly roomRateTimestamps = new Map<string, number[]>()

  readonly databasePath: string

  private constructor(
    private readonly database: Database,
    databasePath: string,
    private readonly clock: () => number,
  ) {
    this.databasePath = databasePath
  }

  static open(options: AgoraStoreOpenOptions = {}): AgoraStore {
    const secretsDir = options.secretsDir ?? process.env.MP_CC_SECRETS_DIR ?? join(import.meta.dir, "secrets")
    const databasePath = options.databasePath ?? join(secretsDir, AGORA_DATABASE_FILENAME)
    mkdirSync(databasePath === ":memory:" ? secretsDir : dirname(databasePath), { recursive: true })
    const database = timeSqlite(new Database(databasePath, { create: true, strict: true }), "agora")
    const store = new AgoraStore(database, databasePath, options.clock ?? Date.now)
    try {
      database.exec("PRAGMA foreign_keys=ON")
      database.exec("PRAGMA journal_mode=WAL")
      database.exec("PRAGMA synchronous=NORMAL")
      database.exec("PRAGMA busy_timeout=5000")
      store.migrate()
      return store
    } catch (error) {
      database.close()
      throw error
    }
  }

  close(): void {
    this.database.close()
  }

  health(): AgoraDatabaseHealth {
    const pragma = (name: string): string | number => {
      const row = this.database.query<PragmaRow, []>(`PRAGMA ${name}`).get()
      if (!row) throw new Error(`Missing PRAGMA ${name} result`)
      return Object.values(row)[0]
    }
    return {
      foreignKeys: Number(pragma("foreign_keys")) === 1,
      journalMode: String(pragma("journal_mode")).toLowerCase(),
      synchronous: Number(pragma("synchronous")),
      busyTimeoutMs: Number(pragma("busy_timeout")),
      migrationVersions: this.database
        .query<VersionRow, []>("SELECT version FROM agora_schema_migrations ORDER BY version")
        .all()
        .map(row => row.version),
      foreignKeyViolations: this.database
        .query<ForeignKeyViolationRow, []>("PRAGMA foreign_key_check")
        .all(),
    }
  }

  private migrate(): void {
    this.transaction(() => {
      this.database.exec(`
        CREATE TABLE IF NOT EXISTS agora_schema_migrations (
          version       INTEGER PRIMARY KEY,
          applied_at_ms INTEGER NOT NULL
        )
      `)
      const latest = this.database
        .query<VersionRow, []>("SELECT version FROM agora_schema_migrations ORDER BY version DESC LIMIT 1")
        .get()?.version ?? 0
      if (latest > 6) {
        throw new AgoraStoreError(
          "migration_version_unsupported",
          `agora.sqlite schema version ${latest} is newer than supported version 6`,
        )
      }
      if (latest < 1) {
        this.database.exec(`
        CREATE TABLE agora_actors (
          id             TEXT PRIMARY KEY,
          kind           TEXT NOT NULL CHECK (kind IN ('owner', 'cc_bridge')),
          external_key   TEXT NOT NULL UNIQUE,
          created_at_ms  INTEGER NOT NULL,
          disabled_at_ms INTEGER
        );

        CREATE TABLE agora_rooms (
          id                TEXT PRIMARY KEY,
          floor_id          TEXT NOT NULL,
          title             TEXT NOT NULL,
          owner_actor_id    TEXT NOT NULL REFERENCES agora_actors(id),
          client_request_id TEXT NOT NULL,
          next_seq          INTEGER NOT NULL DEFAULT 1 CHECK (next_seq >= 1),
          is_enabled        INTEGER NOT NULL DEFAULT 1 CHECK (is_enabled IN (0, 1)),
          created_at_ms     INTEGER NOT NULL,
          updated_at_ms     INTEGER NOT NULL,
          UNIQUE (owner_actor_id, client_request_id)
        );

        CREATE INDEX agora_rooms_floor_updated
          ON agora_rooms(floor_id, updated_at_ms DESC);

        CREATE TABLE agora_memberships (
          id                   TEXT PRIMARY KEY,
          room_id              TEXT NOT NULL REFERENCES agora_rooms(id) ON DELETE CASCADE,
          actor_id             TEXT NOT NULL REFERENCES agora_actors(id),
          handle               TEXT NOT NULL COLLATE NOCASE,
          display_name         TEXT NOT NULL,
          avatar_ref           TEXT,
          role                 TEXT NOT NULL CHECK (role IN ('owner', 'member')),
          executor_kind        TEXT NOT NULL CHECK (executor_kind IN ('none', 'cc_bridge')),
          executor_config_json TEXT NOT NULL DEFAULT '{}',
          is_enabled           INTEGER NOT NULL DEFAULT 1 CHECK (is_enabled IN (0, 1)),
          joined_at_ms         INTEGER NOT NULL,
          UNIQUE (room_id, actor_id),
          UNIQUE (room_id, handle)
        );

        CREATE INDEX agora_memberships_actor
          ON agora_memberships(actor_id, room_id);

        CREATE TABLE agora_messages (
          id                TEXT PRIMARY KEY,
          room_id           TEXT NOT NULL REFERENCES agora_rooms(id) ON DELETE CASCADE,
          seq               INTEGER NOT NULL CHECK (seq >= 1),
          actor_id          TEXT NOT NULL REFERENCES agora_actors(id),
          client_message_id TEXT NOT NULL,
          content           TEXT NOT NULL,
          created_at_ms     INTEGER NOT NULL,
          UNIQUE (room_id, seq),
          UNIQUE (room_id, actor_id, client_message_id)
        );

        CREATE INDEX agora_messages_room_seq
          ON agora_messages(room_id, seq);

        CREATE TABLE agora_mentions (
          id                   TEXT PRIMARY KEY,
          room_id              TEXT NOT NULL REFERENCES agora_rooms(id) ON DELETE CASCADE,
          source_message_id    TEXT NOT NULL REFERENCES agora_messages(id) ON DELETE CASCADE,
          target_membership_id TEXT NOT NULL REFERENCES agora_memberships(id),
          state                TEXT NOT NULL CHECK (state IN ('pending', 'claimed', 'completed', 'failed')),
          claim_token_hash     TEXT,
          claimed_at_ms        INTEGER,
          lease_expires_at_ms  INTEGER,
          completed_at_ms      INTEGER,
          result_message_id    TEXT REFERENCES agora_messages(id),
          attempt_count        INTEGER NOT NULL DEFAULT 0,
          last_error           TEXT,
          created_at_ms        INTEGER NOT NULL,
          UNIQUE (source_message_id, target_membership_id)
        );

        CREATE INDEX agora_mentions_dispatch
          ON agora_mentions(state, target_membership_id, created_at_ms);

        CREATE INDEX agora_mentions_room_state
          ON agora_mentions(room_id, state, created_at_ms DESC);
        `)
        this.database.run(
          "INSERT INTO agora_schema_migrations(version, applied_at_ms) VALUES (1, ?)",
          [this.clock()],
        )
      }
      if (latest < 2) {
        this.database.exec(`
          ALTER TABLE agora_messages ADD COLUMN edited_at_ms INTEGER;

          CREATE TABLE agora_message_edits (
            id                TEXT PRIMARY KEY,
            message_id        TEXT NOT NULL REFERENCES agora_messages(id) ON DELETE CASCADE,
            editor_actor_id   TEXT NOT NULL REFERENCES agora_actors(id),
            previous_content  TEXT NOT NULL,
            edited_at_ms      INTEGER NOT NULL
          );

          CREATE INDEX agora_message_edits_message_time
            ON agora_message_edits(message_id, edited_at_ms, id);
        `)
        this.database.run(
          "INSERT INTO agora_schema_migrations(version, applied_at_ms) VALUES (2, ?)",
          [this.clock()],
        )
      }
      if (latest < 3) {
        this.database.exec(`
          ALTER TABLE agora_messages ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0
            CHECK (is_deleted IN (0, 1));
          ALTER TABLE agora_messages ADD COLUMN deleted_at_ms INTEGER;
        `)
        this.database.run(
          "INSERT INTO agora_schema_migrations(version, applied_at_ms) VALUES (3, ?)",
          [this.clock()],
        )
      }
      if (latest < 4) {
        this.database.exec(`
          CREATE TABLE agora_bridges (
            id                TEXT PRIMARY KEY,
            room_id           TEXT NOT NULL REFERENCES agora_rooms(id) ON DELETE CASCADE,
            owner_actor_id    TEXT NOT NULL REFERENCES agora_actors(id),
            client_request_id TEXT NOT NULL,
            first_actor_id    TEXT NOT NULL REFERENCES agora_actors(id),
            second_actor_id   TEXT NOT NULL REFERENCES agora_actors(id),
            prompt            TEXT NOT NULL,
            status            TEXT NOT NULL CHECK (status IN ('active', 'completed', 'stopped', 'failed')),
            max_turns         INTEGER NOT NULL CHECK (max_turns >= 1),
            turns_completed   INTEGER NOT NULL DEFAULT 0 CHECK (turns_completed >= 0),
            stop_reason       TEXT,
            last_error        TEXT,
            created_at_ms     INTEGER NOT NULL,
            updated_at_ms     INTEGER NOT NULL,
            completed_at_ms   INTEGER,
            UNIQUE (owner_actor_id, client_request_id)
          );

          CREATE UNIQUE INDEX agora_bridges_one_active_per_room
            ON agora_bridges(room_id) WHERE status = 'active';
          CREATE INDEX agora_bridges_room_updated
            ON agora_bridges(room_id, updated_at_ms DESC);

          CREATE TABLE agora_bridge_turns (
            id                 TEXT PRIMARY KEY,
            bridge_id          TEXT NOT NULL REFERENCES agora_bridges(id) ON DELETE CASCADE,
            turn_index         INTEGER NOT NULL CHECK (turn_index >= 0),
            source_message_id  TEXT NOT NULL REFERENCES agora_messages(id),
            mention_id         TEXT NOT NULL UNIQUE REFERENCES agora_mentions(id),
            expected_actor_id  TEXT NOT NULL REFERENCES agora_actors(id),
            reply_message_id   TEXT REFERENCES agora_messages(id),
            state              TEXT NOT NULL CHECK (state IN ('pending', 'claimed', 'completed', 'cancelled', 'failed')),
            error              TEXT,
            created_at_ms      INTEGER NOT NULL,
            claimed_at_ms      INTEGER,
            completed_at_ms    INTEGER,
            UNIQUE (bridge_id, turn_index)
          );

          CREATE INDEX agora_bridge_turns_bridge_state
            ON agora_bridge_turns(bridge_id, state, turn_index);
        `)
        this.database.run(
          "INSERT INTO agora_schema_migrations(version, applied_at_ms) VALUES (4, ?)",
          [this.clock()],
        )
      }
      if (latest < 5) {
        this.database.exec(`
          ALTER TABLE agora_rooms ADD COLUMN is_dm INTEGER NOT NULL DEFAULT 0
            CHECK (is_dm IN (0, 1));
          ALTER TABLE agora_rooms ADD COLUMN dm_peer_actor_id TEXT REFERENCES agora_actors(id);

          CREATE UNIQUE INDEX agora_rooms_unique_dm
            ON agora_rooms(floor_id, owner_actor_id, dm_peer_actor_id)
            WHERE is_dm = 1;
        `)
        this.database.run(
          "INSERT INTO agora_schema_migrations(version, applied_at_ms) VALUES (5, ?)",
          [this.clock()],
        )
      }
      if (latest < 6) {
        this.database.exec(`
          ALTER TABLE agora_mentions ADD COLUMN kind TEXT NOT NULL DEFAULT 'direct'
            CHECK (kind IN ('direct', 'observe'));
          ALTER TABLE agora_mentions ADD COLUMN depth INTEGER NOT NULL DEFAULT 0
            CHECK (depth >= 0);

          CREATE TABLE agora_settings (
            key           TEXT PRIMARY KEY,
            value         TEXT NOT NULL,
            updated_at_ms INTEGER NOT NULL
          );
        `)
        this.database.run(
          "INSERT INTO agora_schema_migrations(version, applied_at_ms) VALUES (6, ?)",
          [this.clock()],
        )
      }
    })
  }

  private transaction<T>(work: () => T): T {
    this.database.exec("BEGIN IMMEDIATE")
    try {
      const result = work()
      this.database.exec("COMMIT")
      return result
    } catch (error) {
      try { this.database.exec("ROLLBACK") } catch {}
      throw error
    }
  }

  private enforceMessageRateLimit(actorId: string, now: number): void {
    const recent = (this.messageRateTimestamps.get(actorId) ?? [])
      .filter(timestamp => timestamp > now - AGORA_LIMITS.messageRateWindowMs)
    this.messageRateTimestamps.set(actorId, recent)
    if (recent.length < AGORA_LIMITS.messagePostsPerMinute) return
    const retryAfterMs = Math.max(1, recent[0] + AGORA_LIMITS.messageRateWindowMs - now)
    throw new AgoraStoreError(
      "rate_limit_exceeded",
      `Actor may post at most ${AGORA_LIMITS.messagePostsPerMinute} messages per minute`,
      { limit: AGORA_LIMITS.messagePostsPerMinute, retry_after_ms: retryAfterMs },
    )
  }

  private enforceRoomRateLimit(actorId: string, now: number): void {
    const recent = (this.roomRateTimestamps.get(actorId) ?? [])
      .filter(timestamp => timestamp > now - AGORA_LIMITS.roomRateWindowMs)
    this.roomRateTimestamps.set(actorId, recent)
    if (recent.length < AGORA_LIMITS.roomCreationsPerHour) return
    const retryAfterMs = Math.max(1, recent[0] + AGORA_LIMITS.roomRateWindowMs - now)
    throw new AgoraStoreError(
      "rate_limit_exceeded",
      `Actor may create at most ${AGORA_LIMITS.roomCreationsPerHour} rooms per hour`,
      { limit: AGORA_LIMITS.roomCreationsPerHour, retry_after_ms: retryAfterMs },
    )
  }

  getSpeechMode(): AgoraSpeechMode {
    const row = this.database.query<{ value: string }, []>(
      "SELECT value FROM agora_settings WHERE key = 'speech_mode'",
    ).get()
    const stored = row?.value as AgoraSpeechMode | undefined
    return stored && AGORA_SPEECH_MODES.includes(stored) ? stored : "mention_only"
  }

  setSpeechMode(mode: AgoraSpeechMode): AgoraSpeechMode {
    if (!AGORA_SPEECH_MODES.includes(mode)) {
      throw new AgoraStoreError("invalid_speech_mode", `Unknown Agora speech mode: ${mode}`)
    }
    this.database.run(
      `INSERT INTO agora_settings(key, value, updated_at_ms) VALUES ('speech_mode', ?, ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at_ms = excluded.updated_at_ms`,
      [mode, this.clock()],
    )
    return mode
  }

  /// 房间级 AI 发言最小间隔（全局设置，0 = 关）。
  getMinSpeakIntervalMs(): number {
    const row = this.database.query<{ value: string }, []>(
      "SELECT value FROM agora_settings WHERE key = 'min_speak_interval_ms'",
    ).get()
    const stored = row ? Number(row.value) : 0
    return Number.isInteger(stored) && stored >= 0 ? stored : 0
  }

  setMinSpeakIntervalMs(intervalMs: number): number {
    if (!Number.isInteger(intervalMs) || intervalMs < 0) {
      throw new AgoraStoreError(
        "invalid_min_speak_interval",
        "min_speak_interval_ms must be a non-negative integer",
      )
    }
    this.database.run(
      `INSERT INTO agora_settings(key, value, updated_at_ms) VALUES ('min_speak_interval_ms', ?, ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at_ms = excluded.updated_at_ms`,
      [String(intervalMs), this.clock()],
    )
    return intervalMs
  }

  /// executor 算发言闸用的时钟出口（测试注入的假时钟由此生效）。
  nowMs(): number {
    return this.clock()
  }

  /// 房间内最近一条 AI 消息的时间戳（无 AI 消息 = null）。
  lastAIMessageAtMs(roomId: string): number | null {
    return this.database.query<{ last: number | null }, [string]>(
      `SELECT MAX(message.created_at_ms) AS last
       FROM agora_messages message
       JOIN agora_actors actor ON actor.id = message.actor_id
       WHERE message.room_id = ? AND actor.kind = 'cc_bridge'`,
    ).get(roomId)?.last ?? null
  }

  /// free 档的旁听候选：房间内启用的 CC 成员，排除给定 actor（消息作者 + 已被显式 @ 的）。
  private observeCandidates(roomId: string, excludeActorIds: ReadonlySet<string>): AgoraMembership[] {
    return this.database.query<MembershipRow, [string]>(
      `SELECT ${MEMBERSHIP_COLUMNS}
       FROM agora_memberships
       WHERE room_id = ? AND is_enabled = 1 AND executor_kind = 'cc_bridge'
       ORDER BY joined_at_ms, id`,
    ).all(roomId).map(membershipFromRow)
      .filter(member => !excludeActorIds.has(member.actorId))
      .filter(member => this.actorById(member.actorId)?.disabledAtMs === null)
  }

  /// owner 发言抢权：作废房间内所有 pending 的接力 mention（depth > 0）和 pending 旁听。
  /// bridge 轮次 mention 是 depth 0 direct，天然不在杀伤面。
  private supersedeOnOwnerPost(roomId: string): AgoraMention[] {
    return this.failPendingMentions(
      roomId,
      "depth > 0 OR kind = 'observe'",
      [],
      "superseded_by_owner",
    )
  }

  /// 同一成员只保留最新一条 pending 旁听：给这些 membership 发新 observe 前，作废其旧 pending observe。
  private replacePendingObserves(roomId: string, targets: readonly AgoraMembership[]): AgoraMention[] {
    if (targets.length === 0) return []
    const placeholders = targets.map(() => "?").join(", ")
    return this.failPendingMentions(
      roomId,
      `kind = 'observe' AND target_membership_id IN (${placeholders})`,
      targets.map(target => target.id),
      "superseded_by_newer_message",
    )
  }

  /// round_robin 圈状态（agora_settings 每房一条 JSON）：owner 发言时快照 order，完成/pass 推进 cursor，圈满删除。
  private roundRobinStateKey(roomId: string): string {
    return `round_robin_state_${roomId}`
  }

  private roundRobinState(roomId: string): { order: string[]; cursor: number } | null {
    const row = this.database.query<{ value: string }, [string]>(
      "SELECT value FROM agora_settings WHERE key = ?",
    ).get(this.roundRobinStateKey(roomId))
    if (!row) return null
    try {
      const parsed = JSON.parse(row.value) as { order?: unknown; cursor?: unknown }
      if (
        Array.isArray(parsed.order) && parsed.order.every(entry => typeof entry === "string")
        && typeof parsed.cursor === "number" && Number.isInteger(parsed.cursor)
      ) {
        return { order: parsed.order as string[], cursor: parsed.cursor }
      }
    } catch {}
    return null
  }

  private saveRoundRobinState(roomId: string, state: { order: string[]; cursor: number }): void {
    this.database.run(
      `INSERT INTO agora_settings(key, value, updated_at_ms) VALUES (?, ?, ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at_ms = excluded.updated_at_ms`,
      [this.roundRobinStateKey(roomId), JSON.stringify(state), this.clock()],
    )
  }

  private clearRoundRobinState(roomId: string): void {
    this.database.run("DELETE FROM agora_settings WHERE key = ?", [this.roundRobinStateKey(roomId)])
  }

  /// owner 发言开新圈：重新快照成员顺序（进房顺序，与 observeCandidates 同序），只给 order[0] 发 depth 0 direct。
  private startRoundRobin(roomId: string, ownerActorId: string, sourceMessageId: string, now: number): AgoraMention[] {
    const roster = this.observeCandidates(roomId, new Set([ownerActorId]))
    if (roster.length === 0) {
      this.clearRoundRobinState(roomId)
      return []
    }
    this.saveRoundRobinState(roomId, { order: roster.map(member => member.actorId), cursor: 0 })
    return this.insertPendingMentions(roomId, sourceMessageId, [roster[0]], now, "direct", 0)
  }

  /// 轮次推进：完成/pass 者必须是 order[cursor] 才轮到下一位；跳过中途变不可用的成员；圈满清游标静默等 owner。
  private advanceRoundRobin(roomId: string, completedActorId: string, sourceMessageId: string, now: number): AgoraMention[] {
    const state = this.roundRobinState(roomId)
    if (!state || state.order[state.cursor] !== completedActorId) return []
    let cursor = state.cursor + 1
    while (cursor < state.order.length) {
      const membership = this.membershipByActor(roomId, state.order[cursor])
      const actor = membership ? this.actorById(membership.actorId) : null
      if (membership?.isEnabled && actor && actor.disabledAtMs === null) {
        this.saveRoundRobinState(roomId, { order: state.order, cursor })
        return this.insertPendingMentions(roomId, sourceMessageId, [membership], now, "direct", 0)
      }
      cursor += 1
    }
    this.clearRoundRobinState(roomId)
    return []
  }

  private failPendingMentions(
    roomId: string,
    condition: string,
    parameters: readonly string[],
    reason: string,
  ): AgoraMention[] {
    const rows = this.database.query<MentionRow, string[]>(
      `SELECT ${MENTION_COLUMNS}
       FROM agora_mentions
       WHERE room_id = ? AND state = 'pending' AND (${condition})
       ORDER BY created_at_ms, id`,
    ).all(roomId, ...parameters).map(mentionFromRow)
    const superseded: AgoraMention[] = []
    for (const mention of rows) {
      this.database.run(
        `UPDATE agora_mentions
         SET state = 'failed', claim_token_hash = NULL, claimed_at_ms = NULL,
             lease_expires_at_ms = NULL, last_error = ?
         WHERE id = ? AND state = 'pending'`,
        [reason, mention.id],
      )
      superseded.push(this.requireMention(mention.id))
    }
    return superseded
  }

  private actorById(actorId: string): AgoraActor | null {
    const row = this.database.query<ActorRow, [string]>(
      `SELECT ${ACTOR_COLUMNS} FROM agora_actors WHERE id = ?`,
    ).get(actorId)
    return row ? actorFromRow(row) : null
  }

  private actorByExternalKey(externalKey: string): AgoraActor | null {
    const row = this.database.query<ActorRow, [string]>(
      `SELECT ${ACTOR_COLUMNS} FROM agora_actors WHERE external_key = ?`,
    ).get(externalKey)
    return row ? actorFromRow(row) : null
  }

  private roomById(roomId: string): AgoraRoom | null {
    const row = this.database.query<RoomRow, [string]>(
      `SELECT ${ROOM_COLUMNS} FROM agora_rooms WHERE id = ?`,
    ).get(roomId)
    return row ? roomFromRow(row) : null
  }

  private membershipById(membershipId: string): AgoraMembership | null {
    const row = this.database.query<MembershipRow, [string]>(
      `SELECT ${MEMBERSHIP_COLUMNS} FROM agora_memberships WHERE id = ?`,
    ).get(membershipId)
    return row ? membershipFromRow(row) : null
  }

  private membershipByActor(roomId: string, actorId: string): AgoraMembership | null {
    const row = this.database.query<MembershipRow, [string, string]>(
      `SELECT ${MEMBERSHIP_COLUMNS} FROM agora_memberships WHERE room_id = ? AND actor_id = ?`,
    ).get(roomId, actorId)
    return row ? membershipFromRow(row) : null
  }

  private messageById(messageId: string): AgoraMessage | null {
    const row = this.database.query<MessageRow, [string]>(
      `SELECT ${MESSAGE_COLUMNS} FROM agora_messages WHERE id = ?`,
    ).get(messageId)
    return row ? messageFromRow(row) : null
  }

  private messageByClientId(roomId: string, actorId: string, clientMessageId: string): AgoraMessage | null {
    const row = this.database.query<MessageRow, [string, string, string]>(
      `SELECT ${MESSAGE_COLUMNS}
       FROM agora_messages
       WHERE room_id = ? AND actor_id = ? AND client_message_id = ?`,
    ).get(roomId, actorId, clientMessageId)
    return row ? messageFromRow(row) : null
  }

  private mentionById(mentionId: string): AgoraMention | null {
    const row = this.database.query<MentionRow, [string]>(
      `SELECT ${MENTION_COLUMNS} FROM agora_mentions WHERE id = ?`,
    ).get(mentionId)
    return row ? mentionFromRow(row) : null
  }

  private bridgeById(bridgeId: string): AgoraBridge | null {
    const row = this.database.query<BridgeRow, [string]>(
      `SELECT ${BRIDGE_COLUMNS} FROM agora_bridges WHERE id = ?`,
    ).get(bridgeId)
    return row ? bridgeFromRow(row) : null
  }

  private bridgeByMention(mentionId: string): AgoraBridge | null {
    const row = this.database.query<BridgeRow, [string]>(
      `SELECT ${BRIDGE_COLUMNS}
       FROM agora_bridges
       WHERE id = (SELECT bridge_id FROM agora_bridge_turns WHERE mention_id = ?)`,
    ).get(mentionId)
    return row ? bridgeFromRow(row) : null
  }

  private bridgeTurnByMention(mentionId: string): AgoraBridgeTurn | null {
    const row = this.database.query<BridgeTurnRow, [string]>(
      `SELECT ${BRIDGE_TURN_COLUMNS} FROM agora_bridge_turns WHERE mention_id = ?`,
    ).get(mentionId)
    return row ? bridgeTurnFromRow(row) : null
  }

  private currentBridgeTurn(bridgeId: string): AgoraBridgeTurn | null {
    const row = this.database.query<BridgeTurnRow, [string]>(
      `SELECT ${BRIDGE_TURN_COLUMNS}
       FROM agora_bridge_turns
       WHERE bridge_id = ? AND state IN ('pending', 'claimed')
       ORDER BY turn_index DESC LIMIT 1`,
    ).get(bridgeId)
    return row ? bridgeTurnFromRow(row) : null
  }

  private mentionTokenHash(mentionId: string): string | null {
    return this.database.query<HashRow, [string]>(
      "SELECT claim_token_hash AS claimTokenHash FROM agora_mentions WHERE id = ?",
    ).get(mentionId)?.claimTokenHash ?? null
  }

  private requireRoom(roomId: string): AgoraRoom {
    requireUuid(roomId)
    const room = this.roomById(roomId)
    if (!room) throw new AgoraStoreError("room_not_found", `Agora room not found: ${roomId}`)
    return room
  }

  private requireActor(actorId: string): AgoraActor {
    requireUuid(actorId)
    const actor = this.actorById(actorId)
    if (!actor) throw new AgoraStoreError("actor_not_found", `Agora actor not found: ${actorId}`)
    return actor
  }

  private requireMention(mentionId: string): AgoraMention {
    requireUuid(mentionId)
    const mention = this.mentionById(mentionId)
    if (!mention) throw new AgoraStoreError("mention_not_found", `Agora mention not found: ${mentionId}`)
    return mention
  }

  private insertActor(kind: AgoraActorKind, externalKey: string): AgoraActor {
    const existing = this.actorByExternalKey(externalKey)
    if (existing) {
      if (existing.kind !== kind) {
        throw new AgoraStoreError("actor_kind_mismatch", `Actor ${externalKey} has kind ${existing.kind}`)
      }
      return existing
    }
    const actor: AgoraActor = {
      id: randomUUID(),
      kind,
      externalKey,
      createdAtMs: this.clock(),
      disabledAtMs: null,
    }
    this.database.run(
      `INSERT INTO agora_actors(id, kind, external_key, created_at_ms, disabled_at_ms)
       VALUES (?, ?, ?, ?, NULL)`,
      [actor.id, actor.kind, actor.externalKey, actor.createdAtMs],
    )
    return actor
  }

  upsertOwnerActor(): AgoraActor {
    return this.transaction(() => this.insertActor("owner", AGORA_OWNER_EXTERNAL_KEY))
  }

  upsertCCActor(sessionName: string): AgoraActor {
    const validSessionName = requireSessionName(sessionName)
    return this.transaction(() => this.insertActor("cc_bridge", `cc-session:${validSessionName}`))
  }

  getActor(actorId: string): AgoraActor | null {
    requireUuid(actorId)
    return this.actorById(actorId)
  }

  listCCActors(): AgoraActor[] {
    return this.database.query<ActorRow, []>(
      `SELECT ${ACTOR_COLUMNS}
       FROM agora_actors
       WHERE kind = 'cc_bridge'
       ORDER BY created_at_ms, id`,
    ).all().map(actorFromRow)
  }

  disableActor(actorId: string): AgoraActor {
    return this.transaction(() => {
      const actor = this.requireActor(actorId)
      if (actor.disabledAtMs === null) {
        this.database.run("UPDATE agora_actors SET disabled_at_ms = ? WHERE id = ?", [this.clock(), actor.id])
      }
      return this.requireActor(actor.id)
    })
  }

  createRoom(input: AgoraCreateRoomInput): AgoraRoomCreateResult {
    const floorId = requireFloorId(input.floorId)
    const title = requireTitle(input.title)
    const clientRequestId = requireUuid(input.clientRequestId)
    const isDM = input.isDM ?? false
    const ownerHandle = normalizeAgoraHandle(input.ownerProfile.handle)
    const ownerDisplayName = requireDisplayName(input.ownerProfile.displayName)
    if (isDM && input.members.length !== 1) {
      throw new AgoraStoreError("invalid_dm_members", "A direct message room must contain exactly one agent")
    }
    if (input.members.length + 1 > AGORA_LIMITS.membershipsPerRoom) {
      throw new AgoraStoreError(
        "membership_limit_exceeded",
        `A room can contain at most ${AGORA_LIMITS.membershipsPerRoom} memberships`,
        { limit: AGORA_LIMITS.membershipsPerRoom },
      )
    }

    let rateTimestamp: { actorId: string; now: number } | null = null
    const result = this.transaction(() => {
      const owner = this.actorByExternalKey(AGORA_OWNER_EXTERNAL_KEY)
      if (!owner) throw new AgoraStoreError("owner_not_found", "Agora owner actor has not been created")
      if (owner.disabledAtMs !== null) throw new AgoraStoreError("owner_disabled", "Agora owner actor is disabled")

      const existing = this.database.query<RoomRow, [string, string]>(
        `SELECT ${ROOM_COLUMNS}
         FROM agora_rooms
         WHERE owner_actor_id = ? AND client_request_id = ?`,
      ).get(owner.id, clientRequestId)
      if (existing) {
        const room = roomFromRow(existing)
        return { room, memberships: this.listMemberships(room.id), idempotent: true }
      }

      const preparedMembers = input.members.map(spec => this.prepareMemberSpec(spec))
      const dmPeerActorId = isDM ? preparedMembers[0]?.actor.id ?? null : null
      if (dmPeerActorId) {
        const existingDM = this.database.query<RoomRow, [string, string, string]>(
          `SELECT ${ROOM_COLUMNS}
           FROM agora_rooms
           WHERE floor_id = ? AND owner_actor_id = ? AND dm_peer_actor_id = ? AND is_dm = 1`,
        ).get(floorId, owner.id, dmPeerActorId)
        if (existingDM) {
          const room = roomFromRow(existingDM)
          return { room, memberships: this.listMemberships(room.id), idempotent: true }
        }
      }
      const handles = new Set<string>([ownerHandle])
      const actors = new Set<string>([owner.id])
      for (const member of preparedMembers) {
        if (handles.has(member.handle)) {
          throw new AgoraStoreError("duplicate_handle", `Duplicate room handle: @${member.handle}`, {
            handle: member.handle,
          })
        }
        if (actors.has(member.actor.id)) {
          throw new AgoraStoreError("duplicate_membership", `Actor already belongs to the room: ${member.actor.id}`)
        }
        handles.add(member.handle)
        actors.add(member.actor.id)
      }

      const now = this.clock()
      this.enforceRoomRateLimit(owner.id, now)
      const roomId = randomUUID()
      this.database.run(
        `INSERT INTO agora_rooms(
           id, floor_id, title, owner_actor_id, client_request_id,
           is_dm, dm_peer_actor_id, next_seq, is_enabled, created_at_ms, updated_at_ms
         ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, 1, ?, ?)`,
        [roomId, floorId, title, owner.id, clientRequestId, isDM ? 1 : 0, dmPeerActorId, now, now],
      )
      this.insertMembership({
        id: randomUUID(),
        roomId,
        actorId: owner.id,
        handle: ownerHandle,
        displayName: ownerDisplayName,
        avatarRef: input.ownerProfile.avatarRef ?? null,
        role: "owner",
        executorKind: "none",
        executorConfigJson: "{}",
        isEnabled: true,
        joinedAtMs: now,
      })
      for (const member of preparedMembers) {
        this.insertMembership({
          id: randomUUID(),
          roomId,
          actorId: member.actor.id,
          handle: member.handle,
          displayName: member.displayName,
          avatarRef: member.avatarRef,
          role: "member",
          executorKind: "cc_bridge",
          executorConfigJson: JSON.stringify({ session_name: member.sessionName }),
          isEnabled: true,
          joinedAtMs: now,
        })
      }
      rateTimestamp = { actorId: owner.id, now }
      return { room: this.requireRoom(roomId), memberships: this.listMemberships(roomId), idempotent: false }
    })
    if (rateTimestamp) {
      const recent = this.roomRateTimestamps.get(rateTimestamp.actorId) ?? []
      recent.push(rateTimestamp.now)
      this.roomRateTimestamps.set(rateTimestamp.actorId, recent)
    }
    return result
  }

  private prepareMemberSpec(spec: AgoraRoomMemberSpec): {
    actor: AgoraActor
    sessionName: string
    handle: string
    displayName: string
    avatarRef: string | null
  } {
    const actor = this.requireActor(spec.actorId)
    if (actor.disabledAtMs !== null) throw new AgoraStoreError("actor_disabled", `Actor is disabled: ${actor.id}`)
    if (actor.kind !== "cc_bridge" || !actor.externalKey.startsWith("cc-session:")) {
      throw new AgoraStoreError("actor_kind_mismatch", `Actor is not a CC Bridge actor: ${actor.id}`)
    }
    const sessionName = requireSessionName(actor.externalKey.slice("cc-session:".length))
    return {
      actor,
      sessionName,
      handle: normalizeAgoraHandle(spec.handle),
      displayName: requireDisplayName(spec.displayName),
      avatarRef: spec.avatarRef ?? null,
    }
  }

  private insertMembership(membership: AgoraMembership): void {
    this.database.run(
      `INSERT INTO agora_memberships(
         id, room_id, actor_id, handle, display_name, avatar_ref, role,
         executor_kind, executor_config_json, is_enabled, joined_at_ms
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        membership.id,
        membership.roomId,
        membership.actorId,
        membership.handle,
        membership.displayName,
        membership.avatarRef,
        membership.role,
        membership.executorKind,
        membership.executorConfigJson,
        membership.isEnabled ? 1 : 0,
        membership.joinedAtMs,
      ],
    )
  }

  addMember(roomId: string, spec: AgoraRoomMemberSpec): AgoraMembership {
    return this.transaction(() => {
      const room = this.requireRoom(roomId)
      if (!room.isEnabled) throw new AgoraStoreError("room_disabled", `Agora room is disabled: ${room.id}`)
      if (room.isDM) throw new AgoraStoreError("dm_membership_fixed", "Direct message room membership is fixed")
      const count = this.database.query<CountRow, [string]>(
        "SELECT COUNT(*) AS count FROM agora_memberships WHERE room_id = ?",
      ).get(room.id)?.count ?? 0
      if (count >= AGORA_LIMITS.membershipsPerRoom) {
        throw new AgoraStoreError(
          "membership_limit_exceeded",
          `A room can contain at most ${AGORA_LIMITS.membershipsPerRoom} memberships`,
          { limit: AGORA_LIMITS.membershipsPerRoom },
        )
      }
      const member = this.prepareMemberSpec(spec)
      const membership: AgoraMembership = {
        id: randomUUID(),
        roomId: room.id,
        actorId: member.actor.id,
        handle: member.handle,
        displayName: member.displayName,
        avatarRef: member.avatarRef,
        role: "member",
        executorKind: "cc_bridge",
        executorConfigJson: JSON.stringify({ session_name: member.sessionName }),
        isEnabled: true,
        joinedAtMs: this.clock(),
      }
      try {
        this.insertMembership(membership)
      } catch (error) {
        if (error instanceof Error && isUniqueConstraint(error, "agora_memberships.room_id, agora_memberships.handle")) {
          throw new AgoraStoreError("duplicate_handle", `Duplicate room handle: @${membership.handle}`, {
            handle: membership.handle,
          })
        }
        if (error instanceof Error && isUniqueConstraint(error, "agora_memberships.room_id, agora_memberships.actor_id")) {
          throw new AgoraStoreError("duplicate_membership", `Actor already belongs to the room: ${membership.actorId}`)
        }
        throw error
      }
      return this.membershipById(membership.id) ?? membership
    })
  }

  setMembershipEnabled(membershipId: string, isEnabled: boolean): AgoraMembership {
    return this.transaction(() => {
      requireUuid(membershipId)
      const membership = this.membershipById(membershipId)
      if (!membership) {
        throw new AgoraStoreError("membership_not_found", `Agora membership not found: ${membershipId}`)
      }
      this.database.run("UPDATE agora_memberships SET is_enabled = ? WHERE id = ?", [isEnabled ? 1 : 0, membership.id])
      const updated = this.membershipById(membership.id)
      if (!updated) throw new AgoraStoreError("membership_not_found", `Agora membership not found: ${membership.id}`)
      return updated
    })
  }

  setRoomEnabled(roomId: string, isEnabled: boolean): AgoraRoom {
    return this.transaction(() => {
      const room = this.requireRoom(roomId)
      const now = this.clock()
      this.database.run(
        "UPDATE agora_rooms SET is_enabled = ?, updated_at_ms = ? WHERE id = ?",
        [isEnabled ? 1 : 0, now, room.id],
      )
      return this.requireRoom(room.id)
    })
  }

  getRoom(roomId: string): AgoraRoom | null {
    requireUuid(roomId)
    return this.roomById(roomId)
  }

  listRooms(floorId: string): AgoraRoomSnapshot[] {
    const validFloorId = requireFloorId(floorId)
    return this.database.query<RoomRow, [string]>(
      `SELECT ${ROOM_COLUMNS}
       FROM agora_rooms
       WHERE floor_id = ? AND is_enabled = 1
       ORDER BY updated_at_ms DESC, id`,
    ).all(validFloorId).map(row => {
      const room = roomFromRow(row)
      return { room, memberships: this.listMemberships(room.id) }
    })
  }

  listMemberships(roomId: string): AgoraMembership[] {
    requireUuid(roomId)
    return this.database.query<MembershipRow, [string]>(
      `SELECT ${MEMBERSHIP_COLUMNS}
       FROM agora_memberships
       WHERE room_id = ?
       ORDER BY CASE role WHEN 'owner' THEN 0 ELSE 1 END, joined_at_ms, handle, id`,
    ).all(roomId).map(membershipFromRow)
  }

  openRoom(roomId: string, beforeSeq?: number, limit: number = AGORA_LIMITS.messagePageSize): AgoraRoomOpenResult {
    const room = this.requireRoom(roomId)
    const pageLimit = requirePageLimit(limit)
    if (beforeSeq !== undefined && (!Number.isInteger(beforeSeq) || beforeSeq < 1)) {
      throw new AgoraStoreError("invalid_id", "before_seq must be a positive integer")
    }
    const rows = beforeSeq === undefined
      ? this.database.query<MessageRow, [string, number]>(
          `SELECT ${MESSAGE_COLUMNS}
           FROM agora_messages
           WHERE room_id = ?
           ORDER BY seq DESC
           LIMIT ?`,
        ).all(room.id, pageLimit)
      : this.database.query<MessageRow, [string, number, number]>(
          `SELECT ${MESSAGE_COLUMNS}
           FROM agora_messages
           WHERE room_id = ? AND seq < ?
           ORDER BY seq DESC
           LIMIT ?`,
        ).all(room.id, beforeSeq, pageLimit)
    const counts: Record<AgoraMentionState, number> = { pending: 0, claimed: 0, completed: 0, failed: 0 }
    // observe 不进计数：旁听机会大量生成/沉默，进 badge 会常亮误报，收件箱只关心必答的。
    for (const row of this.database.query<StateCountRow, [string]>(
      "SELECT state, COUNT(*) AS count FROM agora_mentions WHERE room_id = ? AND kind = 'direct' GROUP BY state",
    ).all(room.id)) {
      counts[row.state] = row.count
    }
    return {
      room,
      memberships: this.listMemberships(room.id),
      messages: rows.reverse().map(messageFromRow),
      mentionCounts: counts,
      bridge: this.getBridgeStateForRoom(room.id),
    }
  }

  getBridgeState(bridgeId: string): AgoraBridgeState {
    requireUuid(bridgeId)
    const bridge = this.bridgeById(bridgeId)
    if (!bridge) throw new AgoraStoreError("bridge_not_found", `Agora bridge not found: ${bridgeId}`)
    return { bridge, currentTurn: this.currentBridgeTurn(bridge.id) }
  }

  getBridgeStateForRoom(roomId: string): AgoraBridgeState | null {
    const room = this.requireRoom(roomId)
    const row = this.database.query<BridgeRow, [string]>(
      `SELECT ${BRIDGE_COLUMNS}
       FROM agora_bridges
       WHERE room_id = ?
       ORDER BY CASE status WHEN 'active' THEN 0 ELSE 1 END, updated_at_ms DESC, id DESC
       LIMIT 1`,
    ).get(room.id)
    if (!row) return null
    const bridge = bridgeFromRow(row)
    return { bridge, currentTurn: this.currentBridgeTurn(bridge.id) }
  }

  getBridgeStateForMention(mentionId: string): AgoraBridgeState | null {
    requireUuid(mentionId)
    const bridge = this.bridgeByMention(mentionId)
    return bridge ? { bridge, currentTurn: this.currentBridgeTurn(bridge.id) } : null
  }

  listBridgeTurns(bridgeId: string): AgoraBridgeTurn[] {
    const bridge = this.getBridgeState(bridgeId).bridge
    return this.database.query<BridgeTurnRow, [string]>(
      `SELECT ${BRIDGE_TURN_COLUMNS}
       FROM agora_bridge_turns WHERE bridge_id = ? ORDER BY turn_index`,
    ).all(bridge.id).map(bridgeTurnFromRow)
  }

  /// cursor seq 对应消息的 created_at_ms（resume 补放 mutation 的时间水位）。seq=0/不存在 → 0。
  messageCreatedAt(roomId: string, seq: number): number {
    if (seq <= 0) return 0
    const row = this.database.query<{ createdAtMs: number }, [string, number]>(
      `SELECT created_at_ms AS createdAtMs FROM agora_messages WHERE room_id = ? AND seq = ?`,
    ).get(roomId, seq)
    return row?.createdAtMs ?? 0
  }

  /// 指定时刻起（含同毫秒——快速 post+edit 场景漏放是灾难，重放由幂等 merge 吸收）被编辑/软删过的消息（resume 补放 message.updated：断连设备的旧窗口才能
  /// 看到编辑后内容/墓碑——软删的隐私预期依赖这条通路）。已见过的重放由 client 幂等 merge 吸收。
  listMutatedSince(roomId: string, sinceMs: number, limit: number = AGORA_LIMITS.messagePageSize): AgoraMessage[] {
    const room = this.requireRoom(roomId)
    const pageLimit = requirePageLimit(limit)
    return this.database.query<MessageRow, [string, number, number, number]>(
      `SELECT ${MESSAGE_COLUMNS}
       FROM agora_messages
       WHERE room_id = ? AND (edited_at_ms >= ? OR deleted_at_ms >= ?)
       ORDER BY seq ASC
       LIMIT ?`,
    ).all(room.id, sinceMs, sinceMs, pageLimit).map(messageFromRow)
  }

  listMessagesAfter(roomId: string, afterSeq: number, limit: number = AGORA_LIMITS.messagePageSize): AgoraMessage[] {
    const room = this.requireRoom(roomId)
    const pageLimit = requirePageLimit(limit)
    if (!Number.isInteger(afterSeq) || afterSeq < 0) {
      throw new AgoraStoreError("invalid_id", "after_seq must be a non-negative integer")
    }
    return this.database.query<MessageRow, [string, number, number]>(
      `SELECT ${MESSAGE_COLUMNS}
       FROM agora_messages
       WHERE room_id = ? AND seq > ?
       ORDER BY seq ASC
       LIMIT ?`,
    ).all(room.id, afterSeq, pageLimit).map(messageFromRow)
  }

  listMessagesThrough(roomId: string, throughSeq: number, limit: number): AgoraMessage[] {
    const room = this.requireRoom(roomId)
    if (!Number.isInteger(throughSeq) || throughSeq < 1 || throughSeq >= room.nextSeq) {
      throw new AgoraStoreError("invalid_payload", `throughSeq must identify a message in room ${room.id}`)
    }
    if (!Number.isInteger(limit) || limit < 1 || limit > 80) {
      throw new AgoraStoreError("invalid_limit", "Context message limit must be 1...80")
    }
    return this.database.query<MessageRow, [string, number, number]>(
      `SELECT ${MESSAGE_COLUMNS}
       FROM (
         SELECT * FROM agora_messages
         WHERE room_id = ? AND seq <= ?
         ORDER BY seq DESC
         LIMIT ?
       )
       ORDER BY seq ASC`,
    ).all(room.id, throughSeq, limit).map(messageFromRow)
  }

  getMessage(messageId: string): AgoraMessage | null {
    requireUuid(messageId)
    return this.messageById(messageId)
  }

  listMessageEdits(messageId: string): AgoraMessageEdit[] {
    const message = this.messageById(requireUuid(messageId))
    if (!message) throw new AgoraStoreError("message_not_found", `Agora message not found: ${messageId}`)
    return this.database.query<MessageEditRow, [string]>(
      `SELECT id, message_id AS messageId, editor_actor_id AS editorActorId,
              previous_content AS previousContent, edited_at_ms AS editedAtMs
       FROM agora_message_edits
       WHERE message_id = ?
       ORDER BY edited_at_ms, id`,
    ).all(message.id)
  }

  editMessage(messageId: string, actorId: string, content: string): AgoraMessage {
    const validMessageId = requireUuid(messageId)
    const validActorId = requireUuid(actorId)
    const validContent = requireMessageContent(content)
    return this.transaction(() => {
      const actor = this.requireActor(validActorId)
      if (actor.disabledAtMs !== null) throw new AgoraStoreError("actor_disabled", "Cannot edit as a disabled actor")
      const message = this.messageById(validMessageId)
      if (!message) throw new AgoraStoreError("message_not_found", `Agora message not found: ${validMessageId}`)
      if (message.actorId !== actor.id) {
        throw new AgoraStoreError("not_message_owner", "Only the original actor can edit this message")
      }
      if (message.isDeleted) throw new AgoraStoreError("invalid_message", "Deleted messages cannot be edited")
      const room = this.requireRoom(message.roomId)
      if (!room.isEnabled) throw new AgoraStoreError("room_disabled", `Agora room is disabled: ${room.id}`)
      const membership = this.membershipByActor(room.id, actor.id)
      if (!membership || !membership.isEnabled) {
        throw new AgoraStoreError("membership_disabled", "Enabled room membership is required")
      }
      if (message.content === validContent) return message
      const editedAtMs = this.clock()
      this.database.run(
        `INSERT INTO agora_message_edits(id, message_id, editor_actor_id, previous_content, edited_at_ms)
         VALUES (?, ?, ?, ?, ?)`,
        [randomUUID(), message.id, actor.id, message.content, editedAtMs],
      )
      this.database.run(
        "UPDATE agora_messages SET content = ?, edited_at_ms = ? WHERE id = ?",
        [validContent, editedAtMs, message.id],
      )
      return this.messageById(message.id)!
    })
  }

  deleteMessage(messageId: string, actorId: string): AgoraMessageDeleteResult {
    const validMessageId = requireUuid(messageId)
    const validActorId = requireUuid(actorId)
    return this.transaction(() => {
      const actor = this.requireActor(validActorId)
      if (actor.disabledAtMs !== null) throw new AgoraStoreError("actor_disabled", "Cannot delete as a disabled actor")
      const message = this.messageById(validMessageId)
      if (!message) throw new AgoraStoreError("message_not_found", `Agora message not found: ${validMessageId}`)
      const room = this.requireRoom(message.roomId)
      const membership = this.membershipByActor(room.id, actor.id)
      if (!membership || !membership.isEnabled) {
        throw new AgoraStoreError("membership_disabled", "Enabled room membership is required")
      }
      if (actor.id !== room.ownerActorId && actor.id !== message.actorId) {
        throw new AgoraStoreError("message_delete_forbidden", "Only the room owner or original actor can delete this message")
      }
      if (message.isDeleted) {
        return { message, mentions: this.listMentionsForMessage(message.id) }
      }
      const deletedAtMs = this.clock()
      this.database.run(
        `UPDATE agora_messages
         SET content = '', is_deleted = 1, deleted_at_ms = ?
         WHERE id = ?`,
        [deletedAtMs, message.id],
      )
      // 删除即清内容的语义要贯穿编辑历史——否则每个历史版本全文仍在 DB 明文可读
      this.database.run(`DELETE FROM agora_message_edits WHERE message_id = ?`, [message.id])
      this.database.run(
        `UPDATE agora_mentions
         SET state = 'failed', claim_token_hash = NULL, claimed_at_ms = NULL,
             lease_expires_at_ms = NULL, last_error = 'source message deleted'
         WHERE source_message_id = ? AND state IN ('pending', 'claimed')`,
        [message.id],
      )
      for (const mention of this.listMentionsForMessage(message.id)) {
        if (mention.state === "failed") {
          this.updateBridgeAfterMentionFailure(mention.id, "source message deleted", true, deletedAtMs)
        }
      }
      return {
        message: this.messageById(message.id)!,
        mentions: this.listMentionsForMessage(message.id),
      }
    })
  }

  getMention(mentionId: string): AgoraMention | null {
    requireUuid(mentionId)
    return this.mentionById(mentionId)
  }

  listPendingMentions(): AgoraMentionDispatch[] {
    const rows = this.database.query<{ id: string }, []>(
      `SELECT mention.id
       FROM agora_mentions mention
       JOIN agora_memberships membership ON membership.id = mention.target_membership_id
       JOIN agora_actors actor ON actor.id = membership.actor_id
       JOIN agora_rooms room ON room.id = mention.room_id
       JOIN agora_messages source ON source.id = mention.source_message_id
       WHERE mention.state = 'pending'
         AND membership.is_enabled = 1
         AND membership.executor_kind = 'cc_bridge'
         AND actor.disabled_at_ms IS NULL
         AND room.is_enabled = 1
       ORDER BY mention.created_at_ms, source.seq, mention.id`,
    ).all()
    return rows.map(row => this.dispatchForMention(this.requireMention(row.id)))
  }

  listMentionsForMessage(messageId: string): AgoraMention[] {
    requireUuid(messageId)
    return this.database.query<MentionRow, [string]>(
      `SELECT ${MENTION_COLUMNS}
       FROM agora_mentions
       WHERE source_message_id = ?
       ORDER BY created_at_ms, id`,
    ).all(messageId).map(mentionFromRow)
  }

  listMentions(
    roomId: string,
    state?: AgoraMentionState,
    limit: number = AGORA_LIMITS.messagePageSize,
    kind?: AgoraMentionKind,
  ): AgoraMention[] {
    const room = this.requireRoom(roomId)
    const pageLimit = requirePageLimit(limit)
    const conditions = ["room_id = ?"]
    const parameters: (string | number)[] = [room.id]
    if (state) {
      conditions.push("state = ?")
      parameters.push(state)
    }
    if (kind) {
      conditions.push("kind = ?")
      parameters.push(kind)
    }
    parameters.push(pageLimit)
    return this.database.query<MentionRow, (string | number)[]>(
      `SELECT ${MENTION_COLUMNS}
       FROM agora_mentions
       WHERE ${conditions.join(" AND ")}
       ORDER BY created_at_ms DESC, id
       LIMIT ?`,
    ).all(...parameters).map(mentionFromRow)
  }

  private resolveMentionTargets(
    roomId: string,
    senderActorId: string,
    content: string,
  ): AgoraMembership[] {
    const handles = parseExplicitMentionHandles(content)
    if (handles.length > AGORA_LIMITS.mentionsPerMessage) {
      throw new AgoraStoreError(
        "mention_limit_exceeded",
        `A message can target at most ${AGORA_LIMITS.mentionsPerMessage} members`,
        { limit: AGORA_LIMITS.mentionsPerMessage },
      )
    }
    const targets: AgoraMembership[] = []
    const unknown: string[] = []
    const disabled: string[] = []
    for (const handle of handles) {
      const row = this.database.query<MembershipRow, [string, string]>(
        `SELECT ${MEMBERSHIP_COLUMNS}
         FROM agora_memberships
         WHERE room_id = ? AND handle = ? COLLATE NOCASE`,
      ).get(roomId, handle)
      if (!row) {
        unknown.push(handle)
        continue
      }
      const membership = membershipFromRow(row)
      if (membership.actorId === senderActorId) {
        throw new AgoraStoreError("self_mention_not_allowed", `Cannot mention @${handle}`)
      }
      const actor = this.actorById(membership.actorId)
      if (!membership.isEnabled || !actor || actor.disabledAtMs !== null) {
        disabled.push(handle)
        continue
      }
      targets.push(membership)
    }
    if (unknown.length > 0) {
      throw new AgoraStoreError("unknown_handle", `Unknown Agora handle: @${unknown[0]}`, {
        unknown_handles: unknown,
      })
    }
    if (disabled.length > 0) {
      throw new AgoraStoreError("disabled_handle", `Disabled Agora handle: @${disabled[0]}`, {
        disabled_handles: disabled,
      })
    }
    return targets
  }

  private allocateSequence(roomId: string, now: number): number {
    const row = this.database.query<SequenceRow, [number, string]>(
      `UPDATE agora_rooms
       SET next_seq = next_seq + 1, updated_at_ms = ?
       WHERE id = ?
       RETURNING next_seq - 1 AS seq`,
    ).get(now, roomId)
    if (!row) throw new AgoraStoreError("room_not_found", `Agora room not found: ${roomId}`)
    return row.seq
  }

  private insertMessage(
    roomId: string,
    actorId: string,
    clientMessageId: string,
    content: string,
    now: number,
  ): AgoraMessage {
    const message: AgoraMessage = {
      id: randomUUID(),
      roomId,
      seq: this.allocateSequence(roomId, now),
      actorId,
      clientMessageId,
      content,
      createdAtMs: now,
      editedAtMs: null,
      isDeleted: false,
      deletedAtMs: null,
    }
    this.database.run(
      `INSERT INTO agora_messages(
         id, room_id, seq, actor_id, client_message_id, content, created_at_ms
       ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [
        message.id,
        message.roomId,
        message.seq,
        message.actorId,
        message.clientMessageId,
        message.content,
        message.createdAtMs,
      ],
    )
    return message
  }

  private insertPendingMentions(
    roomId: string,
    sourceMessageId: string,
    targets: readonly AgoraMembership[],
    now: number,
    kind: AgoraMentionKind = "direct",
    depth = 0,
  ): AgoraMention[] {
    const mentions: AgoraMention[] = []
    for (const target of targets) {
      const mention: AgoraMention = {
        id: randomUUID(),
        roomId,
        sourceMessageId,
        targetMembershipId: target.id,
        state: "pending",
        kind,
        depth,
        claimedAtMs: null,
        leaseExpiresAtMs: null,
        completedAtMs: null,
        resultMessageId: null,
        attemptCount: 0,
        lastError: null,
        createdAtMs: now,
      }
      this.database.run(
        `INSERT INTO agora_mentions(
           id, room_id, source_message_id, target_membership_id, state, kind, depth,
           claim_token_hash, claimed_at_ms, lease_expires_at_ms, completed_at_ms,
           result_message_id, attempt_count, last_error, created_at_ms
         ) VALUES (?, ?, ?, ?, 'pending', ?, ?, NULL, NULL, NULL, NULL, NULL, 0, NULL, ?)`,
        [
          mention.id, mention.roomId, mention.sourceMessageId, mention.targetMembershipId,
          mention.kind, mention.depth, mention.createdAtMs,
        ],
      )
      mentions.push(mention)
    }
    return mentions
  }

  postOwnerMessage(
    roomId: string,
    clientMessageId: string,
    content: string,
    floorId: string,
  ): AgoraMessageWriteResult {
    const validClientMessageId = requireUuid(clientMessageId)
    const validFloorId = requireFloorId(floorId)
    let rateTimestamp: { actorId: string; now: number } | null = null
    const result = this.transaction(() => {
      const room = this.requireRoom(roomId)
      if (!room.isEnabled) throw new AgoraStoreError("room_disabled", `Agora room is disabled: ${room.id}`)
      if (room.floorId !== validFloorId) throw new AgoraStoreError("floor_mismatch", "Room does not belong to current floor")
      const owner = this.actorByExternalKey(AGORA_OWNER_EXTERNAL_KEY)
      if (!owner) throw new AgoraStoreError("owner_not_found", "Agora owner actor has not been created")
      if (owner.disabledAtMs !== null) throw new AgoraStoreError("owner_disabled", "Agora owner actor is disabled")
      if (room.ownerActorId !== owner.id) throw new AgoraStoreError("not_room_owner", "Authenticated owner does not own room")
      const ownerMembership = this.membershipByActor(room.id, owner.id)
      if (!ownerMembership || ownerMembership.role !== "owner") {
        throw new AgoraStoreError("owner_membership_required", "Enabled owner membership is required")
      }
      if (!ownerMembership.isEnabled) {
        throw new AgoraStoreError("membership_disabled", "Owner membership is disabled")
      }

      const existing = this.messageByClientId(room.id, owner.id, validClientMessageId)
      if (existing) {
        return { message: existing, mentions: this.listMentionsForMessage(existing.id), idempotent: true }
      }

      const validContent = requireMessageContent(content)
      const mode = this.getSpeechMode()
      // round_robin：owner 消息不走 @ fanout，只给 order[0] 发一条轮次点名。
      const directTargets = mode === "round_robin"
        ? []
        : this.resolveMentionTargets(room.id, owner.id, validContent)
      let observeTargets: AgoraMembership[] = []
      if (mode === "free") {
        const exclude = new Set([owner.id, ...directTargets.map(target => target.actorId)])
        observeTargets = this.observeCandidates(room.id, exclude)
      }
      const now = this.clock()
      this.enforceMessageRateLimit(owner.id, now)
      const superseded = this.supersedeOnOwnerPost(room.id)
      if (mode === "round_robin") {
        // owner 插话重开新圈：上一圈的 pending 轮次点名（depth 0 direct，非 bridge 轮次）一并作废。
        superseded.push(...this.failPendingMentions(
          room.id,
          "kind = 'direct' AND depth = 0 AND id NOT IN (SELECT mention_id FROM agora_bridge_turns)",
          [],
          "superseded_by_owner",
        ))
      }
      const message = this.insertMessage(room.id, owner.id, validClientMessageId, validContent, now)
      const mentions = mode === "round_robin"
        ? this.startRoundRobin(room.id, owner.id, message.id, now)
        : [
          ...this.insertPendingMentions(room.id, message.id, directTargets, now, "direct", 0),
          ...this.insertPendingMentions(room.id, message.id, observeTargets, now, "observe", 0),
        ]
      rateTimestamp = { actorId: owner.id, now }
      return { message, mentions, idempotent: false, supersededMentions: superseded }
    })
    if (rateTimestamp) {
      const recent = this.messageRateTimestamps.get(rateTimestamp.actorId) ?? []
      recent.push(rateTimestamp.now)
      this.messageRateTimestamps.set(rateTimestamp.actorId, recent)
    }
    return result
  }

  startBridge(input: AgoraBridgeStartInput): AgoraBridgeStartResult {
    const roomId = requireUuid(input.roomId)
    const clientRequestId = requireUuid(input.clientRequestId)
    const firstActorId = requireUuid(input.firstActorId)
    const secondActorId = requireUuid(input.secondActorId)
    const prompt = requireMessageContent(input.prompt)
    if (firstActorId === secondActorId) {
      throw new AgoraStoreError("bridge_actor_invalid", "Bridge participants must be different actors")
    }
    if (!Number.isInteger(input.maxTurns) || input.maxTurns < 1 || input.maxTurns > AGORA_LIMITS.maxBridgeTurns) {
      throw new AgoraStoreError(
        "invalid_limit",
        `Bridge max_turns must be 1...${AGORA_LIMITS.maxBridgeTurns}`,
        { limit: AGORA_LIMITS.maxBridgeTurns },
      )
    }

    let rateTimestamp: { actorId: string; now: number } | null = null
    const result = this.transaction(() => {
      const room = this.requireRoom(roomId)
      if (!room.isEnabled) throw new AgoraStoreError("room_disabled", `Agora room is disabled: ${room.id}`)
      const owner = this.actorByExternalKey(AGORA_OWNER_EXTERNAL_KEY)
      if (!owner || owner.id !== room.ownerActorId) {
        throw new AgoraStoreError("not_room_owner", "Authenticated owner does not own room")
      }
      if (owner.disabledAtMs !== null) throw new AgoraStoreError("owner_disabled", "Agora owner actor is disabled")

      const existing = this.database.query<BridgeRow, [string, string]>(
        `SELECT ${BRIDGE_COLUMNS}
         FROM agora_bridges WHERE owner_actor_id = ? AND client_request_id = ?`,
      ).get(owner.id, clientRequestId)
      if (existing) {
        const bridge = bridgeFromRow(existing)
        const turn = this.database.query<BridgeTurnRow, [string, number]>(
          `SELECT ${BRIDGE_TURN_COLUMNS} FROM agora_bridge_turns WHERE bridge_id = ? AND turn_index = ?`,
        ).get(bridge.id, 0)
        if (!turn) throw new Error(`Bridge ${bridge.id} has no initial turn`)
        const parsedTurn = bridgeTurnFromRow(turn)
        const message = this.messageById(parsedTurn.sourceMessageId)
        const mention = this.mentionById(parsedTurn.mentionId)
        if (!message || !mention) throw new Error(`Bridge ${bridge.id} has broken initial references`)
        return { bridge, currentTurn: this.currentBridgeTurn(bridge.id), turn: parsedTurn, message, mention, idempotent: true }
      }

      const active = this.database.query<CountRow, [string]>(
        "SELECT COUNT(*) AS count FROM agora_bridges WHERE room_id = ? AND status = 'active'",
      ).get(room.id)?.count ?? 0
      if (active > 0) {
        throw new AgoraStoreError("bridge_already_active", "This room already has an active bridge")
      }

      const firstMembership = this.membershipByActor(room.id, firstActorId)
      const secondMembership = this.membershipByActor(room.id, secondActorId)
      for (const membership of [firstMembership, secondMembership]) {
        if (!membership || membership.role !== "member" || membership.executorKind !== "cc_bridge") {
          throw new AgoraStoreError("bridge_actor_invalid", "Bridge participants must be agent members of the room")
        }
        const actor = this.actorById(membership.actorId)
        if (!membership.isEnabled || !actor || actor.disabledAtMs !== null) {
          throw new AgoraStoreError("bridge_actor_invalid", "Bridge participants must be enabled")
        }
      }

      const now = this.clock()
      this.enforceMessageRateLimit(owner.id, now)
      const seedContent = `@${firstMembership!.handle} ${prompt}`
      const message = this.insertMessage(room.id, owner.id, clientRequestId, seedContent, now)
      const mention = this.insertPendingMentions(room.id, message.id, [firstMembership!], now)[0]
      const bridge: AgoraBridge = {
        id: randomUUID(),
        roomId: room.id,
        ownerActorId: owner.id,
        clientRequestId,
        firstActorId,
        secondActorId,
        prompt,
        status: "active",
        maxTurns: input.maxTurns,
        turnsCompleted: 0,
        stopReason: null,
        lastError: null,
        createdAtMs: now,
        updatedAtMs: now,
        completedAtMs: null,
      }
      this.database.run(
        `INSERT INTO agora_bridges(
           id, room_id, owner_actor_id, client_request_id, first_actor_id, second_actor_id,
           prompt, status, max_turns, turns_completed, stop_reason, last_error,
           created_at_ms, updated_at_ms, completed_at_ms
         ) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, 0, NULL, NULL, ?, ?, NULL)`,
        [
          bridge.id, bridge.roomId, bridge.ownerActorId, bridge.clientRequestId,
          bridge.firstActorId, bridge.secondActorId, bridge.prompt, bridge.maxTurns,
          bridge.createdAtMs, bridge.updatedAtMs,
        ],
      )
      const turn: AgoraBridgeTurn = {
        id: randomUUID(),
        bridgeId: bridge.id,
        turnIndex: 0,
        sourceMessageId: message.id,
        mentionId: mention.id,
        expectedActorId: firstActorId,
        replyMessageId: null,
        state: "pending",
        error: null,
        createdAtMs: now,
        claimedAtMs: null,
        completedAtMs: null,
      }
      this.insertBridgeTurn(turn)
      rateTimestamp = { actorId: owner.id, now }
      return { bridge, currentTurn: turn, turn, message, mention, idempotent: false }
    })
    if (rateTimestamp) {
      const recent = this.messageRateTimestamps.get(rateTimestamp.actorId) ?? []
      recent.push(rateTimestamp.now)
      this.messageRateTimestamps.set(rateTimestamp.actorId, recent)
    }
    return result
  }

  private insertBridgeTurn(turn: AgoraBridgeTurn): void {
    this.database.run(
      `INSERT INTO agora_bridge_turns(
         id, bridge_id, turn_index, source_message_id, mention_id, expected_actor_id,
         reply_message_id, state, error, created_at_ms, claimed_at_ms, completed_at_ms
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        turn.id, turn.bridgeId, turn.turnIndex, turn.sourceMessageId, turn.mentionId,
        turn.expectedActorId, turn.replyMessageId, turn.state, turn.error, turn.createdAtMs,
        turn.claimedAtMs, turn.completedAtMs,
      ],
    )
  }

  stopBridge(bridgeId: string, ownerActorId: string): AgoraBridgeStopResult {
    const validBridgeId = requireUuid(bridgeId)
    const validOwnerActorId = requireUuid(ownerActorId)
    return this.transaction(() => {
      const bridge = this.bridgeById(validBridgeId)
      if (!bridge) throw new AgoraStoreError("bridge_not_found", `Agora bridge not found: ${validBridgeId}`)
      const room = this.requireRoom(bridge.roomId)
      if (room.ownerActorId !== validOwnerActorId || bridge.ownerActorId !== validOwnerActorId) {
        throw new AgoraStoreError("not_room_owner", "Only the room owner can stop a bridge")
      }
      if (bridge.status === "stopped") {
        return { ...this.getBridgeState(bridge.id), stoppedMentions: [], idempotent: true }
      }
      if (bridge.status !== "active") {
        throw new AgoraStoreError("bridge_not_active", `Bridge is ${bridge.status}`, { state: bridge.status })
      }
      const turns = this.database.query<BridgeTurnRow, [string]>(
        `SELECT ${BRIDGE_TURN_COLUMNS}
         FROM agora_bridge_turns WHERE bridge_id = ? AND state IN ('pending', 'claimed')`,
      ).all(bridge.id).map(bridgeTurnFromRow)
      const now = this.clock()
      this.database.run(
        `UPDATE agora_bridges
         SET status = 'stopped', stop_reason = 'user_stopped', updated_at_ms = ?, completed_at_ms = ?
         WHERE id = ? AND status = 'active'`,
        [now, now, bridge.id],
      )
      this.database.run(
        `UPDATE agora_bridge_turns
         SET state = 'cancelled', error = 'bridge stopped', completed_at_ms = ?
         WHERE bridge_id = ? AND state IN ('pending', 'claimed')`,
        [now, bridge.id],
      )
      const stoppedMentions: AgoraMention[] = []
      for (const turn of turns) {
        this.database.run(
          `UPDATE agora_mentions
           SET state = 'failed', claim_token_hash = NULL, claimed_at_ms = NULL,
               lease_expires_at_ms = NULL, last_error = 'bridge stopped'
           WHERE id = ? AND state IN ('pending', 'claimed')`,
          [turn.mentionId],
        )
        stoppedMentions.push(this.requireMention(turn.mentionId))
      }
      return { ...this.getBridgeState(bridge.id), stoppedMentions, idempotent: false }
    })
  }

  private dispatchForMention(mention: AgoraMention): AgoraMentionDispatch {
    const sourceMessage = this.messageById(mention.sourceMessageId)
    const targetMembership = this.membershipById(mention.targetMembershipId)
    const room = this.roomById(mention.roomId)
    if (!sourceMessage || !targetMembership || !room) {
      throw new Error(`Canonical Agora references missing for mention ${mention.id}`)
    }
    const targetActor = this.actorById(targetMembership.actorId)
    if (!targetActor) throw new Error(`Canonical Agora actor missing for mention ${mention.id}`)
    return { mention, sourceMessage, targetMembership, targetActor, room }
  }

  private claimPendingMention(mentionId: string, leaseMs: number): AgoraClaimResult {
    const mention = this.requireMention(mentionId)
    if (mention.state !== "pending") {
      throw new AgoraStoreError("mention_not_pending", `Mention is ${mention.state}`, { state: mention.state })
    }
    const dispatch = this.dispatchForMention(mention)
    if (!dispatch.room.isEnabled) throw new AgoraStoreError("room_disabled", "Cannot claim mention from disabled room")
    if (!dispatch.targetMembership.isEnabled) {
      throw new AgoraStoreError("membership_disabled", "Cannot claim disabled target membership")
    }
    if (dispatch.targetActor.disabledAtMs !== null) {
      throw new AgoraStoreError("actor_disabled", "Cannot claim disabled target actor")
    }
    const bridgeTurn = this.bridgeTurnByMention(mention.id)
    if (bridgeTurn) {
      const bridge = this.bridgeById(bridgeTurn.bridgeId)
      if (!bridge || bridge.status !== "active") {
        throw new AgoraStoreError("bridge_not_active", `Bridge is ${bridge?.status ?? "missing"}`)
      }
      if (
        bridgeTurn.state !== "pending"
        || bridgeTurn.turnIndex !== bridge.turnsCompleted
        || bridgeTurn.expectedActorId !== dispatch.targetActor.id
      ) {
        throw new AgoraStoreError("bridge_turn_mismatch", "Mention is not the active expected bridge turn")
      }
    }
    const active = this.database.query<CountRow, [string]>(
      `SELECT COUNT(*) AS count
       FROM agora_mentions mention
       JOIN agora_memberships membership ON membership.id = mention.target_membership_id
       WHERE mention.state = 'claimed' AND membership.actor_id = ?`,
    ).get(dispatch.targetActor.id)?.count ?? 0
    if (active > 0) {
      throw new AgoraStoreError(
        "mention_already_claimed_for_actor",
        `CC actor already has an active claimed mention: ${dispatch.targetActor.id}`,
      )
    }
    if (!Number.isFinite(leaseMs) || leaseMs <= 0) {
      throw new AgoraStoreError("invalid_limit", "Claim lease must be positive")
    }
    const now = this.clock()
    const claimToken = randomBytes(32).toString("base64url")
    this.database.run(
      `UPDATE agora_mentions
       SET state = 'claimed', claim_token_hash = ?, claimed_at_ms = ?, lease_expires_at_ms = ?, last_error = NULL
       WHERE id = ? AND state = 'pending'`,
      [hashClaimToken(claimToken), now, now + leaseMs, mention.id],
    )
    const claimed = this.requireMention(mention.id)
    if (bridgeTurn) {
      this.database.run(
        `UPDATE agora_bridge_turns SET state = 'claimed', claimed_at_ms = ?
         WHERE id = ? AND state = 'pending'`,
        [now, bridgeTurn.id],
      )
    }
    return { ...this.dispatchForMention(claimed), claimToken }
  }

  claimMention(mentionId: string, leaseMs: number = AGORA_LIMITS.claimLeaseMs): AgoraClaimResult {
    return this.transaction(() => this.claimPendingMention(mentionId, leaseMs))
  }

  claimNextMentionForSession(
    sessionName: string,
    leaseMs: number = AGORA_LIMITS.claimLeaseMs,
    gatedRoomIds: readonly string[] = [],
  ): AgoraClaimResult | null {
    const validSession = requireSessionName(sessionName)
    return this.transaction(() => {
      const actor = this.actorByExternalKey(`cc-session:${validSession}`)
      if (!actor || actor.disabledAtMs !== null) return null
      const active = this.database.query<CountRow, [string]>(
        `SELECT COUNT(*) AS count
         FROM agora_mentions mention
         JOIN agora_memberships membership ON membership.id = mention.target_membership_id
         WHERE mention.state = 'claimed' AND membership.actor_id = ?`,
      ).get(actor.id)?.count ?? 0
      if (active > 0) return null
      // 发言闸：被闸房间内只闸 observe / 接力（depth>0），owner 直接 @（depth=0 direct）豁免。
      const gateClause = gatedRoomIds.length > 0
        ? `AND NOT (mention.room_id IN (${gatedRoomIds.map(() => "?").join(", ")})
             AND (mention.kind = 'observe' OR mention.depth > 0))`
        : ""
      const row = this.database.query<{ id: string }, string[]>(
        `SELECT mention.id
         FROM agora_mentions mention
         JOIN agora_memberships membership ON membership.id = mention.target_membership_id
         JOIN agora_rooms room ON room.id = mention.room_id
         JOIN agora_messages source ON source.id = mention.source_message_id
         WHERE mention.state = 'pending'
           AND membership.actor_id = ?
           AND membership.is_enabled = 1
           AND room.is_enabled = 1
           ${gateClause}
         ORDER BY CASE mention.kind WHEN 'direct' THEN 0 ELSE 1 END,
           mention.created_at_ms, source.seq, mention.id
         LIMIT 1`,
      ).get(actor.id, ...gatedRoomIds)
      return row ? this.claimPendingMention(row.id, leaseMs) : null
    })
  }

  completeMention(mentionId: string, plainClaimToken: string, content: string): AgoraMessageWriteResult {
    const tokenHash = hashClaimToken(plainClaimToken)
    let rateTimestamp: { actorId: string; now: number } | null = null
    const write = this.transaction(() => {
      const mention = this.requireMention(mentionId)
      const storedHash = this.mentionTokenHash(mention.id)
      // resultMessageId null = 已 pass 的 observe，complete 重试不算幂等命中，落到下面 mention_not_claimed。
      if (mention.state === "completed" && storedHash === tokenHash && mention.resultMessageId) {
        const result = this.messageById(mention.resultMessageId)
        if (!result) throw new Error(`Completed mention ${mention.id} result message is missing`)
        return { message: result, mentions: this.listMentionsForMessage(result.id), idempotent: true }
      }
      if (mention.state !== "claimed") {
        throw new AgoraStoreError("mention_not_claimed", `Mention is ${mention.state}`, { state: mention.state })
      }
      if (!storedHash || storedHash !== tokenHash) {
        throw new AgoraStoreError("claim_token_invalid", "Claim token does not match mention")
      }
      const now = this.clock()
      if (mention.leaseExpiresAtMs === null || mention.leaseExpiresAtMs <= now) {
        throw new AgoraStoreError("claim_lease_expired", "Claim lease has expired")
      }
      const dispatch = this.dispatchForMention(mention)
      if (!dispatch.room.isEnabled) throw new AgoraStoreError("room_disabled", "Cannot complete mention in disabled room")
      if (!dispatch.targetMembership.isEnabled) {
        throw new AgoraStoreError("membership_disabled", "Target membership is disabled")
      }
      if (dispatch.targetActor.disabledAtMs !== null) {
        throw new AgoraStoreError("actor_disabled", "Target actor is disabled")
      }

      const bridgeTurn = this.bridgeTurnByMention(mention.id)
      const bridge = bridgeTurn ? this.bridgeById(bridgeTurn.bridgeId) : null
      if (bridgeTurn) {
        if (!bridge || bridge.status !== "active") {
          throw new AgoraStoreError("bridge_not_active", `Bridge is ${bridge?.status ?? "missing"}`)
        }
        if (
          bridgeTurn.state !== "claimed"
          || bridgeTurn.turnIndex !== bridge.turnsCompleted
          || bridgeTurn.expectedActorId !== dispatch.targetActor.id
        ) {
          throw new AgoraStoreError("bridge_turn_mismatch", "Reply does not match the active expected bridge turn")
        }
      }

      const validContent = requireMessageContent(content)
      // 发言模式派发矩阵（07-21 粟粟拍"两个都做"）：
      // - @owner 的 mention 任何档都生成（无执行器，离线推送靠它）
      // - @AI 只在 relay/free 档且链深未到闸时派发（老"一跳接力"守卫退役，depth 闸接管防 ping-pong）
      // - free 档再给其余成员发 observe（可 pass 沉默；沉默不产生消息，链自然断）
      const mode = this.getSpeechMode()
      const nextDepth = mention.depth + 1
      const withinDepth = nextDepth <= AGORA_LIMITS.maxChainDepth
      const resolvedTargets = bridgeTurn
        ? []
        : this.resolveMentionTargets(dispatch.room.id, dispatch.targetActor.id, validContent)
      const ownerTargets = resolvedTargets
        .filter(target => this.actorById(target.actorId)?.kind !== "cc_bridge")
      // round_robin 不接力：AI 回复里的 @AI 不生成链式 direct，也没有 observe fanout，只按圈推进。
      const ccTargets = ((mode === "relay" || mode === "free") && withinDepth)
        ? resolvedTargets.filter(target => this.actorById(target.actorId)?.kind === "cc_bridge")
        : []
      let observeTargets: AgoraMembership[] = []
      if (!bridgeTurn && mode === "free" && withinDepth) {
        const exclude = new Set([dispatch.targetActor.id, ...ccTargets.map(target => target.actorId)])
        observeTargets = this.observeCandidates(dispatch.room.id, exclude)
      }
      this.enforceMessageRateLimit(dispatch.targetActor.id, now)
      const superseded = this.replacePendingObserves(dispatch.room.id, [...ccTargets, ...observeTargets])
      const message = this.insertMessage(
        dispatch.room.id,
        dispatch.targetActor.id,
        `mention:${mention.id}`,
        validContent,
        now,
      )
      const newMentions = [
        ...this.insertPendingMentions(dispatch.room.id, message.id, [...ownerTargets, ...ccTargets], now, "direct", nextDepth),
        ...this.insertPendingMentions(dispatch.room.id, message.id, observeTargets, now, "observe", nextDepth),
      ]
      if (!bridgeTurn && mode === "round_robin" && mention.kind === "direct" && mention.depth === 0) {
        newMentions.push(...this.advanceRoundRobin(dispatch.room.id, dispatch.targetActor.id, message.id, now))
      }
      const result = this.database.run(
        `UPDATE agora_mentions
         SET state = 'completed', completed_at_ms = ?, result_message_id = ?
         WHERE id = ? AND state = 'claimed' AND claim_token_hash = ?`,
        [now, message.id, mention.id, tokenHash],
      )
      if (result.changes !== 1) throw new AgoraStoreError("claim_token_invalid", "Claim changed before completion")
      let bridgeUpdate: AgoraMessageWriteResult["bridgeUpdate"]
      if (bridgeTurn && bridge) {
        this.database.run(
          `UPDATE agora_bridge_turns
           SET state = 'completed', reply_message_id = ?, completed_at_ms = ?, error = NULL
           WHERE id = ? AND state = 'claimed'`,
          [message.id, now, bridgeTurn.id],
        )
        const completedTurn = this.bridgeTurnByMention(mention.id)
        if (!completedTurn) throw new Error(`Bridge turn disappeared for mention ${mention.id}`)
        const turnsCompleted = bridge.turnsCompleted + 1
        let nextMention: AgoraMention | null = null
        let currentTurn: AgoraBridgeTurn | null = null
        let event: "advanced" | "completed" | "failed"
        if (turnsCompleted >= bridge.maxTurns) {
          this.database.run(
            `UPDATE agora_bridges
             SET status = 'completed', turns_completed = ?, stop_reason = 'max_turns_reached',
                 updated_at_ms = ?, completed_at_ms = ?, last_error = NULL
             WHERE id = ? AND status = 'active'`,
            [turnsCompleted, now, now, bridge.id],
          )
          event = "completed"
        } else {
          const nextActorId = dispatch.targetActor.id === bridge.firstActorId
            ? bridge.secondActorId
            : bridge.firstActorId
          const nextMembership = this.membershipByActor(dispatch.room.id, nextActorId)
          const nextActor = this.actorById(nextActorId)
          if (!nextMembership || !nextMembership.isEnabled || !nextActor || nextActor.disabledAtMs !== null) {
            const failure = "next bridge actor is unavailable"
            this.database.run(
              `UPDATE agora_bridges
               SET status = 'failed', turns_completed = ?, stop_reason = 'actor_unavailable',
                   last_error = ?, updated_at_ms = ?, completed_at_ms = ?
               WHERE id = ? AND status = 'active'`,
              [turnsCompleted, failure, now, now, bridge.id],
            )
            event = "failed"
          } else {
            nextMention = this.insertPendingMentions(dispatch.room.id, message.id, [nextMembership], now)[0]
            currentTurn = {
              id: randomUUID(),
              bridgeId: bridge.id,
              turnIndex: turnsCompleted,
              sourceMessageId: message.id,
              mentionId: nextMention.id,
              expectedActorId: nextActorId,
              replyMessageId: null,
              state: "pending",
              error: null,
              createdAtMs: now,
              claimedAtMs: null,
              completedAtMs: null,
            }
            this.insertBridgeTurn(currentTurn)
            this.database.run(
              `UPDATE agora_bridges
               SET turns_completed = ?, updated_at_ms = ?, last_error = NULL
               WHERE id = ? AND status = 'active'`,
              [turnsCompleted, now, bridge.id],
            )
            event = "advanced"
          }
        }
        const updatedBridge = this.bridgeById(bridge.id)
        if (!updatedBridge) throw new Error(`Bridge disappeared after turn completion: ${bridge.id}`)
        if (nextMention) newMentions.push(nextMention)
        bridgeUpdate = { event, bridge: updatedBridge, currentTurn, completedTurn, nextMention }
      }
      rateTimestamp = { actorId: dispatch.targetActor.id, now }
      return { message, mentions: newMentions, idempotent: false, bridgeUpdate, supersededMentions: superseded }
    })
    if (rateTimestamp) {
      const recent = this.messageRateTimestamps.get(rateTimestamp.actorId) ?? []
      recent.push(rateTimestamp.now)
      this.messageRateTimestamps.set(rateTimestamp.actorId, recent)
    }
    return write
  }

  /// observe 沉默：completed + result_message_id NULL，不插消息、不烧限速额度。
  /// direct（被显式 @）必答，pass 直接拒绝。
  passMention(mentionId: string, plainClaimToken: string): AgoraPassResult {
    const tokenHash = hashClaimToken(plainClaimToken)
    return this.transaction(() => {
      const mention = this.requireMention(mentionId)
      const storedHash = this.mentionTokenHash(mention.id)
      if (mention.state === "completed" && mention.resultMessageId === null && storedHash === tokenHash) {
        return { mention, idempotent: true }
      }
      // round_robin 的轮次点名（depth 0 direct，非 bridge 轮次）可 pass 跳过；其余 direct 仍必答。
      const roundRobinTurn = mention.kind === "direct"
        && mention.depth === 0
        && this.getSpeechMode() === "round_robin"
        && !this.bridgeTurnByMention(mention.id)
      if (mention.kind !== "observe" && !roundRobinTurn) {
        throw new AgoraStoreError("pass_not_allowed", "Direct mentions must be answered; only observe mentions can be passed")
      }
      if (mention.state !== "claimed") {
        throw new AgoraStoreError("mention_not_claimed", `Mention is ${mention.state}`, { state: mention.state })
      }
      if (!storedHash || storedHash !== tokenHash) {
        throw new AgoraStoreError("claim_token_invalid", "Claim token does not match mention")
      }
      const now = this.clock()
      if (mention.leaseExpiresAtMs === null || mention.leaseExpiresAtMs <= now) {
        throw new AgoraStoreError("claim_lease_expired", "Claim lease has expired")
      }
      const result = this.database.run(
        `UPDATE agora_mentions
         SET state = 'completed', completed_at_ms = ?, result_message_id = NULL
         WHERE id = ? AND state = 'claimed' AND claim_token_hash = ?`,
        [now, mention.id, tokenHash],
      )
      if (result.changes !== 1) throw new AgoraStoreError("claim_token_invalid", "Claim changed before completion")
      let mentions: AgoraMention[] = []
      if (roundRobinTurn) {
        // pass 不产生消息：下一位的轮次点名挂回本 mention 的源消息。
        const membership = this.membershipById(mention.targetMembershipId)
        if (membership) {
          mentions = this.advanceRoundRobin(mention.roomId, membership.actorId, mention.sourceMessageId, now)
        }
      }
      return { mention: this.requireMention(mention.id), idempotent: false, mentions }
    })
  }

  recoverExpiredClaims(nowMs = this.clock()): AgoraMention[] {
    return this.transaction(() => {
      const expired = this.database.query<MentionRow, [number]>(
        `SELECT ${MENTION_COLUMNS}
         FROM agora_mentions
         WHERE state = 'claimed' AND lease_expires_at_ms <= ?
         ORDER BY lease_expires_at_ms, id`,
      ).all(nowMs).map(mentionFromRow)
      const recovered: AgoraMention[] = []
      for (const mention of expired) {
        const attempts = mention.attemptCount + 1
        const failed = attempts > AGORA_LIMITS.maxMentionAttempts
        this.database.run(
          `UPDATE agora_mentions
           SET state = ?, claim_token_hash = NULL, claimed_at_ms = NULL,
               lease_expires_at_ms = NULL, attempt_count = ?, last_error = ?
           WHERE id = ? AND state = 'claimed'`,
          [
            failed ? "failed" : "pending",
            attempts,
            failed ? "claim lease expired too many times" : "claim lease expired",
            mention.id,
          ],
        )
        this.updateBridgeAfterMentionFailure(
          mention.id,
          failed ? "claim lease expired too many times" : "claim lease expired",
          failed,
          nowMs,
        )
        recovered.push(this.requireMention(mention.id))
      }
      return recovered
    })
  }

  releaseClaimAfterFailure(mentionId: string, plainClaimToken: string, error: string): AgoraMention {
    const tokenHash = hashClaimToken(plainClaimToken)
    return this.transaction(() => {
      const mention = this.requireMention(mentionId)
      if (mention.state !== "claimed") {
        throw new AgoraStoreError("mention_not_claimed", `Mention is ${mention.state}`, { state: mention.state })
      }
      if (this.mentionTokenHash(mention.id) !== tokenHash) {
        throw new AgoraStoreError("claim_token_invalid", "Claim token does not match mention")
      }
      const attempts = mention.attemptCount + 1
      const failed = attempts > AGORA_LIMITS.maxMentionAttempts
      this.database.run(
        `UPDATE agora_mentions
         SET state = ?, claim_token_hash = NULL, claimed_at_ms = NULL,
             lease_expires_at_ms = NULL, attempt_count = ?, last_error = ?
         WHERE id = ? AND state = 'claimed' AND claim_token_hash = ?`,
        [failed ? "failed" : "pending", attempts, conciseError(error), mention.id, tokenHash],
      )
      this.updateBridgeAfterMentionFailure(mention.id, error, failed, this.clock())
      return this.requireMention(mention.id)
    })
  }

  failMention(mentionId: string, error: string): AgoraMention {
    return this.transaction(() => {
      const mention = this.requireMention(mentionId)
      if (mention.state === "completed") {
        throw new AgoraStoreError("mention_not_pending", "Completed mention cannot be failed")
      }
      this.database.run(
        `UPDATE agora_mentions
         SET state = 'failed', claim_token_hash = NULL, claimed_at_ms = NULL,
             lease_expires_at_ms = NULL, last_error = ?
         WHERE id = ?`,
        [conciseError(error), mention.id],
      )
      this.updateBridgeAfterMentionFailure(mention.id, error, true, this.clock())
      return this.requireMention(mention.id)
    })
  }

  retryFailedMention(mentionId: string, ownerActorId: string): AgoraMention {
    return this.transaction(() => {
      const mention = this.requireMention(mentionId)
      const owner = this.requireActor(ownerActorId)
      const room = this.requireRoom(mention.roomId)
      if (room.ownerActorId !== owner.id || owner.externalKey !== AGORA_OWNER_EXTERNAL_KEY) {
        throw new AgoraStoreError("not_room_owner", "Only the room owner can retry a failed mention")
      }
      if (owner.disabledAtMs !== null) throw new AgoraStoreError("owner_disabled", "Agora owner actor is disabled")
      if (mention.state !== "failed") {
        throw new AgoraStoreError("mention_not_failed", `Mention is ${mention.state}`, { state: mention.state })
      }
      if (this.bridgeTurnByMention(mention.id)) {
        throw new AgoraStoreError("bridge_not_active", "Failed bridge turns cannot be retried independently")
      }
      this.database.run("UPDATE agora_mentions SET state = 'pending' WHERE id = ? AND state = 'failed'", [mention.id])
      return this.requireMention(mention.id)
    })
  }

  private updateBridgeAfterMentionFailure(
    mentionId: string,
    error: string,
    terminal: boolean,
    now: number,
  ): void {
    const turn = this.bridgeTurnByMention(mentionId)
    if (!turn) return
    const bridge = this.bridgeById(turn.bridgeId)
    if (!bridge || bridge.status !== "active") return
    const message = conciseError(error)
    if (terminal) {
      this.database.run(
        `UPDATE agora_bridge_turns
         SET state = 'failed', error = ?, completed_at_ms = ?
         WHERE id = ? AND state IN ('pending', 'claimed')`,
        [message, now, turn.id],
      )
      this.database.run(
        `UPDATE agora_bridges
         SET status = 'failed', stop_reason = 'executor_failure', last_error = ?,
             updated_at_ms = ?, completed_at_ms = ?
         WHERE id = ? AND status = 'active'`,
        [message, now, now, bridge.id],
      )
      return
    }
    this.database.run(
      `UPDATE agora_bridge_turns
       SET state = 'pending', claimed_at_ms = NULL, error = ?
       WHERE id = ? AND state = 'claimed'`,
      [message, turn.id],
    )
    this.database.run(
      "UPDATE agora_bridges SET last_error = ?, updated_at_ms = ? WHERE id = ? AND status = 'active'",
      [message, now, bridge.id],
    )
  }
}
