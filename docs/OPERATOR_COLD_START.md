# Operator cold start — SDLC clean-room (one-shot deployment)

Numbered steps from clean checkout to **verified** first use. Per **CLEAN_ROOM_SPEC.md** Appendix **F.3** (≤ 12 steps).

1. Check out the **implementation root** that ships the agent (the tree containing `bin/agent.mjs` and `scripts/sdlc-acceptance.sh`).

2. Install runtime prerequisites: **Node.js**, **sqlite3** CLI, and (for LM Studio routing) **Python 3** if your CI uses the acceptance harness mock.

3. Build or copy the agent entrypoint so **`bin/agent.mjs`** exists and is executable via `node`.

4. Start your local model backend (e.g. **LM Studio**) and load **Qwen 2.5** (or the model id your `lm_studio_local` profile uses).

5. Export the agent and database (adjust paths to your machine):

   ```bash
   export ONA="$PWD/bin/agent.mjs"
   export AGENT_SDLC_DB="${AGENT_SDLC_DB:-$PWD/.agent_sdlc.db}"
   ```

6. Export OpenAI-compatible endpoint and model id for LM Studio (names must match your build):

   ```bash
   export LM_STUDIO_BASE_URL="http://127.0.0.1:1234/v1"
   export LM_STUDIO_MODEL="<your-qwen-2.5-model-id>"
   ```

7. Run **full clean-room acceptance** (required for one-shot sign-off; must exit **0**):

   ```bash
   ./scripts/sdlc-acceptance.sh
   ```

   This script includes **ROW-90** (§8.1): phase enum is checked as **distinct `conversations.phase` values in `AGENT_SDLC_DB`** — part of the **same** automated matrix as the other rows. REPL launch, default model, and first-turn behavior are covered by the matrix rows implemented in **`scripts/sdlc-acceptance.sh`** — **do not** add parallel ad-hoc acceptance scripts (see **CLEAN_ROOM_SPEC.md** Appendix **F.1**).

8. For interactive use, start the REPL with the same environment as in steps 5–6 (e.g. `node "$PWD/bin/agent.mjs"`).

---

**DELIVERED predicate:** Appendix **F** requires this file, **`scripts/sdlc-acceptance.sh` exit 0**, and **`docs/ACCEPTANCE_MATRIX.md`** with closed PASS criteria. Extend the matrix with any additional rows your process requires before claiming delivery.
