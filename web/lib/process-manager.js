// =============================================================================
// Process Manager — spawns and manages deploy.sh / cleanup subprocesses
// =============================================================================
// Singleton (survives Next.js HMR) that wraps child_process.spawn, streams
// stdout/stderr as 'log' events, and emits 'done' when the process exits.
// =============================================================================

import { spawn } from 'child_process';
import { EventEmitter } from 'events';
import path from 'path';

// All commands run from the project root (one level above web/)
const PROJECT_DIR = path.resolve(process.cwd(), '..');

class ProcessManager extends EventEmitter {
  constructor() {
    super();
    this.setMaxListeners(50);
    this.process = null;
    this.status = 'idle'; // idle | running | complete | error | cleaning
    this.mode = null; // 'deploy' | 'cleanup'
    this.logs = [];
    this.exitCode = null;
    this.deployOptions = null;
  }

  // Start a deployment subprocess with the given options
  startDeploy(options) {
    if (this.status === 'running' || this.status === 'cleaning') {
      throw new Error('A process is already running');
    }

    this.logs = [];
    this.status = 'running';
    this.mode = 'deploy';
    this.exitCode = null;
    this.deployOptions = options;

    const env = {
      ...process.env,
      PRESELECTED_installtype: options.installtype,
      PRESELECTED_version: options.version,
      PRESELECTED_os: options.os,
      // Force colors and unbuffered output
      FORCE_COLOR: '1',
      PYTHONUNBUFFERED: '1',
      ANSIBLE_FORCE_COLOR: '1',
      TERM: 'xterm-256color',
    };

    const debugFlag = options.debug ? ' --debug' : '';
    // Use stdbuf for line-buffered output if available, otherwise fall back to plain bash
    const args = ['-c', `command -v stdbuf >/dev/null 2>&1 && exec stdbuf -oL -eL bash deploy.sh${debugFlag} || exec bash deploy.sh${debugFlag}`];

    this.process = spawn('bash', args, {
      cwd: PROJECT_DIR,
      env,
      stdio: ['pipe', 'pipe', 'pipe'],
      detached: true,
    });

    this._attachHandlers();
  }

  // Start a cleanup subprocess (deploy.sh cleanup) and auto-confirm the prompt
  startCleanup() {
    if (this.status === 'running' || this.status === 'cleaning') {
      throw new Error('A process is already running');
    }

    this.logs = [];
    this.status = 'cleaning';
    this.mode = 'cleanup';
    this.exitCode = null;

    const env = {
      ...process.env,
      FORCE_COLOR: '1',
      PYTHONUNBUFFERED: '1',
      ANSIBLE_FORCE_COLOR: '1',
      TERM: 'xterm-256color',
    };

    this.process = spawn('bash', ['-c', 'command -v stdbuf >/dev/null 2>&1 && exec stdbuf -oL -eL bash deploy.sh cleanup || exec bash deploy.sh cleanup'], {
      cwd: PROJECT_DIR,
      env,
      stdio: ['pipe', 'pipe', 'pipe'],
      detached: true,
    });

    // Auto-confirm the destructive change prompt
    setTimeout(() => {
      try {
        if (this.process && this.process.stdin && !this.process.stdin.destroyed) {
          this.process.stdin.write('Y\n');
        }
      } catch { /* ignore */ }
    }, 300);

    this._attachHandlers();
  }

  /**
   * Cancel a running deployment: kill deploy.sh and ALL child processes
   * (terraform, ansible, ssh, etc.), then resolve so the caller can start cleanup.
   */
  cancelDeploy() {
    return new Promise((resolve) => {
      if (!this.process || this.status !== 'running') {
        resolve();
        return;
      }

      this.logs.push('\x1b[33m[WARN]\x1b[0m  Deployment cancelled by user.');
      this.emit('log', '\x1b[33m[WARN]\x1b[0m  Deployment cancelled by user.');

      const pid = this.process.pid;

      const onClose = () => {
        this.process = null;
        this.status = 'idle';
        this.mode = null;
        this.removeListener('done', onClose);
        resolve();
      };

      this.once('done', onClose);

      // Kill the entire process tree: deploy.sh, terraform, ansible, ssh, etc.
      // 1) SIGKILL the process group (detached: true puts them in one group)
      try {
        process.kill(-pid, 'SIGKILL');
      } catch {
        try { this.process.kill('SIGKILL'); } catch { /* ignore */ }
      }

      // 2) Also find and kill any orphaned child processes by parent PID.
      //    Terraform and Ansible can spawn subprocesses that escape the group.
      try {
        const { execSync } = require('child_process');
        // pkill -9 -P sends SIGKILL to all processes whose parent is `pid`
        execSync(`pkill -9 -P ${pid} 2>/dev/null; true`, { timeout: 3000 });
        // Also kill any lingering terraform/ansible-playbook started by this user
        execSync(`pgrep -f "deploy.sh" | xargs kill -9 2>/dev/null; true`, { timeout: 3000 });
      } catch { /* best-effort */ }

      // Safety fallback if 'close' event doesn't fire within 3s
      setTimeout(() => {
        if (this.process) {
          this.process = null;
          this.status = 'idle';
          this.mode = null;
          this.removeListener('done', onClose);
          resolve();
        }
      }, 3000);
    });
  }

  // Wire up stdout/stderr → 'log' events and process exit → 'done' event
  _attachHandlers() {
    const MAX_LOG_LINES = 5000; // Cap stored logs to prevent unbounded memory growth

    const handleData = (data) => {
      const text = data.toString();
      const lines = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
      for (const line of lines) {
        if (line.length === 0) continue;
        this.logs.push(line);
        this.emit('log', line);
      }
      // Trim old logs if buffer exceeds limit
      if (this.logs.length > MAX_LOG_LINES) {
        this.logs = this.logs.slice(-MAX_LOG_LINES);
      }
    };

    this.process.stdout.on('data', handleData);
    this.process.stderr.on('data', handleData);

    this.process.on('close', (code) => {
      this.exitCode = code;
      if (this.mode === 'cleanup') {
        this.status = code === 0 ? 'idle' : 'error';
      } else {
        this.status = code === 0 ? 'complete' : 'error';
      }
      this.process = null;
      this.emit('done', { code, status: this.status });
    });

    this.process.on('error', (err) => {
      this.status = 'error';
      this.logs.push(`Process error: ${err.message}`);
      this.process = null;
      this.emit('done', { code: -1, status: 'error' });
    });
  }

  // Graceful abort: SIGTERM first, then SIGKILL after 5s if still alive
  abort() {
    if (this.process) {
      try {
        process.kill(-this.process.pid, 'SIGTERM');
      } catch {
        try { this.process.kill('SIGTERM'); } catch { /* ignore */ }
      }
      setTimeout(() => {
        if (this.process) {
          try {
            process.kill(-this.process.pid, 'SIGKILL');
          } catch {
            try { this.process.kill('SIGKILL'); } catch { /* ignore */ }
          }
        }
      }, 5000);
    }
  }

  getState() {
    return {
      status: this.status,
      mode: this.mode,
      logs: [...this.logs],
      exitCode: this.exitCode,
      deployOptions: this.deployOptions,
    };
  }

  reset() {
    if (this.status === 'running' || this.status === 'cleaning') return;
    this.status = 'idle';
    this.mode = null;
    this.logs = [];
    this.exitCode = null;
    this.deployOptions = null;
  }
}

// Singleton — survives Next.js HMR in dev mode.
// Re-create if the old instance is missing new methods (stale HMR).
export function getProcessManager() {
  if (!globalThis.__ecelabProcessManager || typeof globalThis.__ecelabProcessManager.cancelDeploy !== 'function') {
    const old = globalThis.__ecelabProcessManager;
    const pm = new ProcessManager();
    // Preserve state from old instance if it existed
    if (old) {
      pm.process = old.process;
      pm.status = old.status;
      pm.mode = old.mode;
      pm.logs = old.logs;
      pm.exitCode = old.exitCode;
      pm.deployOptions = old.deployOptions;
      // Re-attach process event handlers to the new PM instance.
      // After HMR, the old instance's closures (which capture `this`) are stale,
      // so we strip them and re-bind to the new PM.
      if (pm.process) {
        pm.process.removeAllListeners();
        if (pm.process.stdout) pm.process.stdout.removeAllListeners();
        if (pm.process.stderr) pm.process.stderr.removeAllListeners();
        pm._attachHandlers();
      }
    }
    globalThis.__ecelabProcessManager = pm;
  }
  return globalThis.__ecelabProcessManager;
}
