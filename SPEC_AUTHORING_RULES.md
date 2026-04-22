# Spec authoring rules — host doc (`CLEAN_ROOM_SPEC.md`)

**Status:** Normative for how this repository’s clean-room specification is written and revised.  
**Ties to:** SEP-027 (`~/.sep/SEP-027.md`) Phase 0 and strict one-shot definitions.  
**Chat-derived:** Consolidated from the specification effort thread (process failures, explicit user decisions, and corrections).

---

## Framing (normative)

This effort **adapts** the Claude Code **reference product** under strict SDLC constraints. It is **not** greenfield. The following apply together:

1. **Clean room (implementation).** The target codebase **must** satisfy the host spec and SEP-027 **as contracts**. The reference/leaked `claude-code` tree is **supporting material**—for tracing behavior, diffing, and labeling **reference behavior** vs **fork policy**—not an authority to copy unless the spec explicitly adopts a reference behavior. Implement **to the spec**, verify **against** reference where useful.

2. **Spec as diff.** Normative sections of the host doc state **deltas**: what **changes** (e.g. SQLite transactional substrate, hook-plane semantics, orchestration, providers). **Any behavior, UX, CLI flow, or surface not explicitly forked** in the host doc or SEP **defaults to parity** with the reference Claude Code product until an **explicit** open decision, deferral, or normative addition says otherwise. Silence means **unchanged vs reference**, not **absent** or **free to reinvent**.

3. **Spec as one-shot LLM guide.** For every topic the host doc treats as **normative**, the text must be **complete enough** that an implementer (including a one-shot LLM pass) **need not invent** missing shapes, policy, or algorithms (see §2). That completeness obligation applies **only** to what is claimed normative—not an excuse to redefine unspecified layers.

---

## 1. Authority and edits

1. The host spec is **not** a free-form design surface. Any change set to `CLEAN_ROOM_SPEC.md` (or successor host path) follows **SEP-027 Phase 0** for that change set.
2. **Phase 0 (mandatory):** one-sentence **goal** → numbered **plan** (each step names **files** and **sections**) → **open decisions** (or explicit `None`) → **stop** → user **Proceed** (or equivalent explicit execute signal) → **then** edit.
3. **Observations are not instructions.** If the user only notes a gap (“there is no UI here”), the agent **responds in prose only**—**no** repository edits unless the user then requests a change and approves execution.
4. **Proceed** authorizes **only** what appears in the approved plan, not opportunistic follow-on edits.

---

## 2. Strict one-shot (for the spec text)

1. A reader can implement **everything normative** in the host doc **without inferring** missing JSON shapes, enums, table columns, algorithms, or policy.
2. **Forbidden** in normative sections unless reconciled per SEP-027 D1: ellipses (`…`), “see file” without a **generated** artifact or locked pointer, and open-ended “implementation-defined” **without a closed allowed set** written in the spec.
3. **Reference vs fork:** Behavior traced from the reference `claude-code` tree is labeled **reference behavior**; deliberate changes are labeled **fork policy**. Do not blend the two without labeling.

---

## 3. Substance already required in the host doc

1. **Single SQLite database** for all **transactional** agent state (per the host doc’s definition). **No** session JSONL (or equivalent) as **authoritative** store; **no** directory/plan-path scans for **authoritative** plan text.
2. **Hook plane:** **sequential** execution, **total** hook order, **deterministic** merge rules; **no** normative async hook control path for the SDLC profile.
3. **Orchestration is core:** provider selection, credentials policy, and the agent turn loop are **in scope** and **normative**, not dismissed as “model APIs out of scope.”
4. **Providers (closed enum):** `claude_code_subscription`, `openai_compatible`, `lm_studio_local` — exact strings as frozen in the host doc.
5. **Model identifiers:** **per-provider enums** with **explicit** wire mapping tables; not a single global opaque model string for all backends.
6. **Secrets:** credentials and equivalent **only** via **environment variables**; **forbidden** in SQLite, `settings_snapshot`, hook stdin, and transcript payloads.

---

## 4. Reference product and UX (clarifications)

1. **Framing (above) is authoritative** for clean-room meaning, spec-as-diff, and default parity with Claude Code.
2. **“Use case”** includes **operator experience**. If the user **intentionally** narrows scope (e.g. defers CLI normative text to a named phase), record that in the host doc or SEP as an **explicit** deferral—not as silence.
3. Do **not** describe unspecified areas as an “evolved non-goal.” If something is **not** yet normative but parity is waived, say so as an **open decision** or **fork**; otherwise **default parity** applies (**Spec as diff**, Framing).

---

## 5. Meta-rules (honesty about gaps)

1. Do **not** retrofit narrative to explain omissions (e.g. claiming UI was “out of scope by design” when it was never explicitly settled).
2. If a layer is unspecified, the host doc or SEP should record **why** (open decision, deferred phase) rather than silence.

---

## 6. Style and language

1. **English** for normative spec text unless the user requests another language.
2. **Answer the user’s message** before mutating files.
3. **Chunk execution:** after a Proceed batch, report what changed; avoid scope creep inside one approval.

---

## 7. Acceptance bar

1. Hook stdin/stdout appendices meet **SEP-027** Phases 1–2 and acceptance criteria (exhaustive where claimed; no undocumented variants).
2. **D1–D4** in SEP-027 are **filled** or deferred with a **single** follow-up SEP ID.
3. Future edits to the host doc **always** use Phase 0 + explicit Proceed so the spec does not become a transcript of unprompted agent design.

---

*This file is the canonical authoring contract for the host spec. SEP-027 remains the phased delivery and open-decision log.*
