#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const BASE_DIR = process.env.COST_TRACKER_DIR || path.join(process.env.HOME, '.claude', 'cost-tracker');
const ACTIVITY_FILE = path.join(BASE_DIR, 'activity.jsonl');
const CONFIG_FILE = path.join(BASE_DIR, 'config.json');
const SESSIONS_FILE = path.join(BASE_DIR, 'tags', 'sessions.json');

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

function loadSessions() {
  try {
    return JSON.parse(fs.readFileSync(SESSIONS_FILE, 'utf8'));
  } catch (_) {
    return {};
  }
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
  const sessionId = data.session_id || null;
  const timestamp = new Date().toISOString();

  // Build tags
  const tags = {};

  // Auto-tag: ticket from git branch
  let ticket = null;
  if (config.autoTagPatterns && config.autoTagPatterns.ticketFromBranch) {
    const branch = getGitBranch(project);
    if (branch) {
      ticket = extractTicket(branch, config.ticketPattern);
      if (ticket) tags.ticket = ticket;
    }
  }

  const entry = {
    timestamp,
    event: 'session_start',
    sessionId,
    project,
    tags,
  };

  // Append to activity.jsonl
  try {
    fs.appendFileSync(ACTIVITY_FILE, JSON.stringify(entry) + '\n', 'utf8');
  } catch (_) {
    // Silently fail — never crash the hook
  }

  // If ticket found, write to tags/sessions.json
  if (ticket && sessionId) {
    try {
      const sessions = loadSessions();
      sessions[sessionId] = {
        ticket,
        project,
        startedAt: timestamp,
      };
      fs.writeFileSync(SESSIONS_FILE, JSON.stringify(sessions, null, 2) + '\n', 'utf8');
    } catch (_) {
      // Silently fail — never crash the hook
    }
  }
}

main().catch(() => {
  // Never crash
});
