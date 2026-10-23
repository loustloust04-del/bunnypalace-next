import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
process.env.MP_CC_SECRETS_DIR ??= mkdtempSync(join(tmpdir(), "cc-bridge-test-secrets-"))
process.env.MP_CC_TMUX_DRY_RUN ??= "1"
process.env.MP_CC_WARROOM ??= "0"
