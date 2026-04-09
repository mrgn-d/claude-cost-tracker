#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const COST_TRACKER_DIR = process.env.COST_TRACKER_DIR || path.join(os.homedir(), '.claude', 'cost-tracker');
const PROJECTS_DIR = path.join(os.homedir(), '.claude', 'projects');
const CONFIG_PATH = path.join(COST_TRACKER_DIR, 'config.json');
const COSTS_JSONL_PATH = path.join(COST_TRACKER_DIR, 'costs.jsonl');
const LAST_HARVEST_PATH = path.join(COST_TRACKER_DIR, 'last-harvest.json');

const FALLBACK_PRICING = {
  input: 3.0,
  output: 15.0,
  cacheRead: 0.375,
  cacheWrite: 3.75
};

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (_) {
    return null;
  }
}

function writeJson(filePath, data) {
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2) + '\n', 'utf8');
}

function computeCost(inputTokens, outputTokens, cacheRead, cacheWrite, pricing) {
  const M = 1_000_000;
  return (
    (inputTokens * pricing.input / M) +
    (outputTokens * pricing.output / M) +
    (cacheRead * pricing.cacheRead / M) +
    (cacheWrite * pricing.cacheWrite / M)
  );
}

/** Scan a session JSONL file and return per-model usage totals. */
function sumSessionUsage(filePath) {
  const byModel = {};
  let sessionId = null;
  let firstTimestamp = null;
  let cwd = null;
  let gitBranch = null;
  let firstPrompt = null;

  try {
    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split('\n').filter(Boolean);

    for (const line of lines) {
      const obj = JSON.parse(line);

      if (!sessionId && obj.sessionId) {
        sessionId = obj.sessionId;
      }
      if (!firstTimestamp && obj.timestamp) {
        firstTimestamp = obj.timestamp;
      }
      if (!cwd && obj.cwd) {
        cwd = obj.cwd;
      }
      if (!gitBranch && obj.gitBranch) {
        gitBranch = obj.gitBranch;
      }
      if (!firstPrompt && obj.type === 'user' && obj.message) {
        const msg = typeof obj.message === 'string' ? obj.message : (obj.message.content || '');
        // Strip system/XML tags and leading prompt chars, take first 80 chars
        const clean = (typeof msg === 'string' ? msg : '').replace(/<[^>]+>[^<]*/g, '').replace(/^[\s❯>]+/, '').trim();
        if (clean.length > 0) {
          firstPrompt = clean.slice(0, 80);
        }
      }

      if (obj.type === 'assistant' && obj.message && obj.message.usage) {
        const model = obj.message.model || 'unknown';
        const u = obj.message.usage;

        if (!byModel[model]) {
          byModel[model] = { inputTokens: 0, outputTokens: 0, cacheRead: 0, cacheWrite: 0 };
        }
        byModel[model].inputTokens += u.input_tokens || 0;
        byModel[model].outputTokens += u.output_tokens || 0;
        byModel[model].cacheRead += u.cache_read_input_tokens || 0;
        byModel[model].cacheWrite += u.cache_creation_input_tokens || 0;
      }
    }
  } catch (_) {
    return null;
  }

  return { byModel, sessionId, firstTimestamp, cwd, gitBranch, firstPrompt };
}

/** Find all session JSONL files across all project directories. */
function findSessionFiles(sinceMs) {
  const results = [];

  try {
    const projectDirs = fs.readdirSync(PROJECTS_DIR, { withFileTypes: true })
      .filter(d => d.isDirectory())
      .map(d => path.join(PROJECTS_DIR, d.name));

    for (const dir of projectDirs) {
      try {
        const files = fs.readdirSync(dir)
          .filter(f => f.endsWith('.jsonl'));

        for (const f of files) {
          const fullPath = path.join(dir, f);
          const stat = fs.statSync(fullPath);
          if (stat.mtimeMs > sinceMs) {
            // Session ID is the filename without extension
            const sessionId = path.basename(f, '.jsonl');
            results.push({ path: fullPath, sessionId, projectDir: dir, mtimeMs: stat.mtimeMs });
          }
        }
      } catch (_) {
        // Skip unreadable directories
      }
    }
  } catch (_) {}

  return results;
}

function getProjectFromPath(p) {
  if (!p) return 'unknown';
  const home = os.homedir();
  let rel = p.startsWith(home) ? p.slice(home.length + 1) : p;
  // Strip common dev path prefixes to get org/repo
  rel = rel.replace(/^(dev\/github\.com\/|src\/|projects\/|code\/|workspace\/)/, '');
  // Strip .claude/projects/ encoded paths
  rel = rel.replace(/^\.claude\/projects\//, '');
  const parts = rel.replace(/^\//, '').split('/').filter(Boolean);
  return parts.length >= 2 ? parts.slice(0, 2).join('/') : parts.join('/') || 'unknown';
}

async function main() {
  const config = readJson(CONFIG_PATH);
  if (!config) return;

  const lastHarvest = readJson(LAST_HARVEST_PATH) || {};
  const lastHarvestTime = lastHarvest.harvestedAt ? new Date(lastHarvest.harvestedAt).getTime() : 0;
  const pricing = config.pricing || {};
  const harvestedAt = new Date().toISOString();

  // Find session files modified since last harvest (re-scans active sessions too)
  const sessionFiles = findSessionFiles(lastHarvestTime);

  // Load existing costs so we can replace stale entries for re-harvested sessions
  let existingCosts = [];
  try {
    existingCosts = fs.readFileSync(COSTS_JSONL_PATH, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l));
  } catch (_) {}

  const entries = [];
  const harvestedIds = new Set();

  for (const sf of sessionFiles) {
    const usage = sumSessionUsage(sf.path);
    if (!usage) continue;

    const project = getProjectFromPath(usage.cwd || sf.projectDir);
    const sid = usage.sessionId || sf.sessionId;

    for (const [model, tokens] of Object.entries(usage.byModel)) {
      if (tokens.inputTokens === 0 && tokens.outputTokens === 0 &&
          tokens.cacheRead === 0 && tokens.cacheWrite === 0) {
        continue;
      }

      const modelPricing = pricing[model] || FALLBACK_PRICING;
      const estimatedCost = computeCost(
        tokens.inputTokens, tokens.outputTokens,
        tokens.cacheRead, tokens.cacheWrite,
        modelPricing
      );

      entries.push({
        model,
        inputTokens: tokens.inputTokens,
        outputTokens: tokens.outputTokens,
        cacheReadTokens: tokens.cacheRead,
        cacheCreationTokens: tokens.cacheWrite,
        estimatedCost,
        harvestedAt,
        sessionId: sid,
        project,
        branch: usage.gitBranch || null,
        summary: usage.firstPrompt || null,
        sessionTimestamp: usage.firstTimestamp,
      });
    }

    harvestedIds.add(sid);
  }

  // Merge: keep old entries for sessions we didn't re-scan, replace ones we did
  const kept = existingCosts.filter(e => !harvestedIds.has(e.sessionId));
  const merged = [...kept, ...entries];

  // Rewrite costs.jsonl
  const lines = merged.map(e => JSON.stringify(e)).join('\n') + (merged.length ? '\n' : '');
  fs.writeFileSync(COSTS_JSONL_PATH, lines, 'utf8');

  // Update last harvest timestamp
  writeJson(LAST_HARVEST_PATH, { harvestedAt });

  const totalCost = entries.reduce((sum, e) => sum + e.estimatedCost, 0);
  if (entries.length) {
    for (const e of entries) {
      console.error(`  ${e.sessionId} (${e.model}): $${e.estimatedCost.toFixed(4)}`);
    }
    console.error(`  Harvested ${newlyHarvested.length} session(s), total: $${totalCost.toFixed(4)}`);
  }
}

main().catch(() => {});
