#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const BASE_DIR = process.env.COST_TRACKER_DIR || path.join(process.env.HOME, '.claude', 'cost-tracker');
const ACTIVITY_FILE = path.join(BASE_DIR, 'activity.jsonl');
const CONFIG_FILE = path.join(BASE_DIR, 'config.json');

function loadConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
  } catch (_) {
    return { ticketPattern: '[A-Z]{2,6}-\\d+', autoTagPatterns: {} };
  }
}

function getGitBranch(dir) {
  if (!dir) return null;
  try {
    return execSync('git rev-parse --abbrev-ref HEAD', {
      cwd: dir,
      timeout: 2000,
      stdio: ['ignore', 'pipe', 'ignore'],
    }).toString().trim();
  } catch (_) {
    return null;
  }
}

function extractTicket(str, pattern) {
  if (!str || !pattern) return null;
  try {
    const match = str.match(new RegExp(pattern));
    return match ? match[0] : null;
  } catch (_) {
    return null;
  }
}

function inferStage(toolName, toolInput) {
  if (!toolName) return null;
  const name = toolName.toLowerCase();
  if (name === 'read' || name === 'grep' || name === 'glob' || name === 'websearch' || name === 'webfetch') return 'research';
  if (name === 'edit' || name === 'write' || name === 'notebookedit') return 'implementation';
  if (name === 'agent') return 'agent';
  if (name === 'bash') {
    const cmd = (toolInput && toolInput.command) ? toolInput.command.toLowerCase() : '';
    if (/\b(test|jest|mocha|vitest|pytest|npm test|yarn test|pnpm test|bun test|spec)\b/.test(cmd)) {
      return 'testing';
    }
    return 'execution';
  }
  return null;
}

async function main() {
  let input = '';
  process.stdin.setEncoding('utf8');
  for await (const chunk of process.stdin) {
    input += chunk;
  }

  let data;
  try {
    data = JSON.parse(input);
  } catch (_) {
    // Invalid JSON — nothing to log
    return;
  }

  const config = loadConfig();
  const project = process.env.CLAUDE_PROJECT_DIR || null;

  // Build tags
  const tags = {};

  // Auto-tag: ticket from git branch
  if (config.autoTagPatterns && config.autoTagPatterns.ticketFromBranch) {
    const branch = getGitBranch(project);
    if (branch) {
      const ticket = extractTicket(branch, config.ticketPattern);
      if (ticket) tags.ticket = ticket;
    }
  }

  // Auto-tag: infer stage from tool name
  if (config.autoTagPatterns && config.autoTagPatterns.inferStage) {
    const stage = inferStage(data.tool_name, data.tool_input);
    if (stage) tags.stage = stage;
  }

  const entry = {
    timestamp: new Date().toISOString(),
    event: 'tool_call',
    sessionId: data.session_id || null,
    toolName: data.tool_name || null,
    toolInput: data.tool_input || null,
    project: project,
    tags,
  };

  try {
    fs.appendFileSync(ACTIVITY_FILE, JSON.stringify(entry) + '\n', 'utf8');
  } catch (_) {
    // Silently fail — never crash the hook
  }
}

main().catch(() => {
  // Never crash
});
