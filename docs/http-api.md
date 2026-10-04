# Yamaha YAS-207 Controller — HTTP API

Generic public API documentation for the controller. This describes the HTTP
interface as implemented by `control/control.rb` and exposed by the running
controller process. Installation-specific details (base URL, binding,
authentication, deployment paths) are intentionally omitted — configure
`controller.http_bind` and `controller.http_port` in your config.

## Basics

- **Server:** WEBrick, running in a thread inside the controller process
  (`ruby control/control.rb`).
- **Request convention:** POSTs use `application/x-www-form-urlencoded`
  bodies. JSON values (intents) are passed as the *value* of a form field,
  not as a JSON request body.
- **Caveat on HTTP status:** the mounted handlers rescue their own errors
  and always answer HTTP 200 with a text body. A failed request looks like
  `200` with a body such as `failed to send intent ...: ...`. **Always
  inspect the response body, not just the status code.** (A 404/500 only
  occurs for non-mounted paths that fall through to WEBrick's error
  handler, or protocol-level failures.)

## Endpoint summary

| Path | Method | Purpose |
|---|---|---|
| `/state` | GET | Authoritative device + session state (JSON) |
| `/send` | POST | Send raw data, named commands, or a **partial intent** |
| `/start-session` | POST | Begin a named session (snapshot + optional wake + intent) |
| `/stop-session` | POST | End a named session (staged restore of the snapshot) |
| `/` | GET | Human state page (HTML, or JSON with `?json`) |

WEBrick longest-prefix matching means **any unmounted path (e.g.
`/status`) falls through to the `/` handler** and returns the same state
page. This is an accidental alias, not a separate endpoint. Prefer `/state`.

## GET /state

- **Purpose:** read the controller's current view of the device and the
  session model. This is the authoritative read used by every tool.
- **Request:** none.
- **Response:** `application/json; charset=utf-8` (pretty-printed):

```json
{
  "device_state": {
    "power": false,
    "input": "tv",
    "mute": false,
    "volume": 16,
    "subwoofer": 16,
    "surround": "3d",
    "bass_ext": true,
    "clearvoice": true
  },
  "session": {
    "name": null,
    "active": false,
    "restoring": false,
    "restore_phase": null,
    "restore_error": null,
    "powered_on_by_session": false
  },
  "protocol": {
    "status_generation": 145,
    "volume_status_generation": 3
  }
}
```

- **Semantics:**
  - `device_state` reflects the last device status report received over
    SPP. The controller polls status every `status_refresh_seconds`
    (default: 30 s) and after every command it sends, so values are
    typically current within a few seconds; after a write, verify with a
    fresh `/state` read (tools poll for convergence).
  - `session.active` is true from `/start-session` until the staged
    restore after `/stop-session` has fully completed.
  - `session.restoring` / `restore_phase` / `restore_error` expose the
    staged-restore progress for diagnostics.
  - `powered_on_by_session` is true while a snapshot records that the
    active session powered the device on (restore will emit a final
    `power_off`).
  - `protocol.*_generation` counters increment on each device status
    reply — useful to prove the link is alive.
- **Errors:** none expected; the endpoint is a plain in-process read.

### `device_state` fields

| Field | Type | Domain / values |
|---|---|---|
| `power` | bool | on/off |
| `input` | string | `hdmi`, `analog`, `bluetooth`, `tv` |
| `mute` | bool | |
| `volume` | int | `0..50` (protocol maximum is 50) |
| `subwoofer` | int | `0, 4, 8, 12, 16, 20, 24, 28, 32` |
| `surround` | string | `stereo`, `tv`, `movie`, `music`, `sports`, `game`, `3d` |
| `bass_ext` | bool | |
| `clearvoice` | bool | |

## POST /send

- **Purpose:** send raw data, named commands, or a validated **partial
  intent** to the device.
- **Content type:** `application/x-www-form-urlencoded`.
- **Request body (exactly one of the three params):**

| Param | Format | Effect |
|---|---|---|
| `intent` | JSON object string | **Partial intent** — only the given fields are changed |
| `commands` | comma-separated command names | send named commands (e.g. `volume_up`) |
| `data` | comma-separated hex pairs | send raw bytes (expert use) |

- **Intent validation** (`parse_intent`): the intent must be a JSON object
  whose keys are a subset of the fields below, each within its domain:

| Field | Accepted values |
|---|---|
| `power` | `true` / `false` — **stripped and ignored when `controller.manage_power: false`**; never use it |
| `mute` | `true` / `false` |
| `bass_ext` | `true` / `false` |
| `clearvoice` | `true` / `false` |
| `input` | `"hdmi"`, `"analog"`, `"bluetooth"`, `"tv"` |
| `volume` | integer `0..50` |
| `subwoofer` | integer in `0,4,8,12,16,20,24,28,32` |
| `surround` | `"stereo"`, `"tv"`, `"movie"`, `"music"`, `"sports"`, `"game"`, `"3d"` |

  Any other key or out-of-domain value → rejected (response body:
  `failed to send intent ...: ... must be one of: ...`).

- **Partial semantics:** the intent is merged into the controller's pending
  intent; only the delta vs. the observed device state is written to the
  device. Unspecified fields are untouched.
- **Response:** `text/plain; charset=utf-8`.
  - Success: `send intent: {:surround=>:"3d", :subwoofer=>16, ...}.`
    (the resulting pending-intent hash, Ruby format)
  - Failure: `failed to send intent <input>: <reason>.` — reasons include
    `device not ready` (SPP not synced yet) and `session restore in
    progress` (all mutations are rejected while a staged restore runs).
- **Synchronous vs eventual:** the POST returns once the intent is
  **accepted and queued** — not when the device has applied it. The
  controller enforces the intent against subsequent device status
  reports (re-asserting deltas). **Callers must verify the result by
  reading `/state`** and polling until the fields converge. HTTP 200 +
  "send intent:" is not proof the Yamaha changed.

### Safe examples

Read state:

```sh
curl -fsS http://<controller>/state
```

Partial intent — canonical TV-reset profile (harmless when already in place):

```sh
curl -fsS -X POST --data-urlencode 'intent={"surround":"3d","subwoofer":16,"bass_ext":true,"clearvoice":true}' http://<controller>/send
# then verify:
curl -fsS http://<controller>/state
```

Single-field example (clear voice off):

```sh
curl -fsS -X POST --data-urlencode 'intent={"clearvoice":false}' http://<controller>/send
```

Do **not** send `power` (ignored when `manage_power=false`) and avoid
casual `input`/`volume` writes from manual probing — during a music
session, `volume` and `mute` belong to the player/adapter.

## POST /start-session

- **Purpose:** begin a named session: capture the pre-session snapshot,
  wake the YAS if it is off and `power_on_for_session_starts` is set
  (bounded 10 s wait for confirmed power-on), then apply the given intent.
- **Request:** form params `name` (string) and `intent` (JSON object
  string), same validation as `/send`.
- **Response (text/plain):** `start session: <pending-intent hash>.` or
  `failed to start session: <reason>.` (reasons include `device not
  ready`, `session restore in progress`, and `yamaha did not power on
  within 10s`).
- The `name` identifies the session for `/stop-session`.

## POST /stop-session

- **Purpose:** end a named session and run the **staged restore** of the
  exact pre-session snapshot. Order: `mute` → `volume` (closed-loop with
  bounded correction) → `sound` (clearvoice/surround/bass_ext/subwoofer) →
  `input` → `post_input_volume` re-verify → `final_mute` → `final_power`
  (last; `power_off` only if this session powered the device on).
- **Request:** form param `name`.
- **Response (text/plain):** `stop session: <hash>.` or
  `failed to stop session: <reason>.`
- The restore is asynchronous: `GET /state` shows
  `session.restoring=true` with `restore_phase` until it settles, then the
  snapshot file is deleted. While restoring, all `/send`,
  `/start-session`, `/stop-session` mutations are rejected with
  `session restore in progress`.

## Controller state model and `initial_intent`

- The controller keeps a pending **intent** (merged from
  `initial_intent`, manual `/send` intents, and session intents) and
  enforces it against observed device state, re-asserting deltas until
  convergence. The startup `initial_intent` is one-shot: it is merged at
  the first state sync after controller start / SPP reconnect and then
  consumed — it does not re-assert on later drift.
- **`controller.initial_intent` is tri-state:**
  - key absent → legacy upstream default intent applied at first sync,
    including the legacy SPP-wake side effect (`input=hdmi` + `power=false`
    when the device comes up on `bluetooth`);
  - key present as `{}` → true no-op: no initial intent is applied and the
    legacy SPP-wake side effect does **not** fire;
  - key present non-empty (production: the TV/Movie four-field profile) →
    validated and normalized **at config load** (symbol keys, domain-checked
    values; an invalid key/value/type fails controller startup with
    `ArgumentError`). At first sync it is applied **exactly as validated** —
    no `input`/`power` side effects.
- **Session / restore precedence:** when a live session, a recovered
  session, or an in-flight staged restore owns the device state, the
  `:initial` marker is dropped without merging — the startup intent can
  never overwrite a session snapshot or its restore.
- **Powered-off safety:** while the device reports `power=false` and
  `manage_power=false`, enforcement enqueues no sound-setting commands; the
  pending intent is deferred and converges once the device reports power-on.
  (`manage_power=true` keeps the legacy auto-power-on path.)
- **Session ownership:** during a session the snapshot (not the intent)
  is the source of truth for restore. The adapter owns `volume`/`mute`
  while a session is active; the sound fields come from
  `session.music_intent`.
- `idle_input_policy: "tv"` (if configured) only ever corrects
  `input=bluetooth` → `tv` while idle (powered on, no session, no
  restore, no pending intent); it is a guard against SPP-reconnect
  side effects, not a profile enforcer.