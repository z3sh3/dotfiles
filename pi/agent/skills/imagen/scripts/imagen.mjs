#!/usr/bin/env node
/**
 * imagen-skill runner - batch image generation through the ToAPIs async task API.
 *
 * The ToAPIs image API is ASYNC: POST /v1/images/generations returns a task id,
 * then GET /v1/images/generations/{id} is polled until status=completed.
 * The `n` parameter is ignored by the upstream service (always 1 image per task),
 * so N images = N tasks. Independent tasks are submitted and polled in parallel.
 *
 * Usage:
 *   node imagen.mjs --prompt "a cat" --prompt "a dog"
 *   node imagen.mjs --json '[{"name":"hero","prompt":"..."}]'
 *   node imagen.mjs --file prompts.txt --out ./out --size 16:9 --resolution 2k
 *
 * No third-party dependencies (Node 18+ global fetch required).
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DEFAULT_BASE_URL = 'https://toapis.cn';
// Credentials are NOT embedded in this file. Resolution order:
//   1. IMAGEN_API_KEY / TOAPIS_API_KEY environment variable
//   2. a secrets file: IMAGEN_SECRETS_FILE, else <agent>/secrets/imagen.json,
//      else ~/.pi/agent/secrets/imagen.json  ->  {"api_key": "...", "base_url": "..."}
// Keep the secrets file readable only by the current user (see SKILL.md).
// 'gpt-image-2.5' is a SERIES label, rejected with 403. The concrete models are
// gpt-image-2.5-flare / gpt-image-2.5-sunburst. Map aliases to real model ids.
const MODEL_ALIASES = {
  'gpt-image-2.5': 'gpt-image-2.5-sunburst',
  'gpt-image-2.5-official': 'gpt-image-2.5-sunburst-official',
  'gpt-image-2.5-vip': 'gpt-image-2.5-sunburst-vip',
};
const KNOWN_MODELS = [
  'gpt-image-2.5-sunburst (default, quality locked to high)',
  'gpt-image-2.5-flare',
  'gpt-image-2',
];
const DEFAULT_MODEL = 'gpt-image-2.5-sunburst';
const DEFAULT_FALLBACK_MODEL = 'gpt-image-2';
const DEFAULT_CONCURRENCY = 10;
// Bounded FIFO queue for submissions that were throttled (HTTP 429).
// 0 disables the queue: a throttled submission fails instead of waiting.
const DEFAULT_QUEUE_CAPACITY = 50;
const DEFAULT_MAX_REQUEUES = 10;
const SKILL_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

function secretsCandidates() {
  const list = [];
  if (process.env.IMAGEN_SECRETS_FILE) list.push(path.resolve(process.env.IMAGEN_SECRETS_FILE));
  list.push(path.resolve(SKILL_DIR, '..', '..', 'secrets', 'imagen.json'));
  list.push(path.resolve(os.homedir(), '.pi', 'agent', 'secrets', 'imagen.json'));
  return [...new Set(list)];
}

const maskKey = (key) => (key.length <= 12 ? '***' : `${key.slice(0, 7)}...${key.slice(-4)}`);

function loadCredentials() {
  const envKey = (process.env.IMAGEN_API_KEY || process.env.TOAPIS_API_KEY || '').trim();
  const envBase = (process.env.IMAGEN_BASE_URL || '').trim();
  const normalize = (base) => String(base || DEFAULT_BASE_URL).trim().replace(/\/+$/, '');

  if (envKey) return { apiKey: envKey, baseUrl: normalize(envBase), source: 'environment variable' };

  for (const file of secretsCandidates()) {
    if (!fs.existsSync(file)) continue;
    let parsed;
    try {
      parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (err) {
      throw new Error(`secrets file ${file} is not valid JSON: ${err.message}`);
    }
    const apiKey = String(parsed.api_key ?? parsed.apiKey ?? parsed.key ?? '').trim();
    if (!apiKey) throw new Error(`secrets file ${file} does not define api_key`);
    return { apiKey, baseUrl: normalize(envBase || parsed.base_url || parsed.baseUrl), source: file };
  }
  throw new Error(
    'No API key found. Set IMAGEN_API_KEY, or create ' +
      secretsCandidates()[0] +
      ' with {"api_key": "sk-..."} restricted to the current user.',
  );
}

const USAGE = `
imagen-skill - batch image generation (ToAPIs async image API)

Basic:
  node imagen.mjs --prompt "<text>" [--name <slug>] [more --prompt ...]
  node imagen.mjs --json '{"prompts":[{"name":"hero","prompt":"..."},{"prompt":"..."}]}'
  node imagen.mjs --json @prompts.json
  node imagen.mjs --file prompts.txt          # one per line, optional "name :: prompt"

Options:
  -p, --prompt <text>       Prompt to render (repeatable).
  -n, --name <slug>         Filename slug for the preceding prompt (repeatable).
      --json <json|@file>   JSON list/object of jobs.
  -f, --file <path>         Text file with one prompt per line ("name :: prompt" allowed).
  -o, --out <dir>           Output directory (default ./generated-images/<timestamp>).
      --model <id>          Model (default ${DEFAULT_MODEL}).
      --fallback-model <id|none>
                            Model used when the requested one is unavailable
                            (default ${DEFAULT_FALLBACK_MODEL}).
      --size <r>            Aspect ratio, e.g. 1:1, 16:9, 9:16, 3:2, 2:3 (default 1:1).
                            NOT pixels - "1024x1024" is rejected by the API.
      --resolution <r>      1k | 2k | 4k (default 1k).
      --quality <q>         low | medium | high | auto (2.5 models are locked to high).
      --background <b>      transparent | opaque (2.5 models only).
      --count <n>           Render each prompt n times as separate parallel tasks (default 1).
      --reference <url>     Reference image URL (repeatable, must be a public URL).
      --concurrency <n>     Parallel tasks (default 10).
      --queue-capacity <n>  Bounded FIFO queue holding submissions that hit a rate
                            limit (default 50). 0 = no queue, fail immediately.
      --max-requeues <n>    Max requeues per task before it fails (default 10).
      --timeout <sec>       Per-task timeout (default 600).
      --interval <sec>      Poll interval (default 3).
      --retries <n>         Retries per request for 5xx/network errors (default 3).
                            HTTP 429 is handled by the queue instead.
      --keep-urls           Do not download; only report remote URLs.
      --json-output         Print machine-readable JSON only.
      --check               Verify credentials resolve and the API is reachable, then exit.
      --list-models         Print known models and exit.
      --dry-run             Print the plan without calling the API.
  -h, --help                Show this help.

Environment:
  IMAGEN_API_KEY / TOAPIS_API_KEY   API key (takes precedence over the secrets file).
  IMAGEN_BASE_URL                   Override the base URL (default ${DEFAULT_BASE_URL}).
  IMAGEN_SECRETS_FILE               Override the secrets file path.

Credentials are never stored in this script. Default secrets file:
  <agent>/secrets/imagen.json  ->  {"api_key": "sk-...", "base_url": "${DEFAULT_BASE_URL}"}
`;

function toInt(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? Math.trunc(n) : fallback;
}

function parseArgs(argv) {  const o = {
    prompts: [], names: [], json: null, file: null, out: null,
    model: DEFAULT_MODEL, fallbackModel: DEFAULT_FALLBACK_MODEL,
    size: '1:1', resolution: '1k', quality: null, background: null,
    count: 1, reference: [], concurrency: DEFAULT_CONCURRENCY, timeout: 600,
    queueCapacity: DEFAULT_QUEUE_CAPACITY, maxRequeues: DEFAULT_MAX_REQUEUES,
    interval: 3, retries: 3, keepUrls: false, jsonOutput: false, dryRun: false,
  };
  const need = (i, flag) => {
    if (i + 1 >= argv.length) throw new Error(`Missing value for ${flag}`);
    return argv[i + 1];
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '-p': case '--prompt': o.prompts.push(need(i, a)); i++; break;
      case '-n': case '--name': o.names.push(need(i, a)); i++; break;
      case '--json': o.json = need(i, a); i++; break;
      case '-f': case '--file': o.file = need(i, a); i++; break;
      case '-o': case '--out': o.out = need(i, a); i++; break;
      case '--model': o.model = need(i, a); i++; break;
      case '--fallback-model': o.fallbackModel = need(i, a); i++; break;
      case '--size': o.size = need(i, a); i++; break;
      case '--resolution': o.resolution = need(i, a); i++; break;
      case '--quality': o.quality = need(i, a); i++; break;
      case '--background': o.background = need(i, a); i++; break;
      case '--count': o.count = Number(need(i, a)); i++; break;
      case '--reference': o.reference.push(need(i, a)); i++; break;
      case '--concurrency': o.concurrency = toInt(need(i, a), DEFAULT_CONCURRENCY); i++; break;
      case '--queue-capacity': o.queueCapacity = toInt(need(i, a), DEFAULT_QUEUE_CAPACITY); i++; break;
      case '--max-requeues': o.maxRequeues = toInt(need(i, a), DEFAULT_MAX_REQUEUES); i++; break;
      case '--timeout': o.timeout = Number(need(i, a)); i++; break;
      case '--interval': o.interval = Number(need(i, a)); i++; break;
      case '--retries': o.retries = Number(need(i, a)); i++; break;
      case '--keep-urls': o.keepUrls = true; break;
      case '--json-output': o.jsonOutput = true; break;
      case '--check': o.check = true; break;
      case '--dry-run': o.dryRun = true; break;
      case '--list-models': o.listModels = true; break;
      case '-h': case '--help': o.help = true; break;
      default:
        throw new Error(`Unknown argument: ${a}`);
    }
  }
  return o;
}

function slugify(input, fallback = 'image') {  const slug = String(input ?? '')
    .normalize('NFKD')
    .replace(/[^A-Za-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40)
    .replace(/-+$/g, '');
  return slug || fallback;
}

function resolveModel(model) {
  const key = String(model).trim();
  return MODEL_ALIASES[key] || key;
}

function loadJobs(o) {
  const jobs = [];

  const pushJob = (raw, index) => {
    const prompt = String(raw.prompt ?? '').trim();
    if (!prompt) throw new Error(`Job #${index + 1} has an empty prompt`);
    const count = Math.max(1, Math.floor(raw.count ?? o.count ?? 1));
    const baseName = raw.name ? slugify(raw.name, `image-${index + 1}`) : null;
    for (let k = 0; k < count; k++) {
      jobs.push({
        prompt,
        description: String(raw.description ?? prompt),
        name: baseName ? (count > 1 ? `${baseName}-${k + 1}` : baseName) : null,
        model: resolveModel(raw.model ?? o.model),
        size: raw.size ?? o.size,
        resolution: raw.resolution ?? o.resolution,
        quality: raw.quality ?? o.quality ?? undefined,
        background: raw.background ?? o.background ?? undefined,
        referenceImages: raw.reference_images ?? raw.referenceImages ?? (o.reference.length ? [...o.reference] : []),
      });
    }
  };

  if (o.json) {
    const raw = o.json.startsWith('@') ? fs.readFileSync(o.json.slice(1), 'utf8') : o.json;
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (err) {
      throw new Error(`--json is not valid JSON: ${err.message}`);
    }
    const list = Array.isArray(parsed) ? parsed : (parsed.prompts ?? parsed.jobs ?? parsed.images ?? [parsed]);
    if (!Array.isArray(list) || list.length === 0) throw new Error('--json must describe at least one prompt');
    list.forEach((item, i) => pushJob(typeof item === 'string' ? { prompt: item } : item, i));
  }

  if (o.file) {
    const text = fs.readFileSync(o.file, 'utf8');
    let i = jobs.length;
    for (const line of text.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const sep = trimmed.indexOf('::');
      if (sep > 0) {
        pushJob({ name: trimmed.slice(0, sep).trim(), prompt: trimmed.slice(sep + 2).trim() }, i++);
      } else {
        pushJob({ prompt: trimmed }, i++);
      }
    }
  }

  o.prompts.forEach((prompt, idx) => {
    pushJob({ prompt, name: o.names[idx], description: prompt }, jobs.length);
  });

  if (jobs.length === 0) throw new Error('No prompts supplied. Use --prompt, --json or --file.');
  // Stable, filename-friendly default slugs.
  const used = new Map();
  jobs.forEach((job, i) => {
    let slug = job.name || slugify(job.prompt, 'image');
    const n = (used.get(slug) || 0) + 1;
    used.set(slug, n);
    if (n > 1) slug = `${slug}-${n}`;
    job.slug = slug;
    job.index = i + 1;
  });
  return jobs;
}

/**
 * A submission that came back HTTP 429. Carries the server's Retry-After so the
 * scheduler - not the HTTP layer - decides how long to wait and where to park it.
 */
class RateLimitError extends Error {
  constructor(message, retryAfterMs) {
    super(message);
    this.name = 'RateLimitError';
    this.rateLimited = true;
    this.retryAfterMs = retryAfterMs;
  }
}

function parseRetryAfter(headerValue, fallbackMs) {
  if (!headerValue) return fallbackMs;
  const seconds = Number(headerValue);
  if (Number.isFinite(seconds) && seconds >= 0) return seconds * 1000;
  const at = Date.parse(headerValue);
  if (Number.isFinite(at)) return Math.max(0, at - Date.now());
  return fallbackMs;
}

/** Exponential backoff with jitter: 1s, 2s, 4s ... capped at 30s. */
function backoffMs(attempt) {
  const base = Math.min(30_000, 1000 * 2 ** Math.min(Math.max(0, attempt - 1), 5));
  return base + Math.floor(Math.random() * Math.min(1000, base * 0.25));
}

/**
 * Bounded-queue task scheduler.
 *
 * `concurrency` tasks run at once. When a submission is rate limited it is NOT
 * retried inline and NOT dropped: it goes back into a FIFO waiting queue capped
 * at `queueCapacity` entries and is re-attempted after the backoff. Once that
 * queue is full, excess throttled submissions FAIL instead of letting the queue
 * grow without bound - memory stays bounded under sustained rate limiting.
 *
 * `queueCapacity: 0` disables the queue entirely: a throttled submission fails
 * immediately (no waiting, no backlog).
 *
 * Only *submission* survives through this queue. A rate limit while polling an
 * already-created task is retried inside runJob against the same task id - the
 * work must never be resubmitted, or it would be generated and billed twice.
 */
async function runWithQueue(items, options, worker) {
  const concurrency = Math.max(1, options.concurrency);
  const queueCapacity = Math.max(0, options.queueCapacity);
  const maxRequeues = Math.max(0, options.maxRequeues);
  const labelOf = options.labelOf || ((item, index) => `#${index + 1}`);

  const results = new Array(items.length);
  const ready = items.map((item, index) => ({ item, index, requeues: 0, readyAt: 0, deferred: false }));
  const waiting = [];
  const stats = {
    requeued: 0,
    rejectedQueueFull: 0,
    rejectedRequeueLimit: 0,
    rejectedQueueDisabled: 0,
    peakQueueDepth: 0,
  };

  let active = 0;
  let timer = null;
  // While a backoff is pending, fresh submissions are held back: hammering new
  // work into an API that just throttled us only fills the queue with rejects.
  // Already-queued retries bypass the gate once their readyAt arrives.
  let cooldownUntil = 0;
  let settle;
  const finished = new Promise((resolve) => { settle = resolve; });

  const pump = () => {
    const now = Date.now();
    // Deferred submissions whose backoff elapsed go back to runnable state, FIFO.
    for (let i = 0; i < waiting.length; ) {
      if (waiting[i].readyAt <= now) {
        const slot = waiting.splice(i, 1)[0];
        slot.deferred = true;
        ready.push(slot);
      } else {
        i++;
      }
    }

    while (active < concurrency) {
      const idx = ready.findIndex((slot) => slot.deferred || now >= cooldownUntil);
      if (idx === -1) break;
      const [slot] = ready.splice(idx, 1);
      slot.deferred = false;
      runOne(slot);
    }

    if (active === 0) {
      if (ready.length === 0 && waiting.length === 0) {
        if (timer) { clearTimeout(timer); timer = null; }
        settle();
        return;
      }
      const nextTimes = [];
      if (waiting.length > 0) nextTimes.push(Math.min(...waiting.map((w) => w.readyAt)));
      if (ready.length > 0) nextTimes.push(cooldownUntil);
      const nextAt = Math.min(...nextTimes);
      if (timer) clearTimeout(timer);
      timer = setTimeout(() => { timer = null; pump(); }, Math.max(5, nextAt - Date.now()));
    }
  };

  const runOne = (slot) => {
    active++;
    Promise.resolve()
      .then(() => worker(slot.item, slot.index))
      .then((value) => { results[slot.index] = value; })
      .catch((err) => {
        if (!err || !err.rateLimited) {
          results[slot.index] = { ok: false, item: slot.item, error: err?.message || String(err) };
          return;
        }

        slot.requeues += 1;
        let rejection = null;
        if (queueCapacity === 0) rejection = 'queue disabled (--queue-capacity 0)';
        else if (waiting.length >= queueCapacity) rejection = `queue full (capacity ${queueCapacity})`;
        else if (slot.requeues > maxRequeues) rejection = `exceeded ${maxRequeues} requeues`;

        if (rejection) {
          if (queueCapacity === 0) stats.rejectedQueueDisabled++;
          else if (waiting.length >= queueCapacity) stats.rejectedQueueFull++;
          else stats.rejectedRequeueLimit++;
          log(`  ${labelOf(slot.item, slot.index)} rate limited -> FAILED (${rejection})`);
          results[slot.index] = { ok: false, item: slot.item, error: `${err.message} [rate limit: ${rejection}]` };
          return;
        }

        slot.readyAt = Date.now() + (err.retryAfterMs ?? backoffMs(slot.requeues));
        cooldownUntil = Math.max(cooldownUntil, slot.readyAt);
        waiting.push(slot);
        stats.requeued++;
        stats.peakQueueDepth = Math.max(stats.peakQueueDepth, waiting.length);
        log(
          `  ${labelOf(slot.item, slot.index)} rate limited -> queued (${waiting.length}/${queueCapacity}), ` +
            `retry in ${((slot.readyAt - Date.now()) / 1000).toFixed(1)}s`,
        );
      })
      .finally(() => { active--; pump(); });
  };

  pump();
  await finished;
  return { results, stats };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Guard against a stalled socket hanging the whole batch.
const REQUEST_TIMEOUT_MS = 120_000;
const withTimeout = (init = {}) => ({ ...init, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });

function createClient({ baseUrl, apiKey, retries = 3 }) {
  const auth = { Authorization: `Bearer ${apiKey}` };
  const maxAttempts = Math.max(1, retries + 1);

  async function request(url, init, label) {
    let lastError;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        const res = await fetch(url, withTimeout(init));
        const text = await res.text();
        let body = null;
        try { body = JSON.parse(text); } catch { /* non-JSON body */ }
        if (res.ok) return body ?? { raw: text };
        const message = body?.error?.message || body?.message || text.slice(0, 200);

        // 429 is never retried here: the scheduler owns throttling so a blocked
        // submission can be parked in the bounded queue instead of being lost.
        if (res.status === 429) {
          throw new RateLimitError(
            `${label} HTTP 429: ${message}`,
            parseRetryAfter(res.headers.get('retry-after'), backoffMs(1)),
          );
        }

        lastError = new Error(`${label} HTTP ${res.status}: ${message}`);
        lastError.status = res.status;
        lastError.code = body?.error?.code || body?.code;
        if (res.status < 500 || attempt === maxAttempts) throw lastError;
        log(`  retry ${attempt}/${maxAttempts - 1} for ${label} after HTTP ${res.status}`);
        await sleep(1500 * attempt);
      } catch (err) {
        if (err.rateLimited) throw err;
        lastError = err;
        const retryable = err.status === undefined || err.status >= 500;
        if (!retryable || attempt === maxAttempts) throw err;
        await sleep(1500 * attempt);
      }
    }
    throw lastError;
  }

  return {
    async submit(job) {
      const body = { model: job.model, prompt: job.prompt, size: job.size, resolution: job.resolution, n: 1 };
      if (job.quality) body.quality = job.quality;
      if (job.background) body.background = job.background;
      if (job.referenceImages?.length) body.reference_images = job.referenceImages;
      const json = await request(
        `${baseUrl}/v1/images/generations`,
        { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json' }, body: JSON.stringify(body) },
        'submit',
      );
      if (!json?.id) throw new Error(`submit returned no task id: ${JSON.stringify(json).slice(0, 200)}`);
      return json;
    },
    async task(taskId) {
      return request(`${baseUrl}/v1/images/generations/${taskId}`, { headers: auth }, `poll ${taskId}`);
    },
  };
}

function log(message) {
  process.stderr.write(`${message}\n`);
}

function modelPermissionError(err) {
  return err?.status === 403 || err?.code === 'model_not_found';
}

async function runJob(client, job, cfg) {
  const startedAt = Date.now();
  let task;
  let note;
  try {
    task = await client.submit(job);
  } catch (err) {
    const canFallback = cfg.fallbackModel && cfg.fallbackModel !== job.model && modelPermissionError(err);
    if (err.rateLimited || !canFallback) throw err;
    note = `model ${job.model} unavailable (${err.message}); fell back to ${cfg.fallbackModel}`;
    job.model = cfg.fallbackModel;
    task = await client.submit(job);
  }

  const deadline = startedAt + cfg.timeout * 1000;
  let lastProgress = -1;
  let pollThrottles = 0;
  while (Date.now() < deadline) {
    let state;
    try {
      state = await client.task(task.id);
    } catch (err) {
      if (!err.rateLimited) throw err;
      // The task already exists. Polling it again is free; resubmitting it would
      // create a second task and bill twice, so back off and keep this task id.
      pollThrottles += 1;
      const waitMs = Math.min(err.retryAfterMs ?? backoffMs(pollThrottles), 60_000);
      log(`  [${job.index}] ${job.slug}: rate limited while polling, same task retries in ${(waitMs / 1000).toFixed(1)}s`);
      await sleep(waitMs);
      continue;
    }
    if (state.status === 'completed') {
      const urls = (state.result?.data ?? []).map((d) => d.url || (d.b64_json ? `data:image/png;base64,${d.b64_json}` : null)).filter(Boolean);
      if (urls.length === 0) throw new Error(`task ${task.id} completed without image data`);
      return { taskId: task.id, urls, elapsedMs: Date.now() - startedAt, usage: state.usage, note, expiresAt: state.expires_at };
    }
    if (state.status === 'failed' || state.status === 'canceled') {
      const detail = state.error?.message || state.fail_reason || state.status;
      throw new Error(`task ${task.id} ${state.status}: ${detail}`);
    }
    if (state.progress !== lastProgress) {
      lastProgress = state.progress;
      log(`  [${job.index}] ${job.slug}: ${state.status} ${state.progress ?? 0}%`);
    }
    await sleep(cfg.interval * 1000);
  }
  throw new Error(`task ${task.id} timed out after ${cfg.timeout}s`);
}

async function download(url, filePath) {
  const res = await fetch(url, withTimeout());
  if (!res.ok) throw new Error(`download failed HTTP ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  if (buf.length === 0) throw new Error('download returned 0 bytes');
  fs.writeFileSync(filePath, buf);
  return buf.length;
}

function extensionFor(url, contentType) {
  const fromType = /image\/(png|jpeg|jpg|webp)/.exec(contentType || '');
  if (fromType) return fromType[1] === 'jpeg' ? 'jpg' : fromType[1];
  const fromUrl = /\.(png|jpe?g|webp)(?:\?|$)/i.exec(url || '');
  if (fromUrl) return fromUrl[1].toLowerCase() === 'jpeg' ? 'jpg' : fromUrl[1].toLowerCase();
  return 'png';
}

async function main() {
  const o = parseArgs(process.argv.slice(2));
  if (o.help) { process.stdout.write(USAGE); return; }
  if (o.listModels) {
    process.stdout.write(`Known models (${DEFAULT_BASE_URL}):\n${KNOWN_MODELS.map((m) => `  - ${m}`).join('\n')}\n`);
    return;
  }

  if (o.check) {
    const cred = loadCredentials();
    const res = await fetch(`${cred.baseUrl}/v1/models`, {
      headers: { Authorization: `Bearer ${cred.apiKey}` },
      signal: AbortSignal.timeout(30_000),
    });
    const body = await res.text();
    let modelCount = null;
    try { modelCount = (JSON.parse(body).data || []).length; } catch { /* not JSON */ }
    const lines = [
      `base url:    ${cred.baseUrl}`,
      `key source:  ${cred.source}`,
      `key:         ${maskKey(cred.apiKey)}`,
      `auth check:  HTTP ${res.status}${res.ok ? ' (ok)' : ' - ' + body.slice(0, 160)}`,
    ];
    if (modelCount !== null) lines.push(`models:      ${modelCount} visible`);
    lines.push(`default:     ${DEFAULT_MODEL}`);
    process.stdout.write(lines.join('\n') + '\n');
    if (!res.ok) process.exitCode = 1;
    return;
  }

  // Generation path: validate prompts and credentials before touching the API.
  const jobs = loadJobs(o);
  const { apiKey, baseUrl, source: credSource } = loadCredentials();
  const outDir = path.resolve(o.out || path.join(process.cwd(), 'generated-images', new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)));
  const fallbackModel = !o.fallbackModel || o.fallbackModel === 'none' ? null : resolveModel(o.fallbackModel);
  const cfg = { timeout: o.timeout, interval: Math.max(1, o.interval), fallbackModel };

  if (o.dryRun) {
    process.stdout.write(JSON.stringify({ outDir, baseUrl, credentialSource: credSource, jobs }, null, 2) + '\n');
    return;
  }

  fs.mkdirSync(outDir, { recursive: true });
  const client = createClient({ baseUrl, apiKey, retries: o.retries });
  const startedAt = Date.now();
  const queueOptions = {
    concurrency: Math.max(1, o.concurrency),
    queueCapacity: Math.max(0, o.queueCapacity),
    maxRequeues: Math.max(0, o.maxRequeues),
    labelOf: (job) => `[${job.index}] ${job.slug}`,
  };
  log(`imagen: credentials from ${credSource} (${maskKey(apiKey)})`);
  log(
    `imagen: ${jobs.length} task(s), model=${jobs[0].model}, size=${o.size}, resolution=${o.resolution}, ` +
      `concurrency=${queueOptions.concurrency}, queue-capacity=${queueOptions.queueCapacity}`,
  );

  // Independent prompts have no dependency on each other -> submit + poll concurrently.
  const { results: settled, stats: rateLimitStats } = await runWithQueue(jobs, queueOptions, async (job) => {
    try {
      const result = await runJob(client, job, cfg);
      log(`  [${job.index}] ${job.slug}: completed in ${(result.elapsedMs / 1000).toFixed(1)}s`);
      return { ok: true, job, result };
    } catch (err) {
      // 429 means "park me in the bounded queue", not "fail" - let it bubble up.
      if (err.rateLimited) throw err;
      log(`  [${job.index}] ${job.slug}: FAILED ${err.message}`);
      return { ok: false, job, error: err.message };
    }
  });

  const saved = [];
  const failures = [];
  for (const entry of settled) {
    if (!entry.ok) {
      const failedJob = entry.job ?? entry.item;
      failures.push({ name: failedJob.slug, description: failedJob.description, error: entry.error });
      continue;
    }
    const { job, result } = entry;
    const images = [];
    for (let i = 0; i < result.urls.length; i++) {
      const url = result.urls[i];
      const suffix = result.urls.length > 1 ? `-${i + 1}` : '';
      let filePath = null;
      let bytes = 0;
      if (!o.keepUrls && url.startsWith('http')) {
        const head = await fetch(url, { method: 'HEAD', signal: AbortSignal.timeout(30_000) }).catch(() => null);
        const ext = extensionFor(url, head?.headers.get('content-type'));
        filePath = path.join(outDir, `${String(job.index).padStart(2, '0')}-${job.slug}${suffix}.${ext}`);
        try {
          bytes = await download(url, filePath);
        } catch (err) {
          filePath = null;
          failures.push({ name: job.slug, description: job.description, error: `download failed: ${err.message}` });
        }
      }
      images.push({ file: filePath, bytes, url, description: job.description });
    }
    saved.push({
      name: job.slug,
      description: job.description,
      model: job.model,
      size: job.size,
      resolution: job.resolution,
      quality: job.quality ?? null,
      taskId: result.taskId,
      elapsedMs: result.elapsedMs,
      note: result.note ?? null,
      images,
    });
  }

  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1);
  const rejectedByQueue =
    rateLimitStats.rejectedQueueFull + rateLimitStats.rejectedRequeueLimit + rateLimitStats.rejectedQueueDisabled;
  const manifest = {
    generatedAt: new Date().toISOString(),
    baseUrl,
    outDir,
    model: [...new Set(saved.map((s) => s.model))].join(',') || jobs[0].model,
    size: o.size,
    resolution: o.resolution,
    concurrency: queueOptions.concurrency,
    queueCapacity: queueOptions.queueCapacity,
    rateLimit: { ...rateLimitStats, rejected: rejectedByQueue },
    elapsedSeconds: Number(elapsed),
    succeeded: saved.length,
    failed: failures.length,
    images: saved,
    failures,
  };
  fs.writeFileSync(path.join(outDir, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');

  if (o.jsonOutput) {
    process.stdout.write(JSON.stringify(manifest, null, 2) + '\n');
    return;
  }

  const lines = [];
  const modelsUsed = [...new Set(saved.map((s) => s.model))];
  lines.push(`Output directory: ${outDir}`);
  lines.push(`Model: ${modelsUsed.join(', ') || jobs[0].model} | size: ${o.size} | resolution: ${o.resolution} | elapsed: ${elapsed}s`);
  lines.push(`Result: ${saved.length} prompt(s) succeeded, ${failures.length} failed`);
  if (rateLimitStats.requeued > 0 || rejectedByQueue > 0) {
    lines.push(
      `Rate limiting: ${rateLimitStats.requeued} submission(s) requeued ` +
        `(peak queue depth ${rateLimitStats.peakQueueDepth}/${queueOptions.queueCapacity}), ${rejectedByQueue} rejected`,
    );
  }
  lines.push('');
  let i = 0;
  for (const item of saved) {
    for (const img of item.images) {
      i++;
      lines.push(`${i}. ${img.file || '(URL only)'}`);
      lines.push(`   description: ${img.description}`);
      lines.push(`   model: ${item.model} | size: ${item.size} | resolution: ${item.resolution} | ${(img.bytes / 1024 / 1024).toFixed(2)} MB | task: ${item.taskId}`);
      if (item.note) lines.push(`   note: ${item.note}`);
      if (!img.file) lines.push(`   url: ${img.url}`);
    }
  }
  if (failures.length) {
    lines.push('');
    lines.push('Failures:');
    for (const f of failures) lines.push(`  - ${f.name}: ${f.error}`);
  }
  lines.push('');
  lines.push(`Manifest: ${path.join(outDir, 'manifest.json')}`);
  process.stdout.write(lines.join('\n') + '\n');
}

main().catch((err) => {
  process.stderr.write(`imagen: fatal: ${err.message}\n`);
  process.exitCode = 1;
});
