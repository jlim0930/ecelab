// =============================================================================
// /api/status — GET git update status, deployment state, and process info
// =============================================================================

import { NextResponse } from 'next/server';
import { execSync } from 'child_process';
import path from 'path';
import fs from 'fs';
import { getProcessManager } from '@/lib/process-manager';

const PROJECT_DIR = path.resolve(process.cwd(), '..');

export async function GET() {
  const pm = getProcessManager();

  // Check git status
  let gitStatus = { needsPull: false, changedFiles: [] };
  try {
    execSync('git fetch origin', { cwd: PROJECT_DIR, timeout: 10000, stdio: 'pipe' });
    const diff = execSync('git diff --name-only origin/main', {
      cwd: PROJECT_DIR, timeout: 5000, encoding: 'utf-8', stdio: 'pipe',
    }).trim();
    if (diff) {
      const files = diff.split('\n').filter(f => f && f !== 'vars');
      if (files.length > 0) {
        gitStatus = { needsPull: true, changedFiles: files };
      }
    }
  } catch {
    // Not a git repo or no remote — ignore
  }

  // Check for existing deployment
  let hasDeployment = false;
  try {
    const tfState = path.join(PROJECT_DIR, 'terraform.tfstate');
    if (fs.existsSync(tfState)) {
      const state = JSON.parse(fs.readFileSync(tfState, 'utf-8'));
      hasDeployment = (state.resources || []).length > 0;
    }
  } catch {
    // No terraform state
  }

  // Check for instance info
  let instanceInfo = null;
  try {
    const infoFile = path.join(PROJECT_DIR, 'eceinfo.txt');
    if (fs.existsSync(infoFile)) {
      const content = fs.readFileSync(infoFile, 'utf-8').trim();
      if (content) instanceInfo = content;
    }
  } catch {
    // No info file
  }

  return NextResponse.json({
    git: gitStatus,
    hasDeployment,
    instanceInfo,
    process: pm.getState(),
  });
}
