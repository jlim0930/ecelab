// =============================================================================
// /api/instances — GET live instance data, credentials, and deployment metadata
// =============================================================================
// Primary source: `deploy.sh find` (gcloud query with box-drawing table).
// Fallback: eceinfo.txt. Also returns creation date, max run days, and password.
// =============================================================================

import { NextResponse } from 'next/server';
import { execSync } from 'child_process';
import path from 'path';
import fs from 'fs';

const PROJECT_DIR = path.resolve(process.cwd(), '..');

// Parse the box-drawing table from `deploy.sh find` into structured instance data
function parseDeployShOutput(content) {
  const lines = content.split('\n');
  const instances = [];
  let adminPassword = null;

  for (const line of lines) {
    // Strip ANSI escape codes for clean parsing
    const clean = line.replace(/\x1b\[[0-9;]*m/g, '');

    // Parse table data rows (contain │ separators and instance data, not header/border rows)
    if (clean.includes('│') && !clean.includes('───') && !clean.includes('NAME')) {
      const cells = clean.split('│').map(c => c.trim()).filter(c => c.length > 0);
      if (cells.length >= 7) {
        instances.push({
          name: cells[0],
          zone: cells[1],
          machineType: cells[2],
          internalIp: cells[3],
          publicIp: cells[4],
          os: cells[5],
          status: cells[6],
        });
      }
    }

    // Extract admin password
    const pwMatch = clean.match(/admin password:\s*(.+)/);
    if (pwMatch) {
      adminPassword = pwMatch[1].trim();
    }
  }

  return { instances, adminPassword };
}

/**
 * Get deployment creation time from terraform state file.
 */
function getDeploymentCreatedAt() {
  const tfState = path.join(PROJECT_DIR, 'terraform.tfstate');
  if (fs.existsSync(tfState)) {
    try {
      const state = JSON.parse(fs.readFileSync(tfState, 'utf-8'));
      // Look for instance creation timestamp in terraform state
      for (const resource of (state.resources || [])) {
        if (resource.type === 'google_compute_instance') {
          for (const inst of (resource.instances || [])) {
            const created = inst.attributes?.creation_timestamp;
            if (created) return created;
          }
        }
      }
      // Fallback: use state file mtime
      const stat = fs.statSync(tfState);
      return stat.mtime.toISOString();
    } catch { /* ignore */ }
  }

  // Fallback: eceinfo.txt mtime
  const infoFile = path.join(PROJECT_DIR, 'eceinfo.txt');
  if (fs.existsSync(infoFile)) {
    try {
      const stat = fs.statSync(infoFile);
      return stat.mtime.toISOString();
    } catch { /* ignore */ }
  }

  return null;
}

/**
 * Parse MAX_RUN_DAYS from vars file.
 */
function getMaxRunDays() {
  try {
    const varsContent = fs.readFileSync(path.join(PROJECT_DIR, 'vars'), 'utf-8');
    const match = varsContent.match(/^MAX_RUN_DAYS=(\d+)/m);
    return match ? parseInt(match[1], 10) : 7;
  } catch {
    return 7;
  }
}

export async function GET() {
  try {
    let instances = [];
    let adminPassword = null;

    // Primary source: run deploy.sh find to get live instance data
    try {
      const output = execSync('bash deploy.sh find', {
        cwd: PROJECT_DIR,
        timeout: 30000,
        encoding: 'utf-8',
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      if (output) {
        const parsed = parseDeployShOutput(output);
        instances = parsed.instances;
        adminPassword = parsed.adminPassword;
      }
    } catch (findErr) {
      // deploy.sh find may fail if no instances exist — that's ok
      // Try parsing stderr too in case output went there
      const stderr = findErr.stderr || '';
      const stdout = findErr.stdout || '';
      const combined = stdout + '\n' + stderr;
      if (combined.includes('│')) {
        const parsed = parseDeployShOutput(combined);
        instances = parsed.instances;
        adminPassword = parsed.adminPassword;
      }
    }

    // Fallback: parse eceinfo.txt if deploy.sh find returned nothing
    if (instances.length === 0) {
      const infoFile = path.join(PROJECT_DIR, 'eceinfo.txt');
      if (fs.existsSync(infoFile)) {
        const content = fs.readFileSync(infoFile, 'utf-8').trim();
        if (content) {
          const parsed = parseDeployShOutput(content);
          instances = parsed.instances;
          adminPassword = parsed.adminPassword;
        }
      }
    }

    // If adminPassword wasn't found, try bootstrap-secrets
    if (!adminPassword) {
      const secretsFile = path.join(PROJECT_DIR, 'bootstrap-secrets.local.json');
      if (fs.existsSync(secretsFile)) {
        try {
          const secrets = JSON.parse(fs.readFileSync(secretsFile, 'utf-8'));
          adminPassword = secrets.adminconsole_root_password || null;
        } catch { /* ignore */ }
      }
    }

    // Get ECE version from process manager deploy options
    let eceVersion = null;
    try {
      const pm = (await import('@/lib/process-manager')).getProcessManager();
      eceVersion = pm.deployOptions?.version || null;
    } catch { /* ignore */ }

    // Get deployment creation time and max run days
    const createdAt = getDeploymentCreatedAt();
    const maxRunDays = getMaxRunDays();

    return NextResponse.json({
      instances,
      adminPassword,
      eceVersion,
      createdAt,
      maxRunDays,
      consoleUrl: instances.length > 0 && instances[0].publicIp
        ? `https://${instances[0].publicIp}:12443`
        : null,
    });
  } catch (error) {
    return NextResponse.json(
      { error: error.message },
      { status: 500 }
    );
  }
}
