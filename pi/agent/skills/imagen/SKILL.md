---
name: imagen-skill
description: Generate images from text prompts through the ToAPIs async image API (gpt-image-2.5 / gpt-image-2). Use whenever the user asks to draw, render, generate, create, or imagine a picture/illustration/poster/photo/icon/mockup, or needs multiple images generated at once. Also applies to Chinese requests such as 生成图片、生成图像、画一张、画个、出图、做张海报、封面、壁纸、图标、插画、效果图、批量生成多张图。Handles parallel multi-image generation, downloads files to a local output directory, and reports the directory plus a per-image description.
---

# Imagen Skill

Text-to-image generation through ToAPIs. One command submits **N independent tasks in parallel**, polls them concurrently, downloads the finished PNGs, and prints the output directory plus each image's description.

## When to use

- "generate/draw/render/create an image of ...", "make me a picture/poster/illustration/logo/icon"
- Any request needing several **independent** images (e.g. "one image per chapter", "5 variants")
- Not for editing an existing local file unless it is already reachable as a public URL.

## Quick start

Run the bundled script with `node` (Node 18+, no dependencies). Resolve the path relative to this skill directory.

On Windows prefer the PowerShell front-end (`scripts/imagen.ps1`); on macOS/Linux use the Node runner directly. Both share one implementation — the `.ps1` is a thin wrapper that fixes Windows argument and encoding handling (see `Windows / PowerShell` below).

### PowerShell (Windows — preferred)

```powershell
& "<skill-dir>\scripts\imagen.ps1" -Prompt "a glass teapot on marble, soft studio light" -Name teapot
```

Multiple independent prompts (submitted concurrently):

```powershell
& "<skill-dir>\scripts\imagen.ps1" `
  -Prompt "cyberpunk city at night, neon rain","same city at sunrise, warm haze" `
  -Name cyber-city,cyber-dawn -Size 16:9 -Resolution 2k -Out .\generated-images\scene
```

When invoking through `-File` (from cmd.exe, bash, a CI step or another tool), PowerShell cannot bind a real array — use `-PromptList` with `|` as the separator:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File imagen.ps1 -PromptList "a cat|a dog" -NameList "cat|dog" -Size 1:1 -Out .\out
```

### Node directly (macOS / Linux / any shell)

```bash
node "<skill-dir>/scripts/imagen.mjs" --prompt "a glass teapot on marble, soft studio light" --name teapot
```

Multiple independent prompts (submitted concurrently):

```bash
node "<skill-dir>/scripts/imagen.mjs" \
  --prompt "cyberpunk city at night, neon rain" --name cyber-city \
  --prompt "same city at sunrise, warm haze" --name cyber-dawn \
  --size 16:9 --resolution 2k --out ./generated-images/scene
```

Structured input, best when prompts are long or need per-image settings (works from any shell, and avoids all argv quoting problems):

```bash
node "<skill-dir>/scripts/imagen.mjs" --json '[
  {"name":"cover","prompt":"...","size":"3:4","resolution":"2k"},
  {"name":"inset","prompt":"...","size":"1:1"}
]' --out ./generated-images/book
```

## Windows / PowerShell

`scripts/imagen.ps1` maps every runner flag to a native parameter: `-Prompt -Name -PromptList -NameList -Json -PromptFile -Out -Model -FallbackModel -Size -Resolution -Quality -Background -Count -Reference -Concurrency -QueueCapacity -MaxRequeues -Timeout -Interval -Retries -KeepUrls -JsonOutput -Check -ListModels -DryRun -NodePath -ExtraArgs`. Run it with no arguments to print help.

The wrapper exists for three Windows-specific reasons:

1. **Argument encoding** — Chinese prompts, emoji and quotes get mangled when passed as native argv from PowerShell 5.1. The wrapper writes prompts into a temporary UTF-8 JSON file and hands the runner `--json @file`, so payloads never travel through argv. It also deletes the temp file afterwards.
2. **Console encoding** — PS 5.1 defaults to an OEM codepage (this machine: IBM437), which garbles Chinese in the printed report. The wrapper switches console input/output to UTF-8, so descriptions and filenames survive.
3. **Exit codes** — auth/parameter failures make the script exit non-zero (`$LASTEXITCODE` is propagated), so CI can fail the build.

Array binding caveat: `-Prompt "a","b"` only works when invoked from inside PowerShell. Through `-File`, PowerShell merges them into the single string `a,b`, which would corrupt your prompt — that is exactly why `-PromptList "a|b"` exists. Never try to work around it by relying on comma splitting inside a prompt: commas are legitimate prompt content.

Verified on Windows PowerShell 5.1 and PowerShell 7 with Chinese prompts end-to-end.

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
2. secrets file — `IMAGEN_SECRETS_FILE` if set, else `~/.pi/agent/secrets/imagen.json`

Secrets file format:

```json
{ "api_key": "sk-...", "base_url": "https://toapis.cn" }
```

The secrets file is a plaintext file whose protection is its Windows ACL — inheritance is removed so only the owning user can read it:

```bat
icacls "%USERPROFILE%\.pi\agent\secrets" /inheritance:r /grant:r "%USERNAME%:(OI)(CI)(F)"
icacls "%USERPROFILE%\.pi\agent\secrets\imagen.json" /inheritance:r /grant:r "%USERNAME%:(F)"
```

Rules when handling the key:

- Never print, echo, log, or paste the full key. `--check` prints a masked form on purpose; keep it that way.
- Never write the key into a prompt, an image, a commit, or a new file outside `secrets/`.
- Do not put the key on a command line if avoidable — prefer the environment variable or the secrets file (command lines leak into shell history and process listings).
- Rotating: replace `api_key` in the secrets file, or run `node scripts/imagen.mjs --check` afterwards to confirm the new key authenticates (HTTP 200).

On a shared or backed-up machine, remember the ACL only stops other local accounts and copies of the file elsewhere stay decryptable — use DPAPI encryption or an environment variable if that matters.

## Useful flags

`--out <dir>` · `--model` · `--fallback-model` · `--size` · `--resolution` · `--quality` · `--background transparent` · `--count <n>` (repeat a prompt as separate parallel tasks) · `--reference <url>` · `--concurrency <n>` (default 10) · `--queue-capacity <n>` (default 50, 0 = fail fast) · `--max-requeues <n>` (default 10) · `--timeout <sec>` · `--keep-urls` · `--json-output` · `--check` (verify credentials, no generation) · `--list-models` · `--dry-run`

PowerShell parameter names are the CamelCase equivalents (`-Out`, `-Model`, `-Size`, `-Resolution`, `-Count`, `-Concurrency`, `-QueueCapacity`, `-MaxRequeues`, `-Check`, ...), plus `-PromptList` / `-NameList` for `-File` style invocation. Both front-ends call the same runner, so behaviour and output format are identical.

## Reporting (required)

After the script finishes, tell the user:

1. **The output directory** — the absolute path printed as `Output directory: ...`.
2. **Every image with its description** — one line per file, using the printed description, so the user knows which file is which.
3. Model / size / resolution and total elapsed time.
4. Any failures, and what you will do about them.

Keep the existing numbered list format from the script output; it already contains absolute paths and descriptions. Do not invent file names — quote the real paths. `manifest.json` in the output directory holds the same information in machine-readable form.

## Example report

```
Output directory: D:\tmp\generated-images\2026-02-14T09-31-02
Model: gpt-image-2.5-sunburst | size: 16:9 | resolution: 2k | elapsed: 71.4s

1. D:\tmp\generated-images\2026-02-14T09-31-02\01-cyber-city.png
   description: cyberpunk city at night, neon rain, cinematic wide shot
2. D:\tmp\generated-images\2026-02-14T09-31-02\02-cyber-dawn.png
   description: same city at sunrise, warm haze, empty streets
```
