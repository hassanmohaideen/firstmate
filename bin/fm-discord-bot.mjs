#!/usr/bin/env node
// Self-hosted Discord transport runtime.
//
// This program is deliberately narrow: it owns Discord Gateway/REST I/O,
// strict local configuration, owner/guild/channel/mention authorization,
// private inbox/context publication, reconnects, and secret-safe diagnostics.
// It delegates notification publication to bin/fm-discord-notify.sh so the
// existing durable wake queue remains the only Firstmate notification plane.
//
// Operator lifecycle is owned by bin/fm-discord-bot.sh. Direct use:
//   fm-discord-bot.mjs validate
//   fm-discord-bot.mjs run
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
  rename,
  rm,
  stat,
  unlink,
} from "node:fs/promises";
import { spawn } from "node:child_process";
import { dirname, join, resolve } from "node:path";
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
const NOTIFIER = join(ROOT, "bin", "fm-discord-notify.sh");
const TEST_MODE = process.env.FM_DISCORD_TEST_MODE === "1";
const API_BASE = TEST_MODE && process.env.FM_DISCORD_TEST_API_BASE
  ? process.env.FM_DISCORD_TEST_API_BASE.replace(/\/$/, "")
  : "https://discord.com/api/v10";
const TEST_GATEWAY_URL = TEST_MODE ? process.env.FM_DISCORD_TEST_GATEWAY_URL || "" : "";
const MAX_REPLY_CHARS = 1900;
const RETENTION_SECONDS = 7 * 24 * 60 * 60;
const CONFIG_KEYS = [
  "FM_DISCORD_BOT_TOKEN",
  "FM_DISCORD_OWNER_USER_ID",
  "FM_DISCORD_GUILD_ID",
  "FM_DISCORD_CHANNEL_ID",
];
const SNOWFLAKE_RE = /^[0-9]{15,22}$/;
const SAFE_CODE_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;

class DisabledError extends Error {}
class ConfigError extends Error {}
class DiscordHttpError extends Error {
  constructor(status) {
    super(`Discord HTTP ${status}`);
    this.status = status;
  }
}

function safeLog(message) {
  process.stderr.write(`[discord-bot] ${message}\n`);
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
  if (TEST_MODE) return parsed;
  if (kind === "api") {
    if (parsed.protocol !== "https:" || parsed.hostname !== "discord.com") {
      throw new ConfigError("Discord API endpoint is not the fixed authenticated Discord endpoint");
    }
  } else if (parsed.protocol !== "wss:" || parsed.hostname !== "gateway.discord.gg") {
    throw new ConfigError("Discord Gateway endpoint is not the fixed Discord Gateway endpoint");
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

async function reportDiagnostic(code) {
  if (!SAFE_CODE_RE.test(code)) code = "discord-service-error";
  let previous = "";
  try {
    await assertPrivateFile(ERROR_FILE);
    previous = JSON.parse(await readFile(ERROR_FILE, "utf8")).code || "";
  } catch (error) {
    if (error?.code !== "ENOENT" && !(error instanceof SyntaxError)) {
      safeLog("cannot inspect the existing diagnostic safely");
      return;
    }
  }
  if (previous === code) return;
  await atomicReplacePrivate(ERROR_FILE, `${JSON.stringify({ code, recorded_at: Math.floor(Date.now() / 1000) })}\n`);
  try {
    await notify("error", code);
  } catch {
    safeLog("cannot publish the Discord diagnostic to Firstmate");
  }
}

async function clearDiagnostic() {
  try {
    await removeMarker(ERROR_FILE);
  } catch {
    safeLog("cannot clear the recovered Discord diagnostic");
  }
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

async function pruneContexts() {
  try {
    await ensurePrivateDirectory(CONTEXT_DIR);
    await ensurePrivateDirectory(INBOX_DIR);
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
    return TEST_GATEWAY_URL;
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
  if (!response.ok) throw new DiscordHttpError(response.status);
  const body = await response.json();
  validateProductionEndpoint(body.url, "gateway");
  return body.url;
}

function backoffMilliseconds(attempt) {
  if (TEST_MODE && /^[0-9]+$/.test(process.env.FM_DISCORD_TEST_BACKOFF_MS || "")) {
    return Math.max(1, Math.min(1000, Number(process.env.FM_DISCORD_TEST_BACKOFF_MS)));
  }
  const exponent = Math.min(6, Math.max(0, attempt));
  const base = Math.min(60_000, 1000 * (2 ** exponent));
  return Math.min(60_000, Math.floor(base * (0.75 + Math.random() * 0.5)));
}

function sleep(milliseconds) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));
}

class GatewayRunner {
  constructor(config) {
    this.config = config;
    this.stopping = false;
    this.socket = null;
    this.sessionId = "";
    this.resumeUrl = "";
    this.sequence = null;
    this.selfUserId = "";
    this.attempt = 0;
    this.connected = false;
    this.inbound = Promise.resolve();
    this.backoffTimer = null;
    this.backoffResolve = null;
  }

  stop() {
    this.stopping = true;
    if (this.backoffTimer) clearTimeout(this.backoffTimer);
    this.backoffTimer = null;
    if (this.backoffResolve) this.backoffResolve();
    this.backoffResolve = null;
    if (this.socket && this.socket.readyState < WebSocket.CLOSING) {
      this.socket.close(1000, "shutdown");
    }
  }

  async waitForReconnect(milliseconds) {
    if (this.stopping) return;
    await new Promise((resolvePromise) => {
      this.backoffResolve = resolvePromise;
      this.backoffTimer = setTimeout(resolvePromise, milliseconds);
    });
    this.backoffTimer = null;
    this.backoffResolve = null;
  }

  send(payload) {
    if (this.socket?.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify(payload));
    }
  }

  identify() {
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
    this.send({ op: 6, d: { token: this.config.token, session_id: this.sessionId, seq: this.sequence } });
  }

  async connect(url) {
    const gateway = new URL(url);
    gateway.searchParams.set("v", "10");
    gateway.searchParams.set("encoding", "json");
    return await new Promise((resolvePromise, rejectPromise) => {
      let heartbeatTimeout = null;
      let heartbeatInterval = null;
      let handshakeTimeout = null;
      let heartbeatAcknowledged = true;
      let opened = false;
      let ready = false;
      let settled = false;
      const clearHeartbeat = () => {
        if (heartbeatTimeout) clearTimeout(heartbeatTimeout);
        if (heartbeatInterval) clearInterval(heartbeatInterval);
        if (handshakeTimeout) clearTimeout(handshakeTimeout);
      };
      const finish = (result) => {
        if (settled) return;
        settled = true;
        clearHeartbeat();
        resolvePromise(result);
      };
      let socket;
      try {
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
            }, Math.floor(Math.random() * interval));
            if (this.sessionId) this.resume(); else this.identify();
            break;
          }
          case 11:
            heartbeatAcknowledged = true;
            break;
          case 1:
            this.send({ op: 1, d: this.sequence });
            break;
          case 7:
            socket.close(4000, "server reconnect");
            break;
          case 9:
            if (packet.d !== true) {
              this.sessionId = "";
              this.resumeUrl = "";
              this.sequence = null;
            }
            socket.close(4000, "invalid session");
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
              this.selfUserId = userId;
              this.sessionId = sessionId;
              this.resumeUrl = resumeUrl;
              ready = true;
              this.connected = true;
              if (handshakeTimeout) clearTimeout(handshakeTimeout);
              handshakeTimeout = null;
              writeMarker(READY_FILE, "connected").catch(() => safeLog("cannot publish the ready marker"));
              clearDiagnostic();
            } else if (packet.t === "RESUMED") {
              ready = true;
              this.connected = true;
              if (handshakeTimeout) clearTimeout(handshakeTimeout);
              handshakeTimeout = null;
              writeMarker(READY_FILE, "connected").catch(() => safeLog("cannot publish the ready marker"));
              clearDiagnostic();
            } else if (packet.t === "MESSAGE_CREATE" && this.selfUserId) {
              this.inbound = this.inbound
                .then(() => ingestMessage(packet.d, this.config, this.selfUserId))
                .catch(() => reportDiagnostic("inbox-publication-failed"));
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
        removeMarker(READY_FILE).catch(() => {});
        if ([4007, 4009].includes(event.code)) {
          this.sessionId = "";
          this.resumeUrl = "";
          this.sequence = null;
        }
        if ([4004].includes(event.code)) reportDiagnostic("authentication-rejected");
        if ([4013].includes(event.code)) reportDiagnostic("gateway-intents-invalid");
        if ([4014].includes(event.code)) reportDiagnostic("message-content-intent-disabled");
        finish({ opened, ready, code: event.code });
      });
    });
  }

  async run() {
    await writeMarker(ENABLED_FILE, "enabled");
    await pruneContexts();
    await reconcileInbox(this.config);
    const pruneTimer = setInterval(() => pruneContexts(), 6 * 60 * 60 * 1000);
    pruneTimer.unref?.();
    safeLog("service started");
    while (!this.stopping) {
      let url;
      try {
        url = this.resumeUrl || await gatewayUrl(this.config);
      } catch (error) {
        if (error instanceof DiscordHttpError && [401, 403].includes(error.status)) {
          await reportDiagnostic("authentication-rejected");
        } else {
          await reportDiagnostic("discord-api-unavailable");
        }
        await this.waitForReconnect(backoffMilliseconds(this.attempt++));
        continue;
      }
      try {
        const result = await this.connect(url);
        if (result.ready) this.attempt = 0;
        else this.attempt += 1;
      } catch {
        await reportDiagnostic("gateway-connect-failed");
        this.attempt += 1;
      }
      if (!this.stopping) await this.waitForReconnect(backoffMilliseconds(this.attempt));
    }
    clearInterval(pruneTimer);
    await this.inbound;
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
    case "run": {
      const config = await loadConfig();
      const runner = new GatewayRunner(config);
      const stop = () => {
        runner.stop();
        removeMarker(READY_FILE).catch(() => {});
        removeMarker(ENABLED_FILE).catch(() => {});
        const forcedExit = setTimeout(() => process.exit(0), 5000);
        forcedExit.unref();
      };
      process.once("SIGINT", stop);
      process.once("SIGTERM", stop);
      process.once("SIGHUP", stop);
      try {
        await runner.run();
      } finally {
        await removeMarker(READY_FILE).catch(() => {});
        await removeMarker(ENABLED_FILE).catch(() => {});
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
