---
name: imagen-skill
description: Generate images from text prompts through the ToAPIs async image API (gpt-image-2.5 / gpt-image-2). Use whenever the user asks to draw, render, generate, create, or imagine a picture/illustration/poster/photo/icon/mockup, or needs multiple images generated at once. Also applies to Chinese requests such as 生成图片、生成图像、画一张、画个、出图、做张海报、封面、壁纸、图标、插画、效果图、批量生成多张图。Handles parallel multi-image generation, downloads files to a local output directory, and reports the directory plus a per-image description.
---

# Imagen Skill

Text-to-image generation through ToAPIs. One command submits **N independent tasks in parallel**, polls them concurrently, downloads the finished PNGs, and prints the output directory plus each image's description.

## Platform note (Linux)

This skill is a pure **Node 18+** runner with an optional PowerShell front-end. On Linux (this machine) always call `scripts/imagen.mjs` directly with `node`:

- No `pwsh`/`powershell` is installed — ignore `scripts/imagen.ps1`, it only exists for the Windows box sharing this dotfiles tree.
- Runtime is `node` (verified: v24). No npm packages are required; the script uses global `fetch`.
- Text encoding is UTF-8 natively, so Chinese prompts, emoji and quotes need no special handling (the encoding workarounds in the `.ps1` are Windows-only).
- Paths follow POSIX conventions; pass absolute paths with `/`, never Windows `\` separators.

## When to use

- "generate/draw/render/create an image of ...", "make me a picture/poster/illustration/logo/icon"
- Any request needing several **independent** images (e.g. "one image per chapter", "5 variants")
- Not for editing an existing local file unless it is already reachable as a public URL.

## Quick start

Resolve the runner relative to this skill directory (`~/.pi/agent/skills/imagen/scripts/imagen.mjs`).

Single image:

```bash
node ~/.pi/agent/skills/imagen/scripts/imagen.mjs \
  --prompt "a glass teapot on marble, soft studio light" --name teapot
```

Multiple independent prompts (submitted concurrently):

```bash
node ~/.pi/agent/skills/imagen/scripts/imagen.mjs \
  --prompt "cyberpunk city at night, neon rain" --name cyber-city \
  --prompt "same city at sunrise, warm haze" --name cyber-dawn \
  --size 16:9 --resolution 2k --out ./generated-images/scene
```

Structured input, best when prompts are long or need per-image settings (no shell quoting problems at all):

```bash
node ~/.pi/agent/skills/imagen/scripts/imagen.mjs --json '[
  {"name":"cover","prompt":"...","size":"3:4","resolution":"2k"},
  {"name":"inset","prompt":"...","size":"1:1"}
]' --out ./generated-images/book
```

From a prompt file (one per line, optional `name :: prompt`), which avoids long argv entirely:

```bash
node ~/.pi/agent/skills/imagen/scripts/imagen.mjs --file ./prompts.txt --out ./generated-images/batch
```

Long Chinese prompts: single-quote them in bash. If a prompt contains single quotes, prefer `--json @prompts.json` or `--file` over fighting shell escaping.

## First-time setup on this machine

No API key is configured yet, and there is no `secrets/` directory. Create one **outside the dotfiles git repository** — `~/.pi/agent` is a symlink to `~/.dotfiles/pi/agent`, so a key stored under it can be committed by accident.

```bash
install -d -m 700 ~/.config/pi/secrets
umask 077
cat > ~/.config/pi/secrets/imagen.json <<'JSON'
{ "api_key": "sk-...", "base_url": "https://toapis.cn" }
JSON
chmod 600 ~/.config/pi/secrets/imagen.json
node ~/.pi/agent/skills/imagen/scripts/imagen.mjs --check   # expect HTTP 200
```

`--check` prints the resolved path, the masked key and the auth status, and generates nothing. An environment variable (`IMAGEN_API_KEY`) works too, but a file with mode `0600` is better than a secret sitting in shell history or a shell profile committed to the same repo.

## Workflow

1. **Clarify only what changes the image** — subject, style, aspect ratio, count. Do not stall on details you can infer; state assumptions in the final report.
2. **Write prompts as self-contained descriptions**: subject + composition + lighting + style + palette. The API does not read conversation history, so never send "the same but red" — restate the full scene.
3. **Decide dependencies**:
   - Independent prompts → one batch call, they run in parallel (this is the default and the fast path).
   - A prompt that *depends* on an earlier result (e.g. "now make it night") → run a second batch and put the first image's description back into the new prompt, or pass the returned URL via `--reference`. Never fire dependent prompts in the same batch.
4. **Run the script**, then relay the result to the user (see Reporting).
5. **Verify before reporting** — check the script's exit status and that each reported file exists and is non-trivial in size. If any task failed, say so explicitly instead of silently dropping it.

## API facts (already validated — do not re-discover)

| Item | Value |
|---|---|
| Base URL | `https://toapis.cn` (also `https://api.toapis.cn`) |
| Auth | `Authorization: Bearer <api key>` |
| Submit | `POST /v1/images/generations` |
| Poll | `GET /v1/images/generations/{task_id}` |
| Mode | **Asynchronous task** — submit returns `{id, status:"pending", progress}` |
| Terminal states | `completed` (image at `result.data[].url`), `failed`, `canceled` |

Request parameters: `model`, `prompt`, `size`, `resolution`, `quality`, `background`, `reference_images` (public URLs only — no base64).

Critical constraints learned from live testing:

- **`n` is ignored.** One task always yields exactly one image. Generate N images by submitting N tasks in parallel — never loop sequentially, and never trust `n > 1`.
- **Concurrency defaults to 10.** More parallelism is faster until the account rate-limits; see `Rate limiting` below.
- **`size` is an aspect ratio, not pixels.** Use `1:1`, `16:9`, `9:16`, `3:2`, `2:3`, `4:3`, `3:4`. `1024x1024` gets rejected (HTTP 503).
- **`resolution`** is `1k` (default), `2k`, or `4k`.
- **`gpt-image-2.5` is not a model id** — it is a series label and returns 403. Use `gpt-image-2.5-sunburst` (default here) or `gpt-image-2.5-flare`. The script maps the alias automatically and falls back to `gpt-image-2` when a model is not permitted on the account.
- **2.5 models lock `quality` to `high`**; `gpt-image-2` accepts `low`/`medium`/`high`/`auto`.
- **Result URLs expire (~24 h).** Always download locally; never rely on the URL as the deliverable.
- Typical timing: submit ≈ 0.2 s, generation 40–80 s per image, so a batch of 6 finishes in about a minute rather than six.
- Errors: `403 model_not_found` = model not permitted (use fallback); `503 请求的模型暂无可用服务` = transient, retry; `400 invalid_request` = bad parameters.

## Rate limiting and the bounded queue

With 10 parallel tasks a `429` is normal, not exceptional. The runner treats it as backpressure:

- **Throttle during *submission*** (`POST /v1/images/generations`) — the task did not exist yet, so it is safe to retry. The submission is put into a **bounded FIFO queue** (`--queue-capacity`, default **50**) and re-attempted after the server's `Retry-After` (or exponential backoff with jitter, capped at 30s).
- **Queue is bounded on purpose**: once 50 submissions are waiting, further throttled submissions **fail immediately** instead of accumulating in memory. Memory stays flat under sustained throttling. Failures are reported per image, the rest of the batch continues.
- **Throttle during *polling*** (`GET .../{task_id}`) — the task already exists and is already billed. The runner **never resubmits** it; it backs off and keeps polling the *same* task id. This distinction is the difference between one image and a duplicate charge.
- **Fresh work pauses during backoff.** While a retry is pending, newly throttled prompts are not pushed into the API; otherwise a burst would fill the bounded queue with rejects.

Tuning:

| Goal | Setting |
|---|---|
| Back to "no queue, fail fast" | `--queue-capacity 0` (throttled submissions fail immediately, zero waiting) |
| Bigger burst tolerance | `--queue-capacity 200` |
| Fewer retries per image | `--max-requeues 3` (default 10) |
| Stay under the limit | `--concurrency 5` |

The run summary prints a `Rate limiting: N requeued (peak queue depth x/y), M rejected` line, and `manifest.json` records `concurrency`, `queueCapacity` and a `rateLimit` object (`requeued`, `rejectedQueueFull`, `rejectedRequeueLimit`, `rejectedQueueDisabled`, `peakQueueDepth`).

## Credentials

The API key is **never stored in this skill's files**. The script resolves it in this order:

1. `IMAGEN_API_KEY` or `TOAPIS_API_KEY` environment variable
2. secrets file, first existing match:
   1. `IMAGEN_SECRETS_FILE` (explicit override)
   2. `$XDG_CONFIG_HOME/pi/secrets/imagen.json` → default `~/.config/pi/secrets/imagen.json` (**recommended on Linux**)
   3. `<agent>/secrets/imagen.json` → `~/.pi/agent/secrets/imagen.json` (legacy; inside the dotfiles repo on this machine)
   4. `~/.pi/secrets/imagen.json`

Secrets file format:

```json
{ "api_key": "sk-...", "base_url": "https://toapis.cn" }
```

Permissions on Linux (there is no ACL trick like Windows `icacls`): the key's protection is directory mode `0700` plus file mode `0600`, owned by you. Harden both, and make sure the file never lands in a tracked git work tree:

```bash
install -d -m 700 ~/.config/pi/secrets
chmod 600 ~/.config/pi/secrets/imagen.json
ls -ld ~/.config/pi/secrets ~/.config/pi/secrets/imagen.json   # expect drwx------ / -rw-------
```

Rules when handling the key:

- Never print, echo, log, or paste the full key. `--check` prints a masked form on purpose; keep it that way.
- Never write the key into a prompt, an image, a commit, or a new file outside the secrets directory.
- Do not put the key on a command line if avoidable — command lines leak into shell history, `ps` output and `/proc/*/cmdline`. Prefer the secrets file; if you must use an environment variable, set it for the single command (`IMAGEN_API_KEY=... node ...`) rather than exporting it in a tracked dotfile.
- Rotating: replace `api_key` in the secrets file, then run `node scripts/imagen.mjs --check` to confirm the new key authenticates (HTTP 200).

On a shared box, remember file modes only stop other local accounts — backups, `~/.config` sync tools and shell snapshots can still carry the plaintext elsewhere. Use a password manager, `gpg`, or a system keyring if that matters.

## Useful flags

`--out <dir>` · `--model` · `--fallback-model` · `--size` · `--resolution` · `--quality` · `--background transparent` · `--count <n>` (repeat a prompt as separate parallel tasks) · `--reference <url>` · `--concurrency <n>` (default 10) · `--queue-capacity <n>` (default 50, 0 = fail fast) · `--max-requeues <n>` (default 10) · `--timeout <sec>` · `--keep-urls` · `--json-output` · `--check` (verify credentials, no generation) · `--list-models` · `--dry-run` (print the resolved plan and output dir without calling the API — the cheapest way to validate quoting/paths).

`--dry-run` is the Linux-friendly smoke test: it exercises argument parsing, slug generation, UTF-8 handling and output-path resolution without consuming API quota.

## Reporting (required)

After the script finishes, tell the user:

1. **The output directory** — the absolute path printed as `Output directory: ...`.
2. **Every image with its description** — one line per file, using the printed description, so the user knows which file is which.
3. Model / size / resolution and total elapsed time.
4. Any failures, and what you will do about them.

Keep the existing numbered list format from the script output; it already contains absolute paths and descriptions. Do not invent file names — quote the real paths. `manifest.json` in the output directory holds the same information in machine-readable form.

## Example report

```
Output directory: /home/zeng/tmp/generated-images/2026-02-14T09-31-02
Model: gpt-image-2.5-sunburst | size: 16:9 | resolution: 2k | elapsed: 71.4s

1. /home/zeng/tmp/generated-images/2026-02-14T09-31-02/01-cyber-city.png
   description: cyberpunk city at night, neon rain, cinematic wide shot
2. /home/zeng/tmp/generated-images/2026-02-14T09-31-02/02-cyber-dawn.png
   description: same city at sunrise, warm haze, empty streets
```

## Appendix: Windows / PowerShell (not used on Linux)

`scripts/imagen.ps1` exists only for the Windows machine that shares this dotfiles tree. Both front-ends call the same Node runner, so behaviour and output format are identical. It exists because PowerShell 5.1 mangles non-ASCII argv (fixed by handing prompts over as a temp UTF-8 JSON file) and defaults its console to an OEM codepage.

```powershell
& "<skill-dir>\scripts\imagen.ps1" -Prompt "a glass teapot on marble, soft studio light" -Name teapot
```

Parameters: `-Prompt -Name -PromptList -NameList -Json -PromptFile -Out -Model -FallbackModel -Size -Resolution -Quality -Background -Count -Reference -Concurrency -QueueCapacity -MaxRequeues -Timeout -Interval -Retries -KeepUrls -JsonOutput -Check -ListModels -DryRun -NodePath -ExtraArgs`. Through `-File`, use `-PromptList "a cat|a dog"` instead of `-Prompt "a cat","a dog"` (arrays do not bind through `-File`).

On Linux do not invoke this file: `pwsh` is not installed, and the Node runner covers every flag.
