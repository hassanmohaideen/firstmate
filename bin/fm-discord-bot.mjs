#!/usr/bin/env node
// Self-hosted Discord transport runtime.
//
// This program is deliberately narrow: it owns Discord Gateway/REST I/O,
// strict local configuration, owner/guild/channel/mention authorization,
// private inbox/context publication, reconnects, and secret-safe diagnostics.
// It delegates notification publication to bin/fm-discord-notify.sh so the
// existing durable wake queue remains the only Firstmate notification plane.
//
// Operator lifecycle and Gateway ownership admission are owned by bin/fm-discord-bot.sh.
// Direct use is limited to non-Gateway operations:
//   fm-discord-bot.mjs validate
//   fm-discord-bot.mjs send <message-id> --text-file <path> [--nonce-scope initial|final]
//
// FM_DISCORD_TEST_* variables and `ingest` are hermetic-test seams only. They
// are ignored or refused unless FM_DISCORD_TEST_MODE=1.

import { constants as fsConstants } from "node:fs";
import {
  chmod,
  lstat,
  link,
  mkdir,
  open,
  readFile,
  readdir,
  readlink,
  realpath,
  rename,
  rm,
  stat,
  unlink,
} from "node:fs/promises";
import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { platform, uptime } from "node:os";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(process.env.FM_ROOT_OVERRIDE || join(SCRIPT_DIR, ".."));
const HOME = resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || ROOT);
const STATE = resolve(process.env.FM_STATE_OVERRIDE || join(HOME, "state"));
const CONFIG_DIR = resolve(process.env.FM_CONFIG_OVERRIDE || join(HOME, "config"));
const CONFIG_FILE = resolve(process.env.FM_DISCORD_CONFIG_FILE || join(CONFIG_DIR, "discord-bot.env"));
const INBOX_DIR = join(STATE, "discord-inbox");
const CONTEXT_DIR = join(STATE, "discord-context");
const ENABLED_FILE = join(STATE, "discord-bot.enabled");
const READY_FILE = join(STATE, "discord-bot.ready");
const ERROR_FILE = join(STATE, "discord-bot.error");
const ERROR_NOTIFIED_FILE = join(STATE, "discord-bot.error.notified");
const OWNERSHIP_DIR = join(HOME, "state", ".discord-bot-service");
const TERMINAL_FILE = join(OWNERSHIP_DIR, "terminal.json");
const RECONNECT_FILE = join(OWNERSHIP_DIR, "reconnect.json");
const RECONNECT_SUPPRESSION_FILE = join(OWNERSHIP_DIR, "reconnect-suppression.json");
const WAKE_DEDUP_DIR = join(STATE, ".wake-dedup");
const NOTIFIER = join(ROOT, "bin", "fm-discord-notify.sh");
const TEST_MODE = process.env.FM_DISCORD_TEST_MODE === "1";
const API_BASE = TEST_MODE && process.env.FM_DISCORD_TEST_API_BASE
  ? process.env.FM_DISCORD_TEST_API_BASE.replace(/\/$/, "")
  : "https://discord.com/api/v10";
const TEST_GATEWAY_URL = TEST_MODE ? process.env.FM_DISCORD_TEST_GATEWAY_URL || "" : "";
const TEST_ENFORCE_PRODUCTION_GATEWAY = TEST_MODE
  && process.env.FM_DISCORD_TEST_ENFORCE_PRODUCTION_GATEWAY === "1";
const MAX_REPLY_CHARS = 1900;
const RETENTION_SECONDS = 7 * 24 * 60 * 60;
const DEDUP_RETENTION_SECONDS = RETENTION_SECONDS + 24 * 60 * 60;
const RECONCILE_INTERVAL_MS = TEST_MODE && /^[0-9]+$/.test(process.env.FM_DISCORD_TEST_RECONCILE_MS || "")
  ? Math.max(10, Math.min(1000, Number(process.env.FM_DISCORD_TEST_RECONCILE_MS)))
  : 30_000;
const CONFIG_KEYS = [
  "FM_DISCORD_BOT_TOKEN",
  "FM_DISCORD_OWNER_USER_ID",
  "FM_DISCORD_GUILD_ID",
  "FM_DISCORD_CHANNEL_ID",
];
const SNOWFLAKE_RE = /^[0-9]{15,22}$/;
const SAFE_CODE_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const INCIDENT_ID_RE = /^[0-9a-f]{64}$/;
const BOOT_ID_RE = /^[A-Za-z0-9._:-]{1,128}$/;
let diagnosticTransitions = Promise.resolve();
let diagnosticGeneration = 0;

class DisabledError extends Error {}
class ConfigError extends Error {}
class DiscordHttpError extends Error {
  constructor(status, retryAfterMs = 0) {
    super(`Discord HTTP ${status}`);
    this.status = status;
    this.retryAfterMs = retryAfterMs;
  }
}

function safeLog(message) {
  process.stderr.write(`[discord-bot] ${message}\n`);
}

function diagnosticEpochSeconds() {
  if (TEST_MODE && /^[0-9]+$/.test(process.env.FM_DISCORD_TEST_EPOCH_SECONDS || "")) {
    return Number(process.env.FM_DISCORD_TEST_EPOCH_SECONDS);
  }
  return Math.floor(Date.now() / 1000);
}

function monotonicMilliseconds() {
  return Math.floor(uptime() * 1000);
}

async function systemBootIdentity() {
  const testIdentity = TEST_MODE ? process.env.FM_DISCORD_TEST_BOOT_ID || "" : "";
  if (BOOT_ID_RE.test(testIdentity)) return testIdentity;
  if (platform() === "linux") {
    try {
      const identity = (await readFile("/proc/sys/kernel/random/boot_id", "utf8")).trim();
      if (BOOT_ID_RE.test(identity)) return identity;
    } catch {}
  }
  if (platform() === "darwin") {
    try {
      const identity = await new Promise((resolvePromise, rejectPromise) => {
        const child = spawn("/usr/sbin/sysctl", ["-n", "kern.bootsessionuuid"], {
          stdio: ["ignore", "pipe", "ignore"],
        });
        let output = "";
        child.stdout.on("data", (chunk) => { output += chunk.toString("utf8"); });
        child.once("error", rejectPromise);
        child.once("close", (code) => code === 0 ? resolvePromise(output.trim()) : rejectPromise(new Error("sysctl failed")));
      });
      if (BOOT_ID_RE.test(identity)) return identity;
    } catch {}
  }
  return `process-${process.pid}-${randomBytes(8).toString("hex")}`;
}

function modeBits(info) {
  return info.mode & 0o777;
}

async function assertPlainDirectory(path, expectedMode = null) {
  let info;
  try {
    info = await lstat(path);
  } catch (error) {
    if (error?.code === "ENOENT") {
      throw new ConfigError(`required directory is missing: ${path}`);
    }
    throw error;
  }
  if (!info.isDirectory() || info.isSymbolicLink()) {
    throw new ConfigError(`unsafe directory path: ${path}`);
  }
  if (expectedMode !== null && modeBits(info) !== expectedMode) {
    throw new ConfigError(`directory must have mode ${expectedMode.toString(8)}: ${path}`);
  }
  return info;
}

async function assertPrivateFile(path) {
  const info = await lstat(path);
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1 || modeBits(info) !== 0o600) {
    throw new ConfigError(`private file must be regular, single-linked, and mode 600: ${path}`);
  }
  return info;
}

async function ensureStateRoot() {
  await mkdir(STATE, { recursive: true, mode: 0o700 });
  await assertPlainDirectory(STATE);
}

async function ensurePrivateDirectory(path) {
  await ensureStateRoot();
  try {
    await mkdir(path, { mode: 0o700 });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
  }
  await assertPlainDirectory(path, 0o700);
}

async function ensureOwnershipDirectory() {
  const ownershipState = join(HOME, "state");
  try {
    await mkdir(ownershipState, { recursive: true, mode: 0o700 });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
  }
  await assertPlainDirectory(ownershipState);
  try {
    await mkdir(OWNERSHIP_DIR, { mode: 0o700 });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
  }
  await assertPlainDirectory(OWNERSHIP_DIR, 0o700);
}

async function replaceLeasePid(path, pid) {
  const temp = join(dirname(path), `.pid.handoff.${process.pid}.${randomBytes(8).toString("hex")}`);
  const handle = await open(temp, fsConstants.O_CREAT | fsConstants.O_EXCL | fsConstants.O_WRONLY, 0o600);
  try {
    try {
      await handle.writeFile(`${pid}\n`, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    await rename(temp, path);
  } catch (error) {
    await rm(temp, { force: true });
    throw error;
  }
}

async function requireGatewayOwnership() {
  const ownerPid = process.env.FM_DISCORD_OWNER_PID || "";
  if (!/^[1-9][0-9]*$/.test(ownerPid) || Number(ownerPid) !== process.ppid) {
    throw new ConfigError("Gateway run requires the single-instance service wrapper");
  }
  const lock = join(OWNERSHIP_DIR, "owner.lock");
  const info = await lstat(lock).catch(() => null);
  if (!info?.isSymbolicLink()) {
    throw new ConfigError("Gateway run requires the single-instance service wrapper");
  }
  const ownerTarget = resolve(dirname(lock), await readlink(lock));
  const canonicalOwnershipDir = await realpath(OWNERSHIP_DIR);
  if (dirname(ownerTarget) !== canonicalOwnershipDir || !/^owner\.lock\.owner\.[A-Za-z0-9]+$/.test(ownerTarget.split("/").pop())) {
    throw new ConfigError("Gateway ownership lease is invalid");
  }
  await assertPlainDirectory(ownerTarget, 0o700);
  const pidFile = join(ownerTarget, "pid");
  const pidInfo = await lstat(pidFile);
  if (!pidInfo.isFile() || pidInfo.isSymbolicLink() || pidInfo.nlink !== 1) {
    throw new ConfigError("Gateway ownership lease is invalid");
  }
  const recordedPid = (await readFile(pidFile, "utf8")).trim();
  if (recordedPid !== ownerPid) {
    throw new ConfigError("Gateway ownership lease is invalid");
  }
  const readyFile = join(OWNERSHIP_DIR, "owner.ready");
  await assertPrivateFile(readyFile);
  const ready = (await readFile(readyFile, "utf8")).trim().split("\n");
  if (ready.length !== 2 || ready[0] !== ownerPid || !/^[a-f0-9]{64}$/.test(ready[1])) {
    throw new ConfigError("Gateway ownership lease is invalid");
  }
  if (resolve(dirname(lock), await readlink(lock)) !== ownerTarget) {
    throw new ConfigError("Gateway ownership lease changed during handoff");
  }
  await atomicReplacePrivate(readyFile, `${process.pid}\n${ready[1]}\n`);
  await replaceLeasePid(pidFile, String(process.pid));
  if (resolve(dirname(lock), await readlink(lock)) !== ownerTarget
      || (await readFile(pidFile, "utf8")).trim() !== String(process.pid)) {
    throw new ConfigError("Gateway ownership lease changed during handoff");
  }
  return { lock, ownerTarget, pidFile, readyFile };
}

async function releaseGatewayOwnership(lease) {
  const currentPid = String(process.pid);
  const lockInfo = await lstat(lease.lock).catch(() => null);
  if (!lockInfo?.isSymbolicLink()
      || resolve(dirname(lease.lock), await readlink(lease.lock)) !== lease.ownerTarget
      || (await readFile(lease.pidFile, "utf8").catch(() => "")).trim() !== currentPid) return;
  const ready = await readFile(lease.readyFile, "utf8").catch(() => "");
  if (ready.split("\n", 1)[0] === currentPid) await removeMarker(lease.readyFile);
  await unlink(lease.lock);
  await unlink(lease.pidFile).catch(() => {});
  await rm(lease.ownerTarget, { recursive: false }).catch(() => {});
}

async function atomicReplacePrivate(path, content) {
  const parent = dirname(path);
  await ensureStateRoot();
  await assertPlainDirectory(parent);
  const temp = join(parent, `.${path.split("/").pop()}.tmp.${process.pid}.${Math.random().toString(16).slice(2)}`);
  const handle = await open(temp, fsConstants.O_CREAT | fsConstants.O_EXCL | fsConstants.O_WRONLY, 0o600);
  try {
    try {
      await handle.writeFile(content, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    await chmod(temp, 0o600);
    try {
      await assertPrivateFile(path);
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    await rename(temp, path);
    await assertPrivateFile(path);
  } catch (error) {
    await rm(temp, { force: true });
    throw error;
  }
}

async function atomicPublishPrivateOnce(directory, basename, content) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(basename)) {
    throw new ConfigError("unsafe private artifact name");
  }
  await ensurePrivateDirectory(directory);
  const destination = join(directory, basename);
  const temp = join(directory, `.${basename}.tmp.${process.pid}.${Math.random().toString(16).slice(2)}`);
  const handle = await open(temp, fsConstants.O_CREAT | fsConstants.O_EXCL | fsConstants.O_WRONLY, 0o600);
  try {
    try {
      await handle.writeFile(content, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    await chmod(temp, 0o600);
    await link(temp, destination);
    await unlink(temp);
    await assertPrivateFile(destination);
    return true;
  } catch (error) {
    await rm(temp, { force: true });
    if (error?.code === "EEXIST") {
      await assertPrivateFile(destination);
      return false;
    }
    throw error;
  }
}

function parseConfigText(text) {
  const parsed = new Map();
  for (const [index, raw] of text.split(/\n/).entries()) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const match = /^([A-Z0-9_]+)=(.*)$/.exec(line);
    if (!match) throw new ConfigError(`invalid configuration line ${index + 1}`);
    const [, key, value] = match;
    if (!CONFIG_KEYS.includes(key)) throw new ConfigError(`unsupported configuration key on line ${index + 1}`);
    if (parsed.has(key)) throw new ConfigError(`duplicate configuration key on line ${index + 1}`);
    if (!value || /[\s\x00-\x1f\x7f]/.test(value)) {
      throw new ConfigError(`empty or unsafe value for ${key}`);
    }
    parsed.set(key, value);
  }
  return parsed;
}

async function loadConfig() {
  let fileValues = new Map();
  let fileExists = true;
  try {
    await assertPlainDirectory(dirname(CONFIG_FILE));
    await assertPrivateFile(CONFIG_FILE);
    const text = await readFile(CONFIG_FILE, "utf8");
    fileValues = parseConfigText(text);
  } catch (error) {
    if (error?.code === "ENOENT") {
      fileExists = false;
    } else {
      throw error;
    }
  }

  const anyEnvironmentValue = CONFIG_KEYS.some((key) => Object.hasOwn(process.env, key));
  if (!fileExists && !anyEnvironmentValue) {
    throw new DisabledError("self-hosted Discord is not configured");
  }
  const values = {};
  for (const key of CONFIG_KEYS) {
    values[key] = Object.hasOwn(process.env, key) ? process.env[key] : fileValues.get(key);
    if (!values[key]) throw new ConfigError(`missing ${key}`);
    if (/[\s\x00-\x1f\x7f]/.test(values[key])) throw new ConfigError(`unsafe ${key}`);
  }
  if (values.FM_DISCORD_BOT_TOKEN.length < 20 || values.FM_DISCORD_BOT_TOKEN.length > 200) {
    throw new ConfigError("FM_DISCORD_BOT_TOKEN has an invalid length");
  }
  for (const key of CONFIG_KEYS.slice(1)) {
    if (!SNOWFLAKE_RE.test(values[key])) throw new ConfigError(`${key} must be a Discord snowflake`);
  }
  return {
    token: values.FM_DISCORD_BOT_TOKEN,
    ownerId: values.FM_DISCORD_OWNER_USER_ID,
    guildId: values.FM_DISCORD_GUILD_ID,
    channelId: values.FM_DISCORD_CHANNEL_ID,
  };
}

function validateProductionEndpoint(url, kind) {
  const parsed = new URL(url);
  if (TEST_MODE && !(TEST_ENFORCE_PRODUCTION_GATEWAY && kind === "gateway" && url !== TEST_GATEWAY_URL)) {
    return parsed;
  }
  if (kind === "api") {
    if (parsed.protocol !== "https:" || parsed.hostname !== "discord.com") {
      throw new ConfigError("Discord API endpoint is not the fixed authenticated Discord endpoint");
    }
  } else {
    const isDiscordGateway = parsed.hostname === "gateway.discord.gg"
      || /^gateway(?:-[a-z0-9]+)+\.discord\.gg$/.test(parsed.hostname);
    if (parsed.protocol !== "wss:" || !isDiscordGateway) {
      throw new ConfigError("Discord Gateway endpoint is not a fixed Discord Gateway endpoint");
    }
  }
  return parsed;
}

async function notify(kind, key) {
  const child = spawn(NOTIFIER, [kind, key], {
    env: {
      PATH: process.env.PATH || "/usr/bin:/bin:/usr/sbin:/sbin",
      FM_HOME: HOME,
      FM_ROOT_OVERRIDE: ROOT,
      FM_STATE_OVERRIDE: STATE,
      FM_DISCORD_NODE_BIN: process.execPath,
    },
    stdio: ["ignore", "ignore", "ignore"],
  });
  const status = await new Promise((resolvePromise) => {
    child.once("error", () => resolvePromise(127));
    child.once("exit", (code) => resolvePromise(code ?? 1));
  });
  if (status !== 0) throw new Error("durable notification publication failed");
}

async function writeMarker(path, value) {
  await atomicReplacePrivate(path, `${value}\n`);
}

async function removeMarker(path) {
  try {
    await assertPrivateFile(path);
    await unlink(path);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

async function readDiagnostic(path) {
  try {
    await assertPrivateFile(path);
    const record = JSON.parse(await readFile(path, "utf8"));
    if (!SAFE_CODE_RE.test(record?.code || "")) return null;
    return {
      code: record.code,
      incidentId: INCIDENT_ID_RE.test(record.incident_id || "") ? record.incident_id : "",
    };
  } catch (error) {
    if (error?.code === "ENOENT" || error instanceof SyntaxError) return null;
    throw error;
  }
}

function enqueueDiagnostic(transition) {
  const result = diagnosticTransitions.then(transition);
  diagnosticTransitions = result.catch(() => {});
  return result;
}

async function publishDiagnostic(record) {
  const notified = await readDiagnostic(ERROR_NOTIFIED_FILE);
  if (notified?.incidentId === record.incidentId) return;
  await notify("error", record.code);
  await atomicReplacePrivate(
    ERROR_NOTIFIED_FILE,
    `${JSON.stringify({
      code: record.code,
      incident_id: record.incidentId,
      notified_at: diagnosticEpochSeconds(),
    })}\n`,
  );
}

function reportDiagnostic(code) {
  diagnosticGeneration += 1;
  return enqueueDiagnostic(async () => {
    if (!SAFE_CODE_RE.test(code)) code = "discord-service-error";
    try {
      const previous = await readDiagnostic(ERROR_FILE);
      let record = previous;
      if (previous?.code !== code || !previous.incidentId) {
        record = { code, incidentId: randomBytes(32).toString("hex") };
        await atomicReplacePrivate(ERROR_FILE, `${JSON.stringify({
          code: record.code,
          incident_id: record.incidentId,
          recorded_at: diagnosticEpochSeconds(),
        })}\n`);
      }
      await publishDiagnostic(record);
    } catch {
      safeLog("cannot persist or publish the Discord diagnostic safely");
    }
  });
}

function reconcileDiagnostic() {
  return enqueueDiagnostic(async () => {
    try {
      let record = await readDiagnostic(ERROR_FILE);
      if (!record) return;
      if (!record.incidentId) {
        record = { code: record.code, incidentId: randomBytes(32).toString("hex") };
        await atomicReplacePrivate(ERROR_FILE, `${JSON.stringify({
          code: record.code,
          incident_id: record.incidentId,
          recorded_at: diagnosticEpochSeconds(),
        })}\n`);
      }
      await publishDiagnostic(record);
    } catch {
      safeLog("a pending Discord diagnostic could not be reconciled safely");
    }
  });
}

function clearDiagnostic(expectedGeneration = null) {
  return enqueueDiagnostic(async () => {
    if (expectedGeneration !== null && expectedGeneration !== diagnosticGeneration) return;
    try {
      await removeMarker(ERROR_FILE);
      await removeMarker(ERROR_NOTIFIED_FILE);
    } catch {
      safeLog("cannot clear the recovered Discord diagnostic");
    }
  });
}

function boundedString(value, max = 4000) {
  if (typeof value !== "string") return "";
  return [...value].slice(0, max).join("");
}

function directText(content, selfUserId) {
  const escaped = selfUserId.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return boundedString(content).replace(new RegExp(`<@!?${escaped}>`, "g"), " ").replace(/\s+/g, " ").trim();
}

function authorizedMessage(message, config, selfUserId) {
  if (!message || typeof message !== "object") return null;
  if (!SNOWFLAKE_RE.test(String(message.id || ""))) return null;
  if (String(message.guild_id || "") !== config.guildId) return null;
  if (String(message.channel_id || "") !== config.channelId) return null;
  if (!message.author || String(message.author.id || "") !== config.ownerId) return null;
  if (message.author.bot === true || message.webhook_id) return null;
  if (![0, 19].includes(Number(message.type ?? 0))) return null;
  if (!Array.isArray(message.mentions) || !message.mentions.some((user) => String(user?.id || "") === selfUserId)) {
    return null;
  }
  const text = directText(message.content, selfUserId);
  if (!text) return null;
  return { id: String(message.id), text };
}

async function linkedRequests() {
  const linked = new Set();
  for (const name of await readdir(STATE)) {
    if (!name.endsWith(".meta")) continue;
    const path = join(STATE, name);
    try {
      const info = await lstat(path);
      if (!info.isFile() || info.isSymbolicLink() || info.size > 1024 * 1024) continue;
      const text = await readFile(path, "utf8");
      for (const match of text.matchAll(/^discord_request=([0-9]{15,22})$/gm)) linked.add(match[1]);
    } catch {
      // A concurrently retired task simply contributes no live binding.
    }
  }
  return linked;
}

function discordDeduplicationKey(kind, identity) {
  return createHash("sha256").update(`${kind}:${identity}`).digest("hex");
}

async function retainedDiscordDeduplication() {
  const messages = new Set();
  for (const directory of [INBOX_DIR, CONTEXT_DIR]) {
    for (const name of await readdir(directory)) {
      const match = name.match(/^([0-9]{15,22})\.json$/);
      if (match) messages.add(discordDeduplicationKey("message", match[1]));
    }
  }

  const errors = new Set();
  let preserveAllErrors = false;
  try {
    const info = await assertPrivateFile(ERROR_FILE);
    if (info.size > 4096) throw new ConfigError("private diagnostic record is too large");
    const record = JSON.parse(await readFile(ERROR_FILE, "utf8"));
    if (!SAFE_CODE_RE.test(record?.code || "") || !INCIDENT_ID_RE.test(record?.incident_id || "")) {
      throw new ConfigError("private diagnostic record is invalid");
    }
    errors.add(discordDeduplicationKey("error", record.incident_id));
  } catch (error) {
    if (error?.code !== "ENOENT") preserveAllErrors = true;
  }
  return { messages, errors, preserveAllErrors };
}

async function pruneDiscordDeduplication(retained, now) {
  try {
    await assertPlainDirectory(WAKE_DEDUP_DIR, 0o700);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  for (const name of await readdir(WAKE_DEDUP_DIR)) {
    const match = name.match(/^([0-9a-f]{64})\.(?:accepted|pending)$/);
    if (!match) continue;
    const path = join(WAKE_DEDUP_DIR, name);
    try {
      const info = await assertPrivateFile(path);
      if (info.size > 256 || now - info.mtimeMs / 1000 <= DEDUP_RETENTION_SECONDS) continue;
      const digest = match[1];
      const key = await readFile(path, "utf8");
      if (key === `discord-message-${digest}\n`) {
        if (!retained.messages.has(digest)) await unlink(path);
      } else if (key === `discord-error-${digest}\n`) {
        if (!retained.preserveAllErrors && !retained.errors.has(digest)) await unlink(path);
      }
    } catch {
      continue;
    }
  }
}

async function pruneContexts() {
  try {
    await ensurePrivateDirectory(CONTEXT_DIR);
    await ensurePrivateDirectory(INBOX_DIR);
    const retainedDeduplication = await retainedDiscordDeduplication();
    const inbox = new Set((await readdir(INBOX_DIR)).filter((name) => name.endsWith(".json")));
    const linked = await linkedRequests();
    const now = Date.now() / 1000;
    for (const name of await readdir(CONTEXT_DIR)) {
      if (!name.endsWith(".json") && !name.endsWith(".notified") && !name.endsWith(".sent")) continue;
      const id = name.replace(/\.(json|notified|initial\.sent|final\.sent)$/, "");
      if (inbox.has(`${id}.json`) || linked.has(id)) continue;
      const path = join(CONTEXT_DIR, name);
      try {
        await assertPrivateFile(path);
        const info = await stat(path);
        if (now - info.mtimeMs / 1000 > RETENTION_SECONDS) await unlink(path);
      } catch {
        // Unsafe artifacts are preserved for an operator to inspect.
      }
    }
    await pruneDiscordDeduplication(retainedDeduplication, now);
  } catch {
    safeLog("context pruning was skipped because its private state is unsafe");
  }
}

function inboxRecord(message, accepted, config) {
  const parent = message.referenced_message && typeof message.referenced_message === "object"
    ? {
        author_name: boundedString(message.referenced_message.author?.global_name
          || message.referenced_message.author?.username || "unknown", 100),
        text: boundedString(message.referenced_message.content, 2000),
      }
    : null;
  return {
    schema: "firstmate.discord-inbox.v1",
    request_id: accepted.id,
    text: accepted.text,
    direct_author: "configured-owner",
    in_reply_to: parent,
    binding: {
      message_id: accepted.id,
      guild_id: config.guildId,
      channel_id: config.channelId,
    },
    recorded_at: Math.floor(Date.now() / 1000),
  };
}

function inboxRecordIsBound(record, id, config) {
  return record?.schema === "firstmate.discord-inbox.v1"
    && record.request_id === id
    && typeof record.text === "string"
    && record.text.length > 0
    && [...record.text].length <= 4000
    && record.direct_author === "configured-owner"
    && record.binding?.message_id === id
    && record.binding?.guild_id === config.guildId
    && record.binding?.channel_id === config.channelId;
}

function contextRecordIsBound(record, id, config) {
  return record?.schema === "firstmate.discord-context.v1"
    && record.request_id === id
    && record.message_id === id
    && record.guild_id === config.guildId
    && record.channel_id === config.channelId;
}

function contextRecord(record) {
  return {
    schema: "firstmate.discord-context.v1",
    request_id: record.request_id,
    message_id: record.binding.message_id,
    guild_id: record.binding.guild_id,
    channel_id: record.binding.channel_id,
    recorded_at: record.recorded_at,
  };
}

async function notifyInboxId(id) {
  const notifiedPath = join(CONTEXT_DIR, `${id}.notified`);
  try {
    await assertPrivateFile(notifiedPath);
    return false;
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  await notify("message", id);
  await atomicPublishPrivateOnce(CONTEXT_DIR, `${id}.notified`, `${Math.floor(Date.now() / 1000)}\n`);
  return true;
}

async function ingestMessage(message, config, selfUserId) {
  if (!SNOWFLAKE_RE.test(String(selfUserId || ""))) throw new ConfigError("Discord bot user id is unavailable");
  const accepted = authorizedMessage(message, config, selfUserId);
  if (!accepted) return "ignored";
  await ensurePrivateDirectory(INBOX_DIR);
  await ensurePrivateDirectory(CONTEXT_DIR);
  const contextPath = join(CONTEXT_DIR, `${accepted.id}.json`);
  try {
    await assertPrivateFile(contextPath);
    const existingContext = JSON.parse(await readFile(contextPath, "utf8"));
    if (!contextRecordIsBound(existingContext, accepted.id, config)) {
      throw new ConfigError("existing Discord reply context is invalid");
    }
    const inboxPath = join(INBOX_DIR, `${accepted.id}.json`);
    try {
      await assertPrivateFile(inboxPath);
      const existingInbox = JSON.parse(await readFile(inboxPath, "utf8"));
      if (!inboxRecordIsBound(existingInbox, accepted.id, config)) {
        throw new ConfigError("existing Discord inbox record is invalid");
      }
      await notifyInboxId(accepted.id);
      return "pending";
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
      return "duplicate";
    }
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }

  const record = inboxRecord(message, accepted, config);
  const inboxCreated = await atomicPublishPrivateOnce(
    INBOX_DIR,
    `${accepted.id}.json`,
    `${JSON.stringify(record)}\n`,
  );
  if (!inboxCreated) {
    const existingPath = join(INBOX_DIR, `${accepted.id}.json`);
    await assertPrivateFile(existingPath);
    const existingRecord = JSON.parse(await readFile(existingPath, "utf8"));
    if (!inboxRecordIsBound(existingRecord, accepted.id, config)) {
      throw new ConfigError("concurrent Discord inbox record is invalid");
    }
  }
  await atomicPublishPrivateOnce(
    CONTEXT_DIR,
    `${accepted.id}.json`,
    `${JSON.stringify(contextRecord(record))}\n`,
  );
  await notifyInboxId(accepted.id);
  return "accepted";
}

async function reconcileInbox(config) {
  await reconcileDiagnostic();
  await ensurePrivateDirectory(INBOX_DIR);
  await ensurePrivateDirectory(CONTEXT_DIR);
  for (const name of await readdir(INBOX_DIR)) {
    if (!/^([0-9]{15,22})\.json$/.test(name)) continue;
    const id = name.slice(0, -5);
    try {
      const inboxPath = join(INBOX_DIR, name);
      await assertPrivateFile(inboxPath);
      const record = JSON.parse(await readFile(inboxPath, "utf8"));
      if (!inboxRecordIsBound(record, id, config)) continue;
      await atomicPublishPrivateOnce(
        CONTEXT_DIR,
        `${id}.json`,
        `${JSON.stringify(contextRecord(record))}\n`,
      );
      await notifyInboxId(id);
    } catch {
      safeLog("a pending Discord inbox record could not be reconciled safely");
    }
  }
}

async function fetchWithTimeout(url, options, timeoutMs = 10_000) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

async function gatewayUrl(config) {
  if (TEST_GATEWAY_URL) {
    validateProductionEndpoint(TEST_GATEWAY_URL, "gateway");
    return { url: TEST_GATEWAY_URL, sessionStartLimit: null };
  }
  validateProductionEndpoint(API_BASE, "api");
  let response;
  try {
    response = await fetchWithTimeout(`${API_BASE}/gateway/bot`, {
      headers: { Authorization: `Bot ${config.token}`, Accept: "application/json" },
    }, 5000);
  } catch {
    throw new Error("gateway lookup unavailable");
  }
  if (!response.ok) {
    let retryAfterMs = 0;
    if (response.status === 429) {
      const headerDelay = Number(response.headers.get("retry-after"));
      if (Number.isFinite(headerDelay) && headerDelay > 0) retryAfterMs = Math.ceil(headerDelay * 1000);
      try {
        const errorBody = await response.json();
        const bodyDelay = Number(errorBody?.retry_after);
        if (Number.isFinite(bodyDelay) && bodyDelay > 0) {
          retryAfterMs = Math.max(retryAfterMs, Math.ceil(bodyDelay * 1000));
        }
      } catch {}
    }
    throw new DiscordHttpError(response.status, retryAfterMs);
  }
  const body = await response.json();
  validateProductionEndpoint(body.url, "gateway");
  const limit = body.session_start_limit;
  if (!limit || !Number.isInteger(limit.total) || limit.total < 1
      || !Number.isInteger(limit.remaining) || limit.remaining < 0 || limit.remaining > limit.total
      || !Number.isFinite(limit.reset_after) || limit.reset_after < 0) {
    throw new ConfigError("gateway session-start limit is invalid");
  }
  const resetAfter = Math.ceil(limit.reset_after);
  const testWallOffset = TEST_MODE
    && /^-?[0-9]+$/.test(process.env.FM_DISCORD_TEST_SESSION_RESET_WALL_OFFSET_MS || "")
    ? Number(process.env.FM_DISCORD_TEST_SESSION_RESET_WALL_OFFSET_MS)
    : 0;
  return {
    url: body.url,
    sessionStartLimit: {
      total: limit.total,
      remaining: limit.remaining,
      resetAfter,
      resetAt: Date.now() + resetAfter + testWallOffset,
    },
  };
}

function testDuration(name, fallback, minimum = 1, maximum = fallback) {
  const value = process.env[name] || "";
  if (!TEST_MODE || !/^[0-9]+$/.test(value)) return fallback;
  return Math.max(minimum, Math.min(maximum, Number(value)));
}

const TEST_BACKOFF_MS = testDuration("FM_DISCORD_TEST_BACKOFF_MS", 5000, 1, 1000);
const RECONNECT_POLICY = {
  minimumIntervalMs: TEST_MODE && process.env.FM_DISCORD_TEST_BACKOFF_MS
    ? TEST_BACKOFF_MS
    : testDuration("FM_DISCORD_TEST_MIN_CONNECTION_MS", 5000, 1, 5000),
  baseDelayMs: TEST_BACKOFF_MS,
  maximumDelayMs: TEST_MODE && process.env.FM_DISCORD_TEST_BACKOFF_MS
    ? Math.max(TEST_BACKOFF_MS, testDuration("FM_DISCORD_TEST_MAX_BACKOFF_MS", 1000, 1, 5000))
    : 300_000,
  cooldownAfter: 8,
  cooldownMs: testDuration("FM_DISCORD_TEST_COOLDOWN_MS", 15 * 60_000, 1, 15 * 60_000),
};
const STABLE_CONNECTION_MS = testDuration("FM_DISCORD_TEST_STABLE_MS", 5 * 60_000, 50, 5 * 60_000);
const HEARTBEAT_STABLE_MS = testDuration("FM_DISCORD_TEST_HEARTBEAT_STABLE_MS", 2 * 60_000, 50, 2 * 60_000);

function randomFraction() {
  const fixture = process.env.FM_DISCORD_TEST_RANDOM || "";
  if (TEST_MODE && /^(?:0(?:\.\d+)?|1(?:\.0+)?)$/.test(fixture)) return Number(fixture);
  return Math.random();
}

function reconnectDelayMilliseconds({ pressure, random, now, lastConnectionAt, serverDelayMs = 0, policy = RECONNECT_POLICY }) {
  const exponent = Math.min(16, Math.max(0, pressure - 1));
  const unjittered = Math.min(policy.maximumDelayMs, policy.baseDelayMs * (2 ** exponent));
  const jittered = Math.floor(unjittered * (0.5 + Math.max(0, Math.min(1, random)) * 0.5));
  const intervalRemaining = lastConnectionAt === null
    ? 0
    : Math.max(0, Math.min(policy.minimumIntervalMs, policy.minimumIntervalMs - (now - lastConnectionAt)));
  const cooldown = pressure >= policy.cooldownAfter
    ? Math.floor(policy.cooldownMs * (0.8 + Math.max(0, Math.min(1, random)) * 0.2))
    : 0;
  return Math.max(1, jittered, intervalRemaining, Math.max(0, serverDelayMs), cooldown);
}

function simulateReconnectPolicy(input) {
  const policy = {
    minimumIntervalMs: Number(input.minimum_interval_ms ?? 5000),
    baseDelayMs: Number(input.base_delay_ms ?? 5000),
    maximumDelayMs: Number(input.maximum_delay_ms ?? 300_000),
    cooldownAfter: Number(input.cooldown_after ?? 8),
    cooldownMs: Number(input.cooldown_ms ?? 15 * 60_000),
  };
  const duration = Number(input.duration_ms ?? 60 * 60_000);
  const uptime = Number(input.unstable_uptime_ms ?? 50);
  const stableAt = Number(input.stable_at_connection ?? 0);
  const maximumConnections = Number(input.maximum_connections ?? 10_000);
  const random = Number(input.random ?? 0.5);
  let now = 0;
  let pressure = 0;
  let connections = 0;
  const delays = [];
  while (now < duration && connections < maximumConnections) {
    const lastConnectionAt = now;
    connections += 1;
    now += uptime;
    if (connections === stableAt) pressure = 0;
    pressure += 1;
    const delay = reconnectDelayMilliseconds({ pressure, random, now, lastConnectionAt, policy });
    if (delays.length < 16) delays.push(delay);
    now += delay;
  }
  return { connections, elapsed_ms: now, final_pressure: pressure, delays };
}

function sleep(milliseconds) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));
}

function authenticationFingerprint(config) {
  return createHash("sha256").update(config.token).digest("hex");
}

function rebootWaitRemaining(waitMilliseconds) {
  return waitMilliseconds;
}

function simulateRebootWaitPolicy(input) {
  let remaining = Number(input.remaining_ms);
  const remainingAfterObservations = [];
  const observations = input.reboot_observations_ms || [];
  for (let index = 0; index < observations.length; index += 1) {
    remaining = rebootWaitRemaining(remaining);
    remainingAfterObservations.push(remaining);
  }
  return { remaining_ms: remaining, remaining_after_observations: remainingAfterObservations };
}

function validFallbackSuppression(record) {
  return record?.schema === "firstmate.discord-reconnect-suppression.v1"
    && INCIDENT_ID_RE.test(record.authentication_fingerprint || "")
    && typeof record.operator_intervention_required === "boolean"
    && (record.operator_code === undefined || record.operator_code === null
      || SAFE_CODE_RE.test(record.operator_code))
    && (record.server_not_before === null
      ? record.server_wait_ms === null && record.operator_intervention_required
      : Number.isSafeInteger(record.server_not_before) && record.server_not_before >= 0
        && Number.isSafeInteger(record.server_wait_ms) && record.server_wait_ms >= 0
        && (record.server_wall_observed_at === undefined
          || record.server_wall_observed_at === null
          || Number.isSafeInteger(record.server_wall_observed_at)
            && record.server_wall_observed_at >= 0)
        && (record.server_boot_id === undefined || record.server_boot_id === null
          || BOOT_ID_RE.test(record.server_boot_id))
        && (record.server_monotonic_not_before === undefined
          || record.server_monotonic_not_before === null
          || Number.isSafeInteger(record.server_monotonic_not_before)
            && record.server_monotonic_not_before >= 0)
        && (record.server_reboot_fallback_used === undefined
          || typeof record.server_reboot_fallback_used === "boolean")
        && !record.operator_intervention_required);
}

async function activeTerminalSuppression(config) {
  let record;
  try {
    await assertPrivateFile(TERMINAL_FILE);
    record = JSON.parse(await readFile(TERMINAL_FILE, "utf8"));
  } catch (error) {
    if (error?.code !== "ENOENT") return "terminal-suppression-invalid";
  }
  if (record) {
    if (record.schema !== "firstmate.discord-terminal.v2" || !SAFE_CODE_RE.test(record.code || "")
        || !INCIDENT_ID_RE.test(record.authentication_fingerprint || "")) {
      return "terminal-suppression-invalid";
    }
    if (record.authentication_fingerprint === authenticationFingerprint(config)) return record.code;
    await removeMarker(TERMINAL_FILE);
    await clearDiagnostic();
  }
  let fallback;
  try {
    await assertPrivateFile(RECONNECT_SUPPRESSION_FILE);
    fallback = JSON.parse(await readFile(RECONNECT_SUPPRESSION_FILE, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return "";
    return "terminal-suppression-invalid";
  }
  if (!validFallbackSuppression(fallback)) return "terminal-suppression-invalid";
  if (fallback.authentication_fingerprint !== authenticationFingerprint(config)) {
    await removeMarker(RECONNECT_SUPPRESSION_FILE);
    return "";
  }
  return fallback.operator_intervention_required
    ? fallback.operator_code || "reconnect-state-unavailable"
    : "";
}

async function writeTerminalSuppression(config, code) {
  await ensureOwnershipDirectory();
  if (TEST_MODE && process.env.FM_DISCORD_TEST_TERMINAL_WRITE_FAILURE === "1") {
    throw new Error("injected terminal state failure");
  }
  await atomicReplacePrivate(TERMINAL_FILE, `${JSON.stringify({
    schema: "firstmate.discord-terminal.v2",
    code,
    authentication_fingerprint: authenticationFingerprint(config),
    recorded_at: diagnosticEpochSeconds(),
  })}\n`);
}

function terminalDiagnosticForClose(code) {
  return new Map([
    [4004, "authentication-rejected"],
    [4010, "gateway-sharding-invalid"],
    [4011, "gateway-sharding-required"],
    [4012, "gateway-version-invalid"],
    [4013, "gateway-intents-invalid"],
    [4014, "message-content-intent-disabled"],
  ]).get(code) || "";
}

function validReconnectRecord(record) {
  if (!record) return true;
  const legacy = record.schema === "firstmate.discord-reconnect.v1";
  const limit = record.session_start_limit;
  const resume = record.resume_session;
  if ((!legacy && record.schema !== "firstmate.discord-reconnect.v2")
      || (legacy && !INCIDENT_ID_RE.test(record.config_fingerprint || ""))
      || (!legacy && !INCIDENT_ID_RE.test(record.authentication_fingerprint || ""))
      || !Number.isInteger(record.failure_pressure) || record.failure_pressure < 0
      || (record.last_connection_at !== null
        && (!Number.isSafeInteger(record.last_connection_at) || record.last_connection_at < 0))
      || (record.server_not_before !== undefined && record.server_not_before !== null
        && (!Number.isSafeInteger(record.server_not_before) || record.server_not_before < 0))
      || (record.server_wait_ms !== undefined && record.server_wait_ms !== null
        && (!Number.isSafeInteger(record.server_wait_ms) || record.server_wait_ms < 0))
      || (record.server_wall_observed_at !== undefined && record.server_wall_observed_at !== null
        && (!Number.isSafeInteger(record.server_wall_observed_at) || record.server_wall_observed_at < 0))
      || ((record.server_not_before ?? null) === null !== ((record.server_wait_ms ?? null) === null))
      || (record.server_boot_id !== undefined && record.server_boot_id !== null
        && !BOOT_ID_RE.test(record.server_boot_id))
      || (record.server_monotonic_not_before !== undefined && record.server_monotonic_not_before !== null
        && (!Number.isSafeInteger(record.server_monotonic_not_before)
          || record.server_monotonic_not_before < 0))
      || (record.server_reboot_fallback_used !== undefined
        && typeof record.server_reboot_fallback_used !== "boolean")
      || (limit !== null && (!limit || !Number.isInteger(limit.total) || limit.total < 1
        || !Number.isInteger(limit.remaining) || limit.remaining < 0 || limit.remaining > limit.total
        || !Number.isInteger(limit.resetAt) || limit.resetAt < 0
        || (limit.resetWaitMs !== undefined
          && (!Number.isSafeInteger(limit.resetWaitMs) || limit.resetWaitMs < 0))
        || (limit.resetBootId !== undefined && limit.resetBootId !== null
          && !BOOT_ID_RE.test(limit.resetBootId))
        || (limit.resetMonotonicAt !== undefined && limit.resetMonotonicAt !== null
          && (!Number.isSafeInteger(limit.resetMonotonicAt) || limit.resetMonotonicAt < 0))
        || (limit.resetRebootFallbackUsed !== undefined
          && typeof limit.resetRebootFallbackUsed !== "boolean")))
      || (resume !== undefined && resume !== null
        && (!resume || typeof resume.session_id !== "string" || !resume.session_id
          || typeof resume.resume_url !== "string" || !resume.resume_url
          || (resume.sequence !== null && !Number.isSafeInteger(resume.sequence))
          || (resume.self_user_id !== undefined && !SNOWFLAKE_RE.test(resume.self_user_id))))) {
    return false;
  }
  if (resume) {
    try {
      validateProductionEndpoint(resume.resume_url, "gateway");
    } catch {
      return false;
    }
  }
  return true;
}

async function readReconnectRecord() {
  let record;
  try {
    await assertPrivateFile(RECONNECT_FILE);
    record = JSON.parse(await readFile(RECONNECT_FILE, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw new ConfigError("reconnect state is invalid");
  }
  if (!validReconnectRecord(record)) throw new ConfigError("reconnect state is invalid");
  return record;
}

class GatewayRunner {
  constructor(config) {
    this.config = config;
    this.stopping = false;
    this.socket = null;
    this.sessionId = "";
    this.resumeUrl = "";
    this.sequence = null;
    this.resumeSequence = null;
    this.selfUserId = "";
    this.sessionGeneration = 0;
    this.failurePressure = 0;
    this.lastConnectionAt = null;
    this.serverNotBefore = null;
    this.serverWaitMs = null;
    this.serverWallObservedAt = null;
    this.serverBootId = null;
    this.serverMonotonicNotBefore = null;
    this.serverRebootFallbackUsed = false;
    this.bootId = null;
    this.sessionStartLimit = null;
    this.durableTransitions = Promise.resolve();
    this.fallbackTransitions = Promise.resolve();
    this.sequencePersistPending = false;
    this.sequencePersistTask = null;
    this.connected = false;
    this.inbound = Promise.resolve();
    this.waiters = new Set();
    this.failClosed = false;
    this.failClosedWait = null;
    this.fallbackSuppressionActive = false;
    this.durableWriteCount = 0;
  }

  canUseGateway() {
    return !this.stopping && !this.failClosed;
  }

  stop() {
    this.stopping = true;
    for (const waiter of [...this.waiters]) waiter.resolve();
    if (this.socket && this.socket.readyState < WebSocket.CLOSING) {
      this.socket.close(1000, "shutdown");
    }
  }

  clearSession() {
    this.sessionGeneration += 1;
    this.sessionId = "";
    this.resumeUrl = "";
    this.sequence = null;
    this.resumeSequence = null;
    this.selfUserId = "";
  }

  resumeSessionRecord() {
    if (!this.sessionId) return null;
    return {
      session_id: this.sessionId,
      resume_url: this.resumeUrl,
      sequence: this.resumeSequence,
      self_user_id: this.selfUserId,
    };
  }

  async waitForReconnect(milliseconds) {
    const startedAt = performance.now();
    while (!this.stopping) {
      const remaining = milliseconds - (performance.now() - startedAt);
      if (remaining <= 0) break;
      await new Promise((resolvePromise) => {
        const waiter = {
          timer: null,
          resolve: () => {
            if (waiter.timer) clearTimeout(waiter.timer);
            this.waiters.delete(waiter);
            resolvePromise();
          },
        };
        waiter.timer = setTimeout(waiter.resolve, Math.min(remaining, 2_147_000_000));
        this.waiters.add(waiter);
        if (this.stopping) waiter.resolve();
      });
    }
  }

  durableRecord() {
    return {
      schema: "firstmate.discord-reconnect.v2",
      authentication_fingerprint: authenticationFingerprint(this.config),
      failure_pressure: this.failurePressure,
      last_connection_at: this.lastConnectionAt,
      server_not_before: this.serverNotBefore,
      server_wait_ms: this.serverWaitMs,
      server_wall_observed_at: this.serverWallObservedAt,
      server_boot_id: this.serverBootId,
      server_monotonic_not_before: this.serverMonotonicNotBefore,
      server_reboot_fallback_used: this.serverRebootFallbackUsed,
      session_start_limit: this.sessionStartLimit,
      resume_session: this.resumeSessionRecord(),
    };
  }

  persistDurableState() {
    const content = `${JSON.stringify(this.durableRecord())}\n`;
    const writeNumber = ++this.durableWriteCount;
    const transition = this.durableTransitions.then(async () => {
      if (TEST_MODE && process.env.FM_DISCORD_TEST_DURABLE_WRITE_DELAY_MS) {
        await sleep(testDuration("FM_DISCORD_TEST_DURABLE_WRITE_DELAY_MS", 1, 1, 1000));
      }
      if (TEST_MODE && Number(process.env.FM_DISCORD_TEST_DURABLE_WRITE_FAIL_AT) === writeNumber) {
        throw new Error("injected reconnect state failure");
      }
      await atomicReplacePrivate(RECONNECT_FILE, content);
      if (TEST_MODE && process.env.FM_DISCORD_TEST_DURABLE_WRITE_LOG === "1") {
        const log = await open(join(STATE, "discord-bot.durable-writes"), "a", 0o600);
        try {
          await log.writeFile("write\n");
        } finally {
          await log.close();
        }
      }
    });
    this.durableTransitions = transition.catch(() => {});
    return transition;
  }

  persistFallbackSuppression(operatorCode = "reconnect-state-unavailable") {
    const terminal = operatorCode !== "reconnect-state-unavailable";
    const transition = this.fallbackTransitions.then(async () => {
      let existing;
      try {
        await assertPrivateFile(RECONNECT_SUPPRESSION_FILE);
        existing = JSON.parse(await readFile(RECONNECT_SUPPRESSION_FILE, "utf8"));
      } catch {}
      const fingerprint = authenticationFingerprint(this.config);
      if (!terminal && validFallbackSuppression(existing)
          && existing.authentication_fingerprint === fingerprint
          && existing.operator_intervention_required) {
        this.fallbackSuppressionActive = true;
        return;
      }
      const deadlineActive = !terminal && this.serverNotBefore !== null && this.serverWaitMs !== null;
      await atomicReplacePrivate(RECONNECT_SUPPRESSION_FILE, `${JSON.stringify({
        schema: "firstmate.discord-reconnect-suppression.v1",
        authentication_fingerprint: fingerprint,
        server_not_before: deadlineActive ? this.serverNotBefore : null,
        server_wait_ms: deadlineActive ? this.serverWaitMs : null,
        server_wall_observed_at: deadlineActive ? this.serverWallObservedAt : null,
        server_boot_id: deadlineActive ? this.serverBootId : null,
        server_monotonic_not_before: deadlineActive ? this.serverMonotonicNotBefore : null,
        server_reboot_fallback_used: deadlineActive ? this.serverRebootFallbackUsed : false,
        operator_intervention_required: !deadlineActive,
        operator_code: deadlineActive ? null : operatorCode,
        recorded_at: diagnosticEpochSeconds(),
      })}\n`);
      this.fallbackSuppressionActive = true;
    });
    this.fallbackTransitions = transition.catch(() => {});
    return transition;
  }

  activateFailClosed(code = "reconnect-state-unavailable") {
    this.failClosed = true;
    if (this.socket && this.socket.readyState < WebSocket.CLOSING) {
      this.socket.close(4000, "reconnect state unavailable");
    }
    if (!this.failClosedWait) {
      this.failClosedWait = (async () => {
        await reportDiagnostic(code);
        safeLog("reconnect state could not be persisted; Gateway retries remain stopped");
        while (!this.stopping) await this.waitForReconnect(24 * 60 * 60_000);
        return false;
      })();
    }
    return this.failClosedWait;
  }

  async persistDurableStateOrStop() {
    if (this.failClosed) return await this.failClosedWait;
    try {
      await this.persistDurableState();
      if (this.failClosed) return await this.failClosedWait;
      return true;
    } catch {
      try {
        await this.persistFallbackSuppression();
      } catch {}
      return await this.activateFailClosed();
    }
  }

  queueSequencePersistence() {
    this.sequencePersistPending = true;
    if (this.sequencePersistTask) return;
    this.sequencePersistTask = (async () => {
      while (this.sequencePersistPending && !this.stopping && !this.failClosed) {
        this.sequencePersistPending = false;
        if (!await this.persistDurableStateOrStop()) break;
      }
    })().finally(() => {
      this.sequencePersistTask = null;
      if (this.sequencePersistPending && !this.stopping && !this.failClosed) {
        this.queueSequencePersistence();
      }
    });
  }

  async loadDurableState() {
    await ensureOwnershipDirectory();
    this.bootId = await systemBootIdentity();
    let stateNeedsRebase = false;
    const record = await readReconnectRecord();
    const legacy = record?.schema === "firstmate.discord-reconnect.v1";
    const authenticationBound = record?.schema === "firstmate.discord-reconnect.v2"
      && record.authentication_fingerprint === authenticationFingerprint(this.config);
    const limit = record?.session_start_limit;
    const resume = record?.resume_session;
    this.failurePressure = record?.failure_pressure || 0;
    this.lastConnectionAt = record?.last_connection_at ?? null;
    this.serverNotBefore = record?.server_not_before ?? null;
    this.serverWaitMs = this.serverNotBefore === null ? null : record.server_wait_ms;
    this.serverWallObservedAt = this.serverNotBefore === null
      ? null
      : record?.server_wall_observed_at
        ?? Math.max(0, this.serverNotBefore - this.serverWaitMs);
    this.serverBootId = record?.server_boot_id ?? null;
    this.serverMonotonicNotBefore = record?.server_monotonic_not_before ?? null;
    this.serverRebootFallbackUsed = record?.server_reboot_fallback_used ?? false;
    if (this.serverNotBefore !== null
        && (this.serverBootId !== this.bootId || this.serverMonotonicNotBefore === null)) {
      const now = Date.now();
      this.serverWaitMs = rebootWaitRemaining(this.serverWaitMs);
      this.serverRebootFallbackUsed = true;
      this.serverWallObservedAt = Math.max(this.serverWallObservedAt, now);
      this.serverBootId = this.bootId;
      this.serverMonotonicNotBefore = monotonicMilliseconds() + this.serverWaitMs;
      stateNeedsRebase = true;
    }
    let suppression;
    try {
      await assertPrivateFile(RECONNECT_SUPPRESSION_FILE);
      suppression = JSON.parse(await readFile(RECONNECT_SUPPRESSION_FILE, "utf8"));
    } catch (error) {
      if (error?.code !== "ENOENT") this.activateFailClosed();
    }
    if (suppression) {
      if (!validFallbackSuppression(suppression)) {
        this.activateFailClosed();
      } else if (suppression.authentication_fingerprint !== authenticationFingerprint(this.config)) {
        await removeMarker(RECONNECT_SUPPRESSION_FILE);
      } else if (suppression.operator_intervention_required) {
        this.fallbackSuppressionActive = true;
        this.activateFailClosed(suppression.operator_code || "reconnect-state-unavailable");
      } else {
        const fallbackSameBoot = suppression.server_boot_id === this.bootId
          && Number.isSafeInteger(suppression.server_monotonic_not_before);
        const fallbackPreviouslyUsed = suppression.server_reboot_fallback_used ?? false;
        const now = Date.now();
        const fallbackRemaining = fallbackSameBoot
          ? Math.max(0, suppression.server_monotonic_not_before - monotonicMilliseconds())
          : rebootWaitRemaining(suppression.server_wait_ms);
        const currentRemaining = this.serverDelayRemaining();
        if (fallbackRemaining === 0 && currentRemaining === 0) {
          try {
            await removeMarker(RECONNECT_SUPPRESSION_FILE);
          } catch {
            this.activateFailClosed();
          }
        } else {
          if (fallbackRemaining > currentRemaining) {
            this.serverWaitMs = fallbackRemaining;
            this.serverNotBefore = suppression.server_not_before;
            this.serverWallObservedAt = suppression.server_wall_observed_at
              ?? Math.max(0, suppression.server_not_before - suppression.server_wait_ms);
          } else {
            this.serverWaitMs = currentRemaining;
          }
          this.serverRebootFallbackUsed = this.serverRebootFallbackUsed
            || fallbackPreviouslyUsed || !fallbackSameBoot;
          this.serverWallObservedAt = Math.max(this.serverWallObservedAt, now);
          this.serverBootId = this.bootId;
          this.serverMonotonicNotBefore = monotonicMilliseconds() + this.serverWaitMs;
          this.fallbackSuppressionActive = true;
          stateNeedsRebase = true;
          try {
            await this.persistFallbackSuppression();
          } catch {
            this.activateFailClosed();
          }
        }
      }
    }
    this.sessionStartLimit = authenticationBound ? limit : null;
    if (this.sessionStartLimit) {
      const sameBoot = this.sessionStartLimit.resetBootId === this.bootId
        && Number.isSafeInteger(this.sessionStartLimit.resetMonotonicAt);
      if (!sameBoot) {
        const fallbackUsed = this.sessionStartLimit.resetRebootFallbackUsed ?? false;
        const conservativeWait = fallbackUsed ? 0 : this.sessionStartLimit.resetWaitMs
          ?? Math.max(0, this.sessionStartLimit.resetAt - Date.now());
        this.sessionStartLimit.resetWaitMs = conservativeWait;
        this.sessionStartLimit.resetBootId = this.bootId;
        this.sessionStartLimit.resetMonotonicAt = monotonicMilliseconds() + conservativeWait;
        this.sessionStartLimit.resetAt = Date.now() + conservativeWait;
        this.sessionStartLimit.resetRebootFallbackUsed = true;
        stateNeedsRebase = true;
      }
    }
    const resumable = authenticationBound && resume && SNOWFLAKE_RE.test(resume.self_user_id || "");
    if (resumable) {
      this.sessionId = resume.session_id;
      this.resumeUrl = resume.resume_url;
      this.sequence = resume.sequence;
      this.resumeSequence = resume.sequence;
      this.selfUserId = resume.self_user_id;
      this.sessionGeneration = 1;
    }
    if (!record || legacy || !authenticationBound || stateNeedsRebase
        || (authenticationBound && resume && !resumable)) {
      await this.persistDurableState();
    }
  }

  async updateSessionStartLimit(limit) {
    if (!limit) return true;
    const resetWaitMs = limit.resetAfter;
    const normalized = {
      total: limit.total,
      remaining: limit.remaining,
      resetAt: limit.resetAt,
      resetWaitMs,
      resetBootId: this.bootId,
      resetMonotonicAt: monotonicMilliseconds() + resetWaitMs,
      resetRebootFallbackUsed: false,
    };
    const previous = this.sessionStartLimit;
    if (previous && previous.total === normalized.total
        && previous.resetBootId === this.bootId
        && previous.resetMonotonicAt > monotonicMilliseconds()
        && Math.abs(previous.resetMonotonicAt - normalized.resetMonotonicAt) <= 5000) {
      normalized.remaining = Math.min(previous.remaining, normalized.remaining);
      if (previous.resetMonotonicAt > normalized.resetMonotonicAt) {
        normalized.resetMonotonicAt = previous.resetMonotonicAt;
        normalized.resetWaitMs = Math.max(0, previous.resetMonotonicAt - monotonicMilliseconds());
        normalized.resetAt = Date.now() + normalized.resetWaitMs;
      }
    }
    this.sessionStartLimit = normalized;
    return await this.persistDurableStateOrStop();
  }

  async reserveIdentify() {
    const limit = this.sessionStartLimit;
    if (!limit) return true;
    if (limit.remaining === 0) {
      const remaining = limit.resetBootId === this.bootId
        ? Math.max(0, limit.resetMonotonicAt - monotonicMilliseconds())
        : limit.resetWaitMs;
      if (remaining > 0) await this.waitForReconnect(remaining);
      return false;
    }
    if (TEST_MODE && process.env.FM_DISCORD_TEST_IDENTIFY_RESERVATION_DELAY_MS) {
      await sleep(testDuration("FM_DISCORD_TEST_IDENTIFY_RESERVATION_DELAY_MS", 1, 1, 1000));
      if (!this.canUseGateway()) return false;
    }
    limit.remaining -= 1;
    return await this.persistDurableStateOrStop();
  }

  serverDelayRemaining() {
    if (this.serverNotBefore === null || this.serverWaitMs === null) return 0;
    if (this.serverBootId !== this.bootId || this.serverMonotonicNotBefore === null) {
      return this.serverWaitMs;
    }
    return Math.max(0, this.serverMonotonicNotBefore - monotonicMilliseconds());
  }

  async waitForServerDelay() {
    const checkpointInterval = TEST_MODE ? 50 : 5000;
    while (this.canUseGateway()) {
      const remaining = this.serverDelayRemaining();
      if (remaining <= 0) return true;
      await this.waitForReconnect(Math.min(remaining, checkpointInterval));
      const checkpointRemaining = this.serverDelayRemaining();
      this.serverWaitMs = checkpointRemaining;
      this.serverBootId = this.bootId;
      this.serverMonotonicNotBefore = monotonicMilliseconds() + checkpointRemaining;
      this.serverWallObservedAt = Math.max(this.serverWallObservedAt, Date.now());
      if (!await this.persistDurableStateOrStop()) return false;
      if (this.fallbackSuppressionActive) {
        try {
          await this.persistFallbackSuppression();
        } catch {
          await this.activateFailClosed();
          return false;
        }
      }
    }
    return false;
  }

  retainServerDelay(milliseconds) {
    if (!Number.isFinite(milliseconds) || milliseconds <= 0) return;
    const now = Date.now();
    const delay = Math.min(Number.MAX_SAFE_INTEGER - now, Math.ceil(milliseconds));
    const retainedRemaining = this.serverDelayRemaining();
    this.serverWaitMs = Math.max(retainedRemaining, delay);
    this.serverBootId = this.bootId;
    this.serverMonotonicNotBefore = monotonicMilliseconds() + this.serverWaitMs;
    this.serverRebootFallbackUsed = false;
    this.serverWallObservedAt = now;
    this.serverNotBefore = now + this.serverWaitMs;
  }

  async retireServerDelay() {
    this.serverNotBefore = null;
    this.serverWaitMs = null;
    this.serverWallObservedAt = null;
    this.serverBootId = null;
    this.serverMonotonicNotBefore = null;
    this.serverRebootFallbackUsed = false;
    if (!await this.persistDurableStateOrStop()) return false;
    if (this.fallbackSuppressionActive) {
      try {
        await removeMarker(RECONNECT_SUPPRESSION_FILE);
        this.fallbackSuppressionActive = false;
      } catch {
        try {
          await this.persistFallbackSuppression();
        } catch {}
        await this.activateFailClosed();
        return false;
      }
    }
    return true;
  }

  reconnectDelay(serverDelayMs = this.serverDelayRemaining()) {
    return reconnectDelayMilliseconds({
      pressure: this.failurePressure,
      random: randomFraction(),
      now: Date.now(),
      lastConnectionAt: this.lastConnectionAt,
      serverDelayMs,
    });
  }

  send(payload) {
    if (this.canUseGateway() && this.socket?.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify(payload));
    }
  }

  identify() {
    if (!this.canUseGateway()) return;
    this.send({
      op: 2,
      d: {
        token: this.config.token,
        intents: 33281,
        properties: { os: process.platform, browser: "firstmate", device: "firstmate" },
      },
    });
  }

  resume() {
    if (!this.canUseGateway()) return;
    this.send({ op: 6, d: { token: this.config.token, session_id: this.sessionId, seq: this.resumeSequence } });
  }

  async connect(url) {
    if (!this.canUseGateway()) return null;
    const gateway = new URL(url);
    gateway.searchParams.set("v", "10");
    gateway.searchParams.set("encoding", "json");
    return await new Promise((resolvePromise, rejectPromise) => {
      let heartbeatTimeout = null;
      let heartbeatInterval = null;
      let handshakeTimeout = null;
      let stableTimeout = null;
      let heartbeatAcknowledged = true;
      let heartbeatAcks = 0;
      let opened = false;
      let ready = false;
      let stable = false;
      let readyAt = 0;
      let serverDelayMs = 0;
      let settled = false;
      let checkpointBlocked = false;
      const clearTimers = () => {
        if (heartbeatTimeout) clearTimeout(heartbeatTimeout);
        if (heartbeatInterval) clearInterval(heartbeatInterval);
        if (handshakeTimeout) clearTimeout(handshakeTimeout);
        if (stableTimeout) clearTimeout(stableTimeout);
      };
      const finish = (result) => {
        if (settled) return;
        settled = true;
        clearTimers();
        resolvePromise(result);
      };
      const markStable = () => {
        if (stable || !ready || settled || this.socket !== socket || socket.readyState !== WebSocket.OPEN) return;
        stable = true;
        this.failurePressure = 0;
        const stableDiagnosticGeneration = diagnosticGeneration;
        void this.persistDurableState()
          .then(() => clearDiagnostic(stableDiagnosticGeneration))
          .catch(() => reportDiagnostic("reconnect-state-unavailable"));
      };
      const markReady = () => {
        if (settled || this.socket !== socket || socket.readyState !== WebSocket.OPEN) return;
        ready = true;
        readyAt = Date.now();
        this.connected = true;
        if (handshakeTimeout) clearTimeout(handshakeTimeout);
        handshakeTimeout = null;
        stableTimeout = setTimeout(markStable, STABLE_CONNECTION_MS);
        writeMarker(READY_FILE, "connected").catch(() => safeLog("cannot publish the ready marker"));
      };
      let socket;
      try {
        if (!this.canUseGateway()) {
          finish(null);
          return;
        }
        socket = new WebSocket(gateway);
      } catch (error) {
        rejectPromise(error);
        return;
      }
      this.socket = socket;
      handshakeTimeout = setTimeout(() => socket.close(4000, "gateway handshake timeout"), 15_000);
      socket.addEventListener("open", () => { opened = true; });
      socket.addEventListener("message", (event) => {
        let packet;
        try {
          packet = JSON.parse(String(event.data));
        } catch {
          socket.close(4002, "invalid payload");
          return;
        }
        if (Number.isInteger(packet.s)) this.sequence = packet.s;
        switch (packet.op) {
          case 10: {
            if (handshakeTimeout) clearTimeout(handshakeTimeout);
            handshakeTimeout = setTimeout(() => socket.close(4000, "gateway ready timeout"), 30_000);
            const interval = Number(packet.d?.heartbeat_interval);
            if (!Number.isFinite(interval) || interval < 50) {
              socket.close(4002, "invalid hello");
              return;
            }
            const beat = () => {
              if (!heartbeatAcknowledged) {
                socket.close(4000, "heartbeat timeout");
                return;
              }
              heartbeatAcknowledged = false;
              this.send({ op: 1, d: this.sequence });
            };
            heartbeatTimeout = setTimeout(() => {
              beat();
              heartbeatInterval = setInterval(beat, interval);
            }, Math.floor(randomFraction() * interval));
            if (!this.canUseGateway()) {
              socket.close(4000, "Gateway retries stopped");
              return;
            }
            if (this.sessionId) this.resume(); else this.identify();
            break;
          }
          case 11:
            heartbeatAcknowledged = true;
            heartbeatAcks += 1;
            if (ready && heartbeatAcks >= 3 && Date.now() - readyAt >= HEARTBEAT_STABLE_MS) markStable();
            break;
          case 1:
            this.send({ op: 1, d: this.sequence });
            break;
          case 7:
            socket.close(4000, "server reconnect");
            break;
          case 9:
            serverDelayMs = TEST_MODE && process.env.FM_DISCORD_TEST_INVALID_SESSION_MS
              ? testDuration("FM_DISCORD_TEST_INVALID_SESSION_MS", 1000, 1, 1000)
              : 1000 + Math.floor(randomFraction() * 4001);
            if (packet.d !== true) this.clearSession();
            this.retainServerDelay(serverDelayMs);
            void this.persistDurableStateOrStop().then((persisted) => {
              if (persisted) socket.close(4000, "invalid session");
            });
            break;
          case 0:
            if (packet.t === "READY") {
              const userId = String(packet.d?.user?.id || "");
              const sessionId = String(packet.d?.session_id || "");
              const resumeUrl = String(packet.d?.resume_gateway_url || "");
              if (!SNOWFLAKE_RE.test(userId) || !sessionId || !resumeUrl) {
                socket.close(4002, "invalid ready");
                return;
              }
              try {
                validateProductionEndpoint(resumeUrl, "gateway");
              } catch {
                socket.close(4002, "invalid resume endpoint");
                return;
              }
              if (this.sessionId !== sessionId) this.sessionGeneration += 1;
              this.selfUserId = userId;
              this.sessionId = sessionId;
              this.resumeUrl = resumeUrl;
              this.resumeSequence = Number.isInteger(packet.s) ? packet.s : this.resumeSequence;
              void this.persistDurableStateOrStop().then((persisted) => {
                if (persisted) markReady();
              });
            } else if (packet.t === "RESUMED") {
              markReady();
              if (Number.isInteger(packet.s)) {
                const originGeneration = this.sessionGeneration;
                this.inbound = this.inbound.then(() => {
                  if (checkpointBlocked || this.sessionGeneration !== originGeneration) return;
                  this.resumeSequence = packet.s;
                  this.queueSequencePersistence();
                });
              }
            } else if (packet.t === "MESSAGE_CREATE" && this.selfUserId) {
              const dispatchSequence = packet.s;
              const originGeneration = this.sessionGeneration;
              const originSelfUserId = this.selfUserId;
              this.inbound = this.inbound.then(async () => {
                if (checkpointBlocked || this.sessionGeneration !== originGeneration) return;
                if (TEST_MODE && process.env.FM_DISCORD_TEST_INGEST_DELAY_MS) {
                  await sleep(testDuration("FM_DISCORD_TEST_INGEST_DELAY_MS", 1, 1, 1000));
                  if (this.sessionGeneration !== originGeneration) return;
                }
                await ingestMessage(packet.d, this.config, originSelfUserId);
                if (Number.isInteger(dispatchSequence) && this.sessionGeneration === originGeneration) {
                  this.resumeSequence = dispatchSequence;
                  this.queueSequencePersistence();
                }
              }).catch(async () => {
                checkpointBlocked = true;
                await reportDiagnostic("inbox-publication-failed");
                if (socket.readyState < WebSocket.CLOSING) socket.close(4000, "inbox publication failed");
              });
            } else if (Number.isInteger(packet.s)) {
              const originGeneration = this.sessionGeneration;
              this.inbound = this.inbound.then(() => {
                if (checkpointBlocked || this.sessionGeneration !== originGeneration) return;
                this.resumeSequence = packet.s;
                this.queueSequencePersistence();
              });
            }
            break;
          default:
            break;
        }
      });
      socket.addEventListener("error", () => {
        // Close drives the bounded reconnect path; browser-style WebSocket
        // errors intentionally carry no raw diagnostic into logs.
      });
      socket.addEventListener("close", (event) => {
        this.connected = false;
        if (this.socket === socket) this.socket = null;
        removeMarker(READY_FILE).catch(() => {});
        const complete = async () => {
          if ([4007, 4009].includes(event.code)) {
            this.clearSession();
            if (!await this.persistDurableStateOrStop()) {
              finish({ opened, ready, stable, code: event.code, terminalCode: "", serverDelayMs });
              return;
            }
          }
          finish({
            opened,
            ready,
            stable,
            code: event.code,
            terminalCode: terminalDiagnosticForClose(event.code),
            serverDelayMs,
          });
        };
        void complete();
      });
    });
  }

  async suppressTerminal(code) {
    try {
      await writeTerminalSuppression(this.config, code);
    } catch {
      try {
        await this.persistFallbackSuppression(code);
      } catch {}
      await reportDiagnostic(code);
      safeLog("terminal reconnect suppression could not be persisted; Gateway retries remain stopped");
      while (!this.stopping) await this.waitForReconnect(24 * 60 * 60_000);
      return;
    }
    await reportDiagnostic(code);
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const current = await readDiagnostic(ERROR_FILE).catch(() => null);
      const notified = await readDiagnostic(ERROR_NOTIFIED_FILE).catch(() => null);
      if (current?.incidentId && current.incidentId === notified?.incidentId) break;
      await this.waitForReconnect(Math.min(1000, RECONCILE_INTERVAL_MS));
      if (this.stopping) break;
      await reconcileDiagnostic();
    }
  }

  async run() {
    try {
      await this.loadDurableState();
    } catch (error) {
      if (!(error instanceof ConfigError)) throw error;
      await this.suppressTerminal("reconnect-state-invalid");
      return;
    }
    await writeMarker(ENABLED_FILE, "enabled");
    await pruneContexts();
    await reconcileInbox(this.config);
    const pruneTimer = setInterval(() => pruneContexts(), 6 * 60 * 60 * 1000);
    pruneTimer.unref?.();
    let reconciliationRunning = false;
    const reconcileTimer = setInterval(() => {
      if (reconciliationRunning || this.stopping) return;
      reconciliationRunning = true;
      this.inbound = this.inbound
        .then(() => reconcileInbox(this.config))
        .catch(() => safeLog("pending Discord inbox reconciliation will be retried"));
      void this.inbound.then(() => {
        reconciliationRunning = false;
      });
    }, RECONCILE_INTERVAL_MS);
    reconcileTimer.unref?.();
    safeLog("service started");
    if (this.failClosed) await this.failClosedWait;
    if (this.failurePressure > 0 || this.serverNotBefore !== null) {
      if (this.serverNotBefore !== null) {
        if (await this.waitForServerDelay()) await this.retireServerDelay();
      }
      if (this.canUseGateway() && this.failurePressure > 0) {
        await this.waitForReconnect(this.reconnectDelay(0));
      }
    }
    while (this.canUseGateway()) {
      if (this.serverNotBefore !== null) {
        if (!await this.waitForServerDelay() || !await this.retireServerDelay()) break;
      }
      if (!this.canUseGateway()) break;
      let gateway;
      try {
        gateway = this.resumeUrl
          ? { url: this.resumeUrl, sessionStartLimit: null }
          : await gatewayUrl(this.config);
        if (!this.canUseGateway()) break;
        if (!await this.updateSessionStartLimit(gateway.sessionStartLimit)) break;
      } catch (error) {
        if (error instanceof DiscordHttpError && [401, 403].includes(error.status)) {
          await this.suppressTerminal("authentication-rejected");
          break;
        }
        if (error instanceof ConfigError) {
          await this.suppressTerminal("gateway-configuration-invalid");
          break;
        }
        await reportDiagnostic("discord-api-unavailable");
        this.failurePressure += 1;
        if (error instanceof DiscordHttpError) this.retainServerDelay(error.retryAfterMs);
        if (!await this.persistDurableStateOrStop()) break;
        if (this.serverNotBefore !== null
            && (!await this.waitForServerDelay() || !await this.retireServerDelay())) break;
        await this.waitForReconnect(this.reconnectDelay(0));
        if (!this.canUseGateway()) break;
        continue;
      }
      if (!this.canUseGateway()) break;
      if (!this.sessionId && !await this.reserveIdentify()) {
        if (this.canUseGateway()) continue;
        break;
      }
      if (!this.canUseGateway()) break;
      try {
        this.failurePressure += 1;
        this.lastConnectionAt = Date.now();
        if (!await this.persistDurableStateOrStop() || !this.canUseGateway()) break;
        const result = await this.connect(gateway.url);
        if (!result || !this.canUseGateway()) break;
        if (result.terminalCode) {
          await this.suppressTerminal(result.terminalCode);
          break;
        }
      } catch {
        if (!this.canUseGateway()) break;
        await reportDiagnostic("gateway-connect-failed");
      }
      if (!this.canUseGateway()) break;
      if (this.serverNotBefore !== null
          && (!await this.waitForServerDelay() || !await this.retireServerDelay())) break;
      await this.waitForReconnect(this.reconnectDelay(0));
      if (!this.canUseGateway()) break;
    }
    clearInterval(pruneTimer);
    clearInterval(reconcileTimer);
    await this.inbound;
    if (this.sequencePersistTask) await this.sequencePersistTask;
    await this.durableTransitions;
    await this.fallbackTransitions;
    await diagnosticTransitions;
    safeLog("service stopped");
  }
}

async function readReplyText(path) {
  let text;
  if (path === "-") {
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    text = Buffer.concat(chunks).toString("utf8");
  } else {
    text = await readFile(path, "utf8");
  }
  text = text.trim();
  const length = [...text].length;
  if (length < 1) throw new ConfigError("Discord reply text is empty");
  if (length > MAX_REPLY_CHARS) {
    throw new ConfigError(`Discord reply exceeds the ${MAX_REPLY_CHARS}-character public-safe limit`);
  }
  return text;
}

async function loadBoundContext(messageId, config) {
  if (!SNOWFLAKE_RE.test(messageId)) throw new ConfigError("invalid Discord message id");
  await assertPlainDirectory(CONTEXT_DIR, 0o700);
  const path = join(CONTEXT_DIR, `${messageId}.json`);
  await assertPrivateFile(path);
  const context = JSON.parse(await readFile(path, "utf8"));
  if (!contextRecordIsBound(context, messageId, config)) {
    throw new ConfigError("Discord reply binding does not match the configured conversation boundary");
  }
  return context;
}

async function postReply(config, context, text, scope) {
  validateProductionEndpoint(API_BASE, "api");
  const nonce = `${scope === "final" ? "f" : "a"}${context.message_id}`;
  const payload = {
    content: text,
    nonce,
    enforce_nonce: true,
    message_reference: {
      message_id: context.message_id,
      channel_id: context.channel_id,
      guild_id: context.guild_id,
      fail_if_not_exists: false,
    },
    allowed_mentions: { parse: [], replied_user: false },
  };
  const endpoint = `${API_BASE}/channels/${encodeURIComponent(context.channel_id)}/messages`;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    let response;
    try {
      response = await fetchWithTimeout(endpoint, {
        method: "POST",
        headers: {
          Authorization: `Bot ${config.token}`,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: JSON.stringify(payload),
      });
    } catch {
      if (attempt === 0) {
        await sleep(500);
        continue;
      }
      throw new Error("Discord reply outcome is unknown after a bounded retry");
    }
    if (response.ok) return;
    if (response.status === 429 && attempt === 0) {
      let retryAfter = 1;
      try {
        const body = await response.json();
        retryAfter = Number(body.retry_after) || 1;
      } catch {}
      await sleep(Math.min(10_000, Math.max(100, Math.ceil(retryAfter * 1000))));
      continue;
    }
    if (response.status >= 500 && attempt === 0) {
      await sleep(500);
      continue;
    }
    if ([401, 403].includes(response.status)) throw new Error("Discord rejected the bot authentication or channel permission");
    if (response.status === 404) throw new Error("the bound Discord conversation is no longer available");
    throw new Error(`Discord rejected the reply with HTTP ${response.status}`);
  }
}

async function markReplySent(messageId, scope) {
  await atomicPublishPrivateOnce(
    CONTEXT_DIR,
    `${messageId}.${scope}.sent`,
    `${Math.floor(Date.now() / 1000)}\n`,
  );
}

async function replyAlreadySent(messageId, scope) {
  try {
    await assertPrivateFile(join(CONTEXT_DIR, `${messageId}.${scope}.sent`));
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function removeAnsweredInbox(messageId) {
  const path = join(INBOX_DIR, `${messageId}.json`);
  try {
    await assertPrivateFile(path);
    await unlink(path);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

function parseSendArguments(args) {
  const messageId = args.shift() || "";
  let textFile = "";
  let scope = "initial";
  while (args.length) {
    const arg = args.shift();
    if (arg === "--text-file" && args.length) textFile = args.shift();
    else if (arg === "--nonce-scope" && args.length) scope = args.shift();
    else throw new ConfigError("invalid send arguments");
  }
  if (!textFile) throw new ConfigError("send requires --text-file <path|->");
  if (!["initial", "final"].includes(scope)) throw new ConfigError("invalid Discord reply nonce scope");
  return { messageId, textFile, scope };
}

async function main() {
  const [command = "", ...args] = process.argv.slice(2);
  if (typeof globalThis.WebSocket !== "function" && command === "run") {
    throw new ConfigError("Node.js with built-in WebSocket support is required (Node 22 or newer)");
  }
  switch (command) {
    case "validate": {
      await loadConfig();
      process.stdout.write("self-hosted Discord configuration is valid\n");
      return;
    }
    case "terminal-check": {
      const config = await loadConfig();
      const code = await activeTerminalSuppression(config);
      if (code) {
        process.stdout.write(`${code}\n`);
        process.exitCode = 4;
      }
      return;
    }
    case "terminal-reset": {
      await loadConfig();
      try {
        await readReconnectRecord();
      } catch (error) {
        if (!(error instanceof ConfigError)) throw error;
        await assertPrivateFile(RECONNECT_FILE);
        const quarantineFile = join(OWNERSHIP_DIR, "reconnect.invalid.json");
        try {
          await lstat(quarantineFile);
          throw new ConfigError("invalid reconnect state must be repaired before suppression can be cleared");
        } catch (quarantineError) {
          if (quarantineError?.code !== "ENOENT") throw quarantineError;
        }
        await rename(RECONNECT_FILE, quarantineFile);
        safeLog("invalid reconnect state quarantined for operator inspection");
      }
      await removeMarker(TERMINAL_FILE);
      await removeMarker(RECONNECT_SUPPRESSION_FILE);
      await clearDiagnostic();
      return;
    }
    case "run": {
      const config = await loadConfig();
      const suppressedCode = await activeTerminalSuppression(config);
      if (suppressedCode) {
        await reportDiagnostic(suppressedCode);
        safeLog(`reconnects stopped: ${suppressedCode}; operator intervention is required`);
        return;
      }
      let lease = null;
      let runner = null;
      let stopping = false;
      const stop = () => {
        stopping = true;
        runner?.stop();
        removeMarker(READY_FILE).catch(() => {});
        removeMarker(ENABLED_FILE).catch(() => {});
        const forcedExit = setTimeout(() => process.exit(0), 5000);
        forcedExit.unref();
      };
      process.once("SIGINT", stop);
      process.once("SIGTERM", stop);
      process.once("SIGHUP", stop);
      try {
        lease = await requireGatewayOwnership();
        if (stopping) return;
        runner = new GatewayRunner(config);
        await runner.run();
      } finally {
        await removeMarker(READY_FILE).catch(() => {});
        await removeMarker(ENABLED_FILE).catch(() => {});
        if (lease) await releaseGatewayOwnership(lease);
      }
      return;
    }
    case "send": {
      const { messageId, textFile, scope } = parseSendArguments(args);
      const config = await loadConfig();
      const context = await loadBoundContext(messageId, config);
      if (await replyAlreadySent(messageId, scope)) {
        await removeAnsweredInbox(messageId);
        process.stdout.write("Discord reply already sent\n");
        return;
      }
      const text = await readReplyText(textFile);
      await postReply(config, context, text, scope);
      await markReplySent(messageId, scope);
      await removeAnsweredInbox(messageId);
      process.stdout.write("Discord reply sent\n");
      return;
    }
    case "context-check": {
      const messageId = args.shift() || "";
      if (args.length) throw new ConfigError("context-check accepts one message id");
      const config = await loadConfig();
      await loadBoundContext(messageId, config);
      return;
    }
    case "prune": {
      if (!TEST_MODE || args.length) throw new ConfigError("prune is available only in hermetic test mode");
      await pruneContexts();
      return;
    }
    case "reconnect-policy": {
      if (!TEST_MODE) throw new ConfigError("reconnect-policy is available only in hermetic test mode");
      const fixtureFile = args.shift() || "";
      if (!fixtureFile || args.length) throw new ConfigError("test reconnect-policy requires one fixture file");
      const fixture = JSON.parse(await readFile(fixtureFile, "utf8"));
      process.stdout.write(`${JSON.stringify(simulateReconnectPolicy(fixture))}\n`);
      return;
    }
    case "reboot-wait-policy": {
      if (!TEST_MODE) throw new ConfigError("reboot-wait-policy is available only in hermetic test mode");
      const fixtureFile = args.shift() || "";
      if (!fixtureFile || args.length) throw new ConfigError("test reboot-wait-policy requires one fixture file");
      const fixture = JSON.parse(await readFile(fixtureFile, "utf8"));
      process.stdout.write(`${JSON.stringify(simulateRebootWaitPolicy(fixture))}\n`);
      return;
    }
    case "ingest": {
      if (!TEST_MODE) throw new ConfigError("ingest is available only in hermetic test mode");
      const eventFile = args.shift() || "";
      const selfUserId = process.env.FM_DISCORD_TEST_SELF_USER_ID || "";
      if (!eventFile || args.length) throw new ConfigError("test ingest requires one event file");
      const config = await loadConfig();
      const event = JSON.parse(await readFile(eventFile, "utf8"));
      const outcome = await ingestMessage(event, config, selfUserId);
      process.stdout.write(`${outcome}\n`);
      return;
    }
    default:
      throw new ConfigError("usage: fm-discord-bot.mjs validate|run|send|context-check");
  }
}

main().catch((error) => {
  if (error instanceof DisabledError) {
    safeLog("disabled: no self-hosted Discord configuration");
    process.exitCode = 3;
    return;
  }
  if (error instanceof ConfigError) {
    safeLog(`configuration refused: ${error.message}`);
    process.exitCode = 2;
    return;
  }
  safeLog(error?.message || "operation failed");
  process.exitCode = 1;
});
