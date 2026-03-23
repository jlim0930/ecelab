'use client';

import { useState, useEffect, useRef, useCallback } from 'react';

// ─── Step detection from log lines ───────────────────────────────────────────
const DEPLOY_STEPS = [
  { id: 'prereq',    label: 'Prerequisites',    patterns: [/Checking|check_for_updates|PROJECT_ID|gcloud|Python|pip|Terraform is|jq is|SSH key/i] },
  { id: 'env',       label: 'Environment',      patterns: [/Configuring Python venv|Installing Ansible|venv/i] },
  { id: 'terraform', label: 'Infrastructure',    patterns: [/Finding available zones|Terraform|terraform/i] },
  { id: 'ssh',       label: 'Connectivity',      patterns: [/inventory\.yml|SSH connectivity|SSH key auth|reachable via SSH|Verifying SSH/i] },
  { id: 'ansible',   label: 'Installation',      patterns: [/Running Ansible|ansible-playbook|PLAY |TASK |ok=|changed=/i] },
  { id: 'complete',  label: 'Complete',           patterns: [/ECE installation complete|find_instances/i] },
];

const CLEANUP_STEPS = [
  { id: 'start',    label: 'Starting',     patterns: [/Starting cleanup|Proceeding with delete|destructive change/i] },
  { id: 'destroy',  label: 'Destroying',   patterns: [/terraform destroy|Attempting.*terraform|Deleting instance|Deleting disk|Deleting firewall|gcloud cleanup|No Terraform state/i] },
  { id: 'clean',    label: 'Cleaning',     patterns: [/Cleaning up local|Terraform cache.*removed|files removed/i] },
  { id: 'done',     label: 'Complete',     patterns: [/Cleanup complete|deploy fresh/i] },
];

function detectStep(line, steps) {
  for (let i = steps.length - 1; i >= 0; i--) {
    if (steps[i].patterns.some(p => p.test(line))) return i;
  }
  return -1;
}

// Strip ANSI escape codes for pattern matching
function stripAnsi(str) {
  return str.replace(/\x1b\[[0-9;]*m/g, '');
}

// Map ANSI color codes to CSS colors
const ANSI_COLORS = {
  '30': '#555', '31': '#e06c75', '32': '#98c379', '33': '#e5c07b',
  '34': '#61afef', '35': '#c678dd', '36': '#56b6c2', '37': '#abb2bf',
  '90': '#636d83', '91': '#e06c75', '92': '#98c379', '93': '#e5c07b',
  '94': '#61afef', '95': '#c678dd', '96': '#56b6c2', '97': '#ffffff',
};

// Parse ANSI-coded string into array of { text, color, bold } segments
function parseAnsi(line) {
  const segments = [];
  let currentColor = null;
  let bold = false;
  let lastIndex = 0;
  const regex = /\x1b\[([0-9;]*)m/g;
  let match;

  while ((match = regex.exec(line)) !== null) {
    // Push text before this escape
    if (match.index > lastIndex) {
      segments.push({ text: line.slice(lastIndex, match.index), color: currentColor, bold });
    }
    lastIndex = match.index + match[0].length;

    // Parse codes
    const codes = match[1].split(';').filter(Boolean);
    for (const code of codes) {
      if (code === '0') { currentColor = null; bold = false; }
      else if (code === '1') { bold = true; }
      else if (ANSI_COLORS[code]) { currentColor = ANSI_COLORS[code]; }
    }
  }

  // Remaining text
  if (lastIndex < line.length) {
    segments.push({ text: line.slice(lastIndex), color: currentColor, bold });
  }

  return segments;
}

function classifyLine(line) {
  const clean = stripAnsi(line);
  if (/^\[INFO\]/.test(clean)) return 'info';
  if (/^\[WARN\]/.test(clean)) return 'warn';
  if (/^\[ERROR\]/.test(clean)) return 'error';
  if (/^\[DEBUG\]/.test(clean)) return 'debug';
  return 'plain';
}

// ─── Main App ────────────────────────────────────────────────────────────────
export default function Home() {
  const [appState, setAppState] = useState('loading'); // loading|form|running|complete|error
  const [gitStatus, setGitStatus] = useState(null);
  const [hasDeployment, setHasDeployment] = useState(false);
  const [theme, setTheme] = useState('dark');

  // Form state
  const [versions, setVersions] = useState([]);
  const [osOptions, setOsOptions] = useState([]);
  const [osOptionsDetail, setOsOptionsDetail] = useState([]);
  const [installtype, setInstalltype] = useState('small');
  const [version, setVersion] = useState('');
  const [os, setOs] = useState('');
  const [debug, setDebug] = useState(false);

  // Track chosen options for display (persists after deploy starts)
  const [chosenOptions, setChosenOptions] = useState(null);

  // Runtime state
  const [logs, setLogs] = useState([]);
  const [currentStep, setCurrentStep] = useState(-1);
  const [processMode, setProcessMode] = useState(null); // deploy|cleanup

  // Instance info
  const [instances, setInstances] = useState(null);

  // Loading states
  const [loadingOs, setLoadingOs] = useState(false);
  const [loadingInstances, setLoadingInstances] = useState(false);

  // Modal
  const [showConfirm, setShowConfirm] = useState(null);

  // Copy feedback
  const [copied, setCopied] = useState(false);

  const logEndRef = useRef(null);
  const logsRef = useRef([]);
  const esRef = useRef(null);       // Track active EventSource to prevent duplicates
  const copyTimerRef = useRef(null); // Track copy feedback timeout

  // ─── Scroll log to bottom ──────────────────────────────────────────────
  useEffect(() => {
    if (logEndRef.current) {
      logEndRef.current.scrollIntoView({ behavior: 'smooth' });
    }
  }, [logs]);

  // ─── Cleanup on unmount ──────────────────────────────────────────────
  useEffect(() => {
    return () => {
      if (esRef.current) { esRef.current.close(); esRef.current = null; }
      if (copyTimerRef.current) clearTimeout(copyTimerRef.current);
    };
  }, []);

  // ─── Apply theme to document ─────────────────────────────────────────
  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
  }, [theme]);

  // ─── Initial status check ─────────────────────────────────────────────
  useEffect(() => {
    async function init() {
      try {
        const [statusRes, optionsRes] = await Promise.all([
          fetch('/api/status'),
          fetch('/api/options'),
        ]);
        const status = await statusRes.json();
        const options = await optionsRes.json();

        setGitStatus(status.git);
        setHasDeployment(status.hasDeployment);
        setVersions(options.versions || []);

        // Restore chosen options from process manager state
        if (status.process.deployOptions) {
          setChosenOptions(status.process.deployOptions);
        }

        if (status.process.status === 'running' || status.process.status === 'cleaning') {
          setLogs(status.process.logs || []);
          logsRef.current = status.process.logs || [];
          setProcessMode(status.process.mode);
          setAppState('running');
          let maxStep = -1;
          const steps = status.process.mode === 'cleanup' ? CLEANUP_STEPS : DEPLOY_STEPS;
          for (const line of (status.process.logs || [])) {
            const s = detectStep(stripAnsi(line), steps);
            if (s > maxStep) maxStep = s;
          }
          setCurrentStep(maxStep);
          connectSSE();
        } else if (status.process.status === 'complete') {
          setLogs(status.process.logs || []);
          setAppState('complete');
          fetchInstances();
        } else if (status.process.status === 'error') {
          setLogs(status.process.logs || []);
          setProcessMode(status.process.mode);
          setAppState('error');
        } else {
          if (status.hasDeployment) {
            setAppState('complete');
            fetchInstances();
          } else {
            setAppState('form');
          }
        }

        // Set default version to latest
        if (options.versions?.length > 0) {
          const latest = options.versions[options.versions.length - 1];
          setVersion(latest);
          const osRes = await fetch(`/api/options?version=${latest}`);
          const osData = await osRes.json();
          setOsOptions(osData.osOptions || []);
          setOsOptionsDetail(osData.osOptionsDetail || []);
          if (osData.osOptions?.length > 0) setOs(osData.osOptions[0]);
        }
      } catch (err) {
        console.error('Init error:', err);
        setAppState('form');
      }
    }
    init();
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // ─── Fetch OS options when version changes ─────────────────────────────
  const handleVersionChange = useCallback(async (newVersion) => {
    setVersion(newVersion);
    setOs('');
    if (!newVersion) { setOsOptions([]); setOsOptionsDetail([]); return; }
    setLoadingOs(true);
    try {
      const res = await fetch(`/api/options?version=${newVersion}`);
      const data = await res.json();
      setOsOptions(data.osOptions || []);
      setOsOptionsDetail(data.osOptionsDetail || []);
      if (data.osOptions?.length > 0) setOs(data.osOptions[0]);
    } catch { setOsOptions([]); setOsOptionsDetail([]); }
    setLoadingOs(false);
  }, []);

  // ─── SSE connection for log streaming ──────────────────────────────────
  const connectSSE = useCallback(() => {
    // Close any existing SSE connection to prevent duplicates
    if (esRef.current) {
      esRef.current.close();
      esRef.current = null;
    }

    const es = new EventSource('/api/deploy');
    esRef.current = es;

    es.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);

        if (data.type === 'state') {
          // Replay any buffered logs that arrived before SSE connected
          if (data.logs && data.logs.length > 0) {
            logsRef.current = [...data.logs];
            setLogs([...logsRef.current]);
            // Set mode from server state
            if (data.mode) setProcessMode(data.mode);
            // Detect step progress from replayed logs
            const steps = data.mode === 'cleanup' ? CLEANUP_STEPS : DEPLOY_STEPS;
            let maxStep = -1;
            for (const log of data.logs) {
              const s = detectStep(stripAnsi(log), steps);
              if (s > maxStep) maxStep = s;
            }
            if (maxStep >= 0) setCurrentStep(maxStep);
          }
          return;
        }

        if (data.type === 'log') {
          logsRef.current = [...logsRef.current, data.text];
          setLogs([...logsRef.current]);
          // Use the right step list based on mode — strip ANSI for pattern matching
          const cleanText = stripAnsi(data.text);
          setProcessMode(prev => {
            const steps = prev === 'cleanup' ? CLEANUP_STEPS : DEPLOY_STEPS;
            const s = detectStep(cleanText, steps);
            if (s >= 0) setCurrentStep(p => Math.max(p, s));
            return prev;
          });
        }

        if (data.type === 'done') {
          es.close();
          esRef.current = null;
          if (data.status === 'complete' || data.status === 'idle') {
            if (data.status === 'idle') {
              setAppState('form');
              setHasDeployment(false);
              setInstances(null);
              setChosenOptions(null);
            } else {
              setAppState('complete');
              fetchInstances();
            }
          } else {
            setAppState('error');
          }
        }
      } catch { /* malformed event */ }
    };

    es.onerror = () => {
      es.close();
      esRef.current = null;
      fetch('/api/status').then(r => r.json()).then(status => {
        if (status.process.status === 'complete') {
          setAppState('complete');
          fetchInstances();
        } else if (status.process.status === 'idle') {
          setAppState('form');
        } else if (status.process.status === 'error') {
          setAppState('error');
        }
      }).catch(() => {});
    };
  }, []);

  // ─── Fetch instance info ───────────────────────────────────────────────
  const fetchInstances = async () => {
    setLoadingInstances(true);
    try {
      const res = await fetch('/api/instances');
      const data = await res.json();
      setInstances(data);
      setHasDeployment(true);
    } catch { /* ignore */ }
    setLoadingInstances(false);
  };

  // ─── Deploy ────────────────────────────────────────────────────────────
  const handleDeploy = async () => {
    // Look up container runtime version from detailed OS options
    const osDetail = osOptionsDetail.find(o => o.display === os);
    const cversion = osDetail ? osDetail.cversion : '';
    const container = osDetail ? osDetail.container : '';
    const opts = { installtype, version, os, debug, cversion, container };
    setChosenOptions(opts);
    setLogs([]);
    logsRef.current = [];
    setCurrentStep(-1);
    setProcessMode('deploy');
    setAppState('running');

    try {
      const res = await fetch('/api/deploy', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(opts),
      });

      if (!res.ok) {
        const err = await res.json();
        setLogs([`Error: ${err.error}`]);
        setAppState('error');
        return;
      }

      setTimeout(connectSSE, 500);
    } catch (err) {
      setLogs([`Connection error: ${err.message}`]);
      setAppState('error');
    }
  };

  // ─── Cancel deploy + auto-cleanup ─────────────────────────────────────
  const handleCancel = async () => {
    setShowConfirm(null);
    try {
      const res = await fetch('/api/cancel', { method: 'POST' });
      if (!res.ok) {
        const err = await res.json();
        setLogs(prev => [...prev, `Cancel error: ${err.error}`]);
        return;
      }
      // Switch UI to cleanup mode and reconnect SSE
      setCurrentStep(-1);
      setProcessMode('cleanup');
      setTimeout(connectSSE, 500);
    } catch (err) {
      setLogs(prev => [...prev, `Cancel error: ${err.message}`]);
    }
  };

  // ─── Cleanup ───────────────────────────────────────────────────────────
  const handleCleanup = async () => {
    setShowConfirm(null);
    setLogs([]);
    logsRef.current = [];
    setCurrentStep(-1);
    setProcessMode('cleanup');
    setAppState('running');

    try {
      const res = await fetch('/api/cleanup', { method: 'POST' });
      if (!res.ok) {
        const err = await res.json();
        setLogs([`Error: ${err.error}`]);
        setAppState('error');
        return;
      }
      setTimeout(connectSSE, 500);
    } catch (err) {
      setLogs([`Connection error: ${err.message}`]);
      setAppState('error');
    }
  };

  // ─── Reset to form ────────────────────────────────────────────────────
  const handleReset = async () => {
    try {
      const res = await fetch('/api/status');
      const status = await res.json();
      setHasDeployment(status.hasDeployment);
      if (status.hasDeployment) {
        setAppState('complete');
        fetchInstances();
      } else {
        setAppState('form');
      }
    } catch {
      setAppState('form');
    }
    setLogs([]);
    setCurrentStep(-1);
  };

  // ─── Copy password ────────────────────────────────────────────────────
  const copyPassword = (text) => {
    navigator.clipboard.writeText(text).then(() => {
      setCopied(true);
      if (copyTimerRef.current) clearTimeout(copyTimerRef.current);
      copyTimerRef.current = setTimeout(() => setCopied(false), 2000);
    }).catch(() => {});
  };

  // ─── Render ────────────────────────────────────────────────────────────
  if (appState === 'loading') {
    return (
      <div className="app">
        <Header gitStatus={null} theme={theme} onThemeChange={setTheme} />
        <div style={{ textAlign: 'center', padding: '48px 0', color: 'var(--text-muted)' }}>
          <div className="spinner" style={{ margin: '0 auto', width: 24, height: 24 }} />
          <p style={{ marginTop: 16 }}>Loading...</p>
        </div>
      </div>
    );
  }

  const activeSteps = processMode === 'cleanup' ? CLEANUP_STEPS : DEPLOY_STEPS;

  return (
    <div className="app">
      <Header gitStatus={gitStatus} theme={theme} onThemeChange={setTheme} />

      {/* ─── Deployment Info Panel (always visible except loading) ──────── */}
      <DeploymentInfoPanel
        appState={appState}
        hasDeployment={hasDeployment}
        chosenOptions={chosenOptions}
        instances={instances}
        loadingInstances={loadingInstances}
        processMode={processMode}
        copied={copied}
        onCopyPassword={copyPassword}
      />

      {/* ─── Form View ──────────────────────────────────────────────────── */}
      {appState === 'form' && (
        <div className="fade-in">
          <div className="card">
            <div className="card-title">Deploy Configuration</div>

            <div className="form-group">
              <div className="form-label">Deployment Size</div>
              <div className="radio-group">
                <div className="radio-option">
                  <input type="radio" id="single" name="size" value="single"
                    checked={installtype === 'single'} onChange={() => setInstalltype('single')} />
                  <label htmlFor="single">
                    Single Node
                    <span className="radio-desc">1 instance</span>
                  </label>
                </div>
                <div className="radio-option">
                  <input type="radio" id="small" name="size" value="small"
                    checked={installtype === 'small'} onChange={() => setInstalltype('small')} />
                  <label htmlFor="small">
                    Small Cluster
                    <span className="radio-desc">3 instances</span>
                  </label>
                </div>
              </div>
            </div>

            <div className="form-group">
              <label className="form-label" htmlFor="version">ECE Version</label>
              <select id="version" value={version} onChange={e => handleVersionChange(e.target.value)}>
                <option value="">Select version...</option>
                {[...versions].reverse().map(v => (
                  <option key={v} value={v}>{v}</option>
                ))}
              </select>
            </div>

            <div className="form-group">
              <label className="form-label" htmlFor="os" style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                Operating System
                {loadingOs && <span className="spinner" style={{ width: 12, height: 12, borderWidth: 1.5 }} />}
              </label>
              <select id="os" value={os} onChange={e => setOs(e.target.value)}
                disabled={osOptions.length === 0 || loadingOs}>
                <option value="">{loadingOs ? 'Loading...' : 'Select OS...'}</option>
                {osOptions.map(o => (
                  <option key={o} value={o}>{o}</option>
                ))}
              </select>
            </div>

            <div className="form-group">
              <div className="checkbox-row">
                <input type="checkbox" id="debug" checked={debug}
                  onChange={e => setDebug(e.target.checked)} />
                <label htmlFor="debug">Enable debug output</label>
              </div>
            </div>

            <div className="btn-row-spread">
              <button className="btn btn-outline btn-sm"
                onClick={() => setShowConfirm('cleanup')}
                title="Clean up any leftover resources from a previous deployment">
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5">
                  <path d="M2 4h12M5.33 4V2.67a1.33 1.33 0 011.34-1.34h2.66a1.33 1.33 0 011.34 1.34V4m2 0v9.33a1.33 1.33 0 01-1.34 1.34H4.67a1.33 1.33 0 01-1.34-1.34V4h9.34z" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
                Cleanup Environment
              </button>
              <button className="btn btn-primary" onClick={handleDeploy}
                disabled={!version || !os}>
                Deploy
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ─── Running / Error View ────────────────────────────────────────── */}
      {(appState === 'running' || appState === 'error') && (
        <div className="fade-in">
          {/* Step progress */}
          <div className="card" style={{ padding: '16px 24px' }}>
            {processMode === 'cleanup' ? (
              <StepProgress steps={CLEANUP_STEPS} currentStep={currentStep}
                isError={appState === 'error'} />
            ) : (
              <StepProgress steps={DEPLOY_STEPS} currentStep={currentStep}
                isError={appState === 'error'} />
            )}
          </div>

          {/* Log output */}
          <div className="card">
            <div className="card-title" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
              <span style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                Output
                {appState === 'running' && processMode === 'deploy' && (
                  <button className="btn btn-outline btn-sm"
                    style={{ padding: '3px 10px', fontSize: 11, color: 'var(--error)', borderColor: 'var(--error)' }}
                    onClick={() => setShowConfirm('cancel')}>
                    Cancel
                  </button>
                )}
              </span>
              <span className={`status-badge ${appState === 'running' ? (processMode === 'cleanup' ? 'cleaning' : 'running') : appState}`}>
                {appState === 'running' && <span className="spinner" />}
                {appState === 'running'
                  ? (processMode === 'cleanup' ? 'Cleaning' : 'Running')
                  : appState === 'error' ? 'Failed' : 'Done'}
              </span>
            </div>
            <LogViewer logs={logs} logEndRef={logEndRef} />
          </div>

          {appState === 'error' && (
            <div className="btn-row">
              <button className="btn btn-outline" onClick={handleReset}>Back</button>
              <button className="btn btn-danger" onClick={() => setShowConfirm('cleanup')}>
                Cleanup
              </button>
            </div>
          )}
        </div>
      )}

      {/* ─── Complete View ───────────────────────────────────────────────── */}
      {appState === 'complete' && (
        <div className="fade-in">
          <div className="btn-row">
            <button className="btn btn-danger btn-sm"
              onClick={() => setShowConfirm('cleanup')}>
              <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5">
                <path d="M2 4h12M5.33 4V2.67a1.33 1.33 0 011.34-1.34h2.66a1.33 1.33 0 011.34 1.34V4m2 0v9.33a1.33 1.33 0 01-1.34 1.34H4.67a1.33 1.33 0 01-1.34-1.34V4h9.34z" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
              Cleanup
            </button>
          </div>
        </div>
      )}

      {/* ─── Confirm Modal ───────────────────────────────────────────────── */}
      {showConfirm && (
        <div className="modal-overlay" onClick={() => setShowConfirm(null)}>
          <div className="modal" onClick={e => e.stopPropagation()}>
            {showConfirm === 'cancel' ? (
              <>
                <h3>Cancel Deployment?</h3>
                <p>
                  This will stop the current deployment and clean up all created resources (instances, disks, firewall rules). This cannot be undone.
                </p>
                <div className="btn-row" style={{ marginTop: 16 }}>
                  <button className="btn btn-outline btn-sm" onClick={() => setShowConfirm(null)}>Continue Deploying</button>
                  <button className="btn btn-danger btn-sm" onClick={handleCancel}>
                    Cancel &amp; Cleanup
                  </button>
                </div>
              </>
            ) : (
              <>
                <h3>Confirm Cleanup</h3>
                <p>
                  This will permanently delete all instances, disks, and firewall rules. This action cannot be undone.
                </p>
                <div className="btn-row" style={{ marginTop: 16 }}>
                  <button className="btn btn-outline btn-sm" onClick={() => setShowConfirm(null)}>Cancel</button>
                  <button className="btn btn-danger btn-sm" onClick={handleCleanup}>
                    Delete Everything
                  </button>
                </div>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

// ─── Header ──────────────────────────────────────────────────────────────────
function Header({ gitStatus, theme, onThemeChange }) {
  return (
    <header className="header">
      <div className="header-title">
        <div className="header-logo">E</div>
        ECE Lab
      </div>
      <div className="header-right">
        {gitStatus && (
          gitStatus.needsPull ? (
            <div className="git-badge update" title={`Updated files: ${gitStatus.changedFiles.join(', ')}`}>
              <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor">
                <path d="M8 1.5a6.5 6.5 0 100 13 6.5 6.5 0 000-13zM0 8a8 8 0 1116 0A8 8 0 010 8zm9-3a1 1 0 00-2 0v3.5a1 1 0 00.4.8l2.5 1.8a1 1 0 001.2-1.6L9 7.96V5z"/>
              </svg>
              Updates available — run git pull
            </div>
          ) : (
            <div className="git-badge ok">
              <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor">
                <path d="M8 0a8 8 0 110 16A8 8 0 018 0zm3.78 5.22a.75.75 0 00-1.06 0L7 8.94 5.28 7.22a.75.75 0 00-1.06 1.06l2.25 2.25a.75.75 0 001.06 0l4.25-4.25a.75.75 0 000-1.06z"/>
              </svg>
              Up to date
            </div>
          )
        )}
        <div className="theme-toggle" title="Toggle theme">
          <button
            className={theme === 'light' ? 'active' : ''}
            onClick={() => onThemeChange('light')}
            aria-label="Light mode"
          >
            <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
              <path d="M8 1a.75.75 0 01.75.75v1a.75.75 0 01-1.5 0v-1A.75.75 0 018 1zm0 10.5a3.5 3.5 0 100-7 3.5 3.5 0 000 7zm0-1.5a2 2 0 110-4 2 2 0 010 4zm6.25-2.25a.75.75 0 010 1.5h-1a.75.75 0 010-1.5h1zm-11.5 0a.75.75 0 010 1.5h-1a.75.75 0 010-1.5h1zM12.01 3.05a.75.75 0 010 1.06l-.71.71a.75.75 0 01-1.06-1.06l.71-.71a.75.75 0 011.06 0zm-7.07 7.07a.75.75 0 010 1.06l-.71.71a.75.75 0 11-1.06-1.06l.71-.71a.75.75 0 011.06 0zM12.01 12.01a.75.75 0 01-1.06 0l-.71-.71a.75.75 0 011.06-1.06l.71.71a.75.75 0 010 1.06zm-7.07-7.07a.75.75 0 01-1.06 0l-.71-.71A.75.75 0 014.23 3.17l.71.71a.75.75 0 010 1.06zM8 13.5a.75.75 0 01.75.75v1a.75.75 0 01-1.5 0v-1A.75.75 0 018 13.5z"/>
            </svg>
          </button>
          <button
            className={theme === 'dark' ? 'active' : ''}
            onClick={() => onThemeChange('dark')}
            aria-label="Dark mode"
          >
            <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
              <path d="M6.2 1.74A7 7 0 0014.26 9.8a.75.75 0 01.96.96 8.5 8.5 0 11-9.98-9.98.75.75 0 01.96.96z"/>
            </svg>
          </button>
        </div>
      </div>
    </header>
  );
}

// ─── Parse OS display name into components ───────────────────────────────────
// Format: "Rocky 8 - Podman - x86_64" or "Ubuntu 22.04 - Docker 25.0 - arm64 - selinux"
// container/cversion come from the structured OS options detail
function parseOsDisplay(osName, container, cversion) {
  if (!osName) return { os: '', runtime: '', arch: '', selinux: null };
  const parts = osName.split(' - ').map(s => s.trim());
  const os = parts[0] || '';
  const isRhel = /rocky|centos|rhel|alma|oracle/i.test(os);
  const hasSelinux = (parts[3] || '').toLowerCase() === 'selinux';

  // Build runtime string with version: "Podman 4" or "Docker 25.0"
  let runtime = parts[1] || '';
  if (container && cversion) {
    // Capitalize container name and append version
    const name = container.charAt(0).toUpperCase() + container.slice(1);
    runtime = `${name} ${cversion}`;
  }

  return {
    os,
    runtime,
    arch: parts[2] || '',
    selinux: isRhel ? (hasSelinux ? 'Enforcing' : 'Disabled') : null,
  };
}

// ─── Deployment Info Panel ────────────────────────────────────────────────────
function DeploymentInfoPanel({ appState, hasDeployment, chosenOptions, instances, loadingInstances, processMode, copied, onCopyPassword }) {
  const isRunning = appState === 'running';
  const isComplete = appState === 'complete';
  const isError = appState === 'error';

  // Determine what to show
  const showOptions = chosenOptions && (isRunning || isComplete || isError);
  const showInstances = isComplete && instances?.instances?.length > 0;

  const isLoading = loadingInstances && !showInstances;

  const statusLabel = isRunning
    ? (processMode === 'cleanup' ? 'Cleaning' : 'Deploying')
    : isLoading ? 'Loading'
    : isComplete ? 'Active'
    : isError ? 'Error'
    : hasDeployment ? 'Active' : 'None';

  const statusClass = isRunning
    ? (processMode === 'cleanup' ? 'cleaning' : 'running')
    : isLoading ? 'running'
    : isComplete ? 'complete'
    : isError ? 'error'
    : hasDeployment ? 'complete' : 'idle';

  const osParts = showOptions ? parseOsDisplay(chosenOptions.os, chosenOptions.container, chosenOptions.cversion) : null;

  // Format creation date for display
  const createdAt = instances?.createdAt;
  const maxRunDays = instances?.maxRunDays || 7;
  let createdDisplay = null;
  let expiresDisplay = null;
  if (createdAt) {
    try {
      const d = new Date(createdAt);
      createdDisplay = d.toLocaleString(undefined, {
        year: 'numeric', month: 'short', day: 'numeric',
        hour: '2-digit', minute: '2-digit',
      });
      const expires = new Date(d.getTime() + maxRunDays * 24 * 60 * 60 * 1000);
      expiresDisplay = expires.toLocaleString(undefined, {
        year: 'numeric', month: 'short', day: 'numeric',
        hour: '2-digit', minute: '2-digit',
      });
    } catch { /* ignore */ }
  }

  return (
    <div className="deploy-info">
      <div className="deploy-info-header">
        <span className="deploy-info-title">Deployment</span>
        <span className={`status-badge ${statusClass}`}>
          {(isRunning || isLoading) && <span className="spinner" />}
          {statusLabel}
        </span>
      </div>

      {!showOptions && !showInstances && appState === 'form' && !hasDeployment && !loadingInstances && (
        <div className="deploy-info-none">No active deployment. Configure and deploy below.</div>
      )}

      {/* Loading spinner while fetching instance data from deploy.sh find */}
      {loadingInstances && !showInstances && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '12px 0', color: 'var(--text-muted)' }}>
          <span className="spinner" style={{ width: 16, height: 16, borderWidth: 2 }} />
          <span style={{ fontSize: 13 }}>Fetching deployment info...</span>
        </div>
      )}

      {/* Show chosen deployment options */}
      {showOptions && (
        <div className="info-grid">
          <div className="info-item">
            <span className="info-label">Size</span>
            <span className="info-value">
              {chosenOptions.installtype === 'small' ? 'Small Cluster (3 nodes)' : 'Single Node'}
            </span>
          </div>
          <div className="info-item">
            <span className="info-label">ECE Version</span>
            <span className="info-value">{chosenOptions.version}</span>
          </div>
          <div className="info-item">
            <span className="info-label">Platform</span>
            <span className="info-value">
              {osParts.os} / {osParts.runtime} / {osParts.arch}{osParts.selinux ? ` / SELinux: ${osParts.selinux}` : ''}
            </span>
          </div>
          {createdDisplay && (
            <div className="info-item">
              <span className="info-label">Created</span>
              <span className="info-value">{createdDisplay}</span>
            </div>
          )}
          {chosenOptions.debug && (
            <div className="info-item">
              <span className="info-label">Debug</span>
              <span className="info-value" style={{ color: 'var(--warning)' }}>Enabled</span>
            </div>
          )}
        </div>
      )}

      {/* Auto-delete warning */}
      {(showInstances || (showOptions && createdDisplay)) && (
        <div className="deploy-warning">
          <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
            <path d="M8 1a7 7 0 100 14A7 7 0 008 1zm0 2.5a.75.75 0 01.75.75v3.5a.75.75 0 01-1.5 0v-3.5A.75.75 0 018 3.5zm0 7.5a.75.75 0 100-1.5.75.75 0 000 1.5z"/>
          </svg>
          <span>
            GCP instances will be automatically deleted in <strong>{maxRunDays} days</strong>
            {expiresDisplay && <> (approximately {expiresDisplay})</>}.
            Auto-deleted instances leave behind Terraform state and other artifacts — run <strong>Cleanup</strong> before deploying again.
            You can change the TTL by editing <strong>MAX_RUN_DAYS</strong> in the <strong>vars</strong> file before deploying.
          </span>
        </div>
      )}

      {/* Show instance info + credentials when complete */}
      {showInstances && (
        <>
          <div className="divider" />

          {/* Password */}
          {instances.adminPassword && (
            <div style={{ marginBottom: 12 }}>
              <span style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.3px', color: 'var(--text-muted)' }}>
                Admin Password
              </span>
              <div className="password-row" style={{ marginTop: 4 }}>
                <span className="password-value">{instances.adminPassword}</span>
                <button className={`copy-btn ${copied ? 'copied' : ''}`}
                  onClick={() => onCopyPassword(instances.adminPassword)}>
                  {copied ? (
                    <>
                      <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor">
                        <path d="M13.78 4.22a.75.75 0 010 1.06l-7.25 7.25a.75.75 0 01-1.06 0L2.22 9.28a.75.75 0 011.06-1.06L6 10.94l6.72-6.72a.75.75 0 011.06 0z"/>
                      </svg>
                      Copied
                    </>
                  ) : (
                    <>
                      <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5">
                        <rect x="5" y="5" width="9" height="9" rx="1.5" />
                        <path d="M3.5 11H3a1.5 1.5 0 01-1.5-1.5v-7A1.5 1.5 0 013 1h7a1.5 1.5 0 011.5 1.5V3" />
                      </svg>
                      Copy
                    </>
                  )}
                </button>
              </div>
            </div>
          )}

          {/* Console links — one per host */}
          <div style={{ marginBottom: 12 }}>
            <span style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.3px', color: 'var(--text-muted)' }}>
              Admin Console
            </span>
            <div className="console-links">
              {instances.instances.map((vm, i) => vm.publicIp && (
                <a key={vm.name} className="console-link"
                  href={`https://${vm.publicIp}:12443`} target="_blank" rel="noopener noreferrer">
                  <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5">
                    <path d="M6 3H3a1 1 0 00-1 1v9a1 1 0 001 1h9a1 1 0 001-1v-3M9 1h6m0 0v6m0-6L8 8" strokeLinecap="round" strokeLinejoin="round"/>
                  </svg>
                  {vm.publicIp}:12443
                </a>
              ))}
            </div>
          </div>

          {/* Instance table */}
          <span style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.3px', color: 'var(--text-muted)' }}>
            Instances
          </span>
          <table className="instance-table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Public IP</th>
                <th>Internal IP</th>
                <th>Zone</th>
                <th>Machine</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {instances.instances.map(vm => (
                <tr key={vm.name}>
                  <td style={{ color: 'var(--accent)', fontWeight: 500 }}>{vm.name}</td>
                  <td className="mono">{vm.publicIp || '—'}</td>
                  <td className="mono">{vm.internalIp || '—'}</td>
                  <td>{vm.zone || '—'}</td>
                  <td className="mono">{vm.machineType || '—'}</td>
                  <td>
                    <span className={`status-dot ${vm.status === 'RUNNING' ? 'running' : 'stopped'}`} />
                    {vm.status || '—'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </div>
  );
}

// ─── Step Progress ───────────────────────────────────────────────────────────
function StepProgress({ steps, currentStep, isError }) {
  return (
    <div className="steps">
      {steps.map((step, i) => {
        let cls = 'step';
        let barCls = 'step-bar';
        if (i < currentStep) { cls += ' complete'; barCls += ' complete'; }
        else if (i === currentStep) {
          if (isError) { cls += ' error'; barCls += ' error'; }
          else { cls += ' active'; barCls += ' active'; }
        }
        return (
          <div key={step.id} className={cls}>
            <div className={barCls} />
            <span className="step-label">{step.label}</span>
          </div>
        );
      })}
    </div>
  );
}

// ─── Log Line with ANSI color rendering ──────────────────────────────────────
function AnsiLine({ line }) {
  const hasAnsi = /\x1b\[/.test(line);
  if (!hasAnsi) {
    return <div className={`log-line ${classifyLine(line)}`}>{line}</div>;
  }

  const segments = parseAnsi(line);
  const lineClass = classifyLine(line);

  return (
    <div className={`log-line ${lineClass}`}>
      {segments.map((seg, j) => {
        if (!seg.color && !seg.bold) return <span key={j}>{seg.text}</span>;
        const style = {};
        if (seg.color) style.color = seg.color;
        if (seg.bold) style.fontWeight = 'bold';
        return <span key={j} style={style}>{seg.text}</span>;
      })}
    </div>
  );
}

// ─── Log Viewer ──────────────────────────────────────────────────────────────
// Only renders the last MAX_VISIBLE_LINES lines to avoid DOM bloat on long deploys.
const MAX_VISIBLE_LINES = 500;

function LogViewer({ logs, logEndRef }) {
  const startIndex = Math.max(0, logs.length - MAX_VISIBLE_LINES);
  const visibleLogs = startIndex > 0 ? logs.slice(startIndex) : logs;

  return (
    <div className="log-viewer">
      {logs.length === 0 && (
        <div style={{ color: 'var(--text-muted)', fontStyle: 'italic', display: 'flex', alignItems: 'center', gap: 8 }}>
          <span className="spinner" style={{ width: 12, height: 12, borderWidth: 1.5, borderTopColor: 'var(--text-muted)' }} />
          Waiting for output...
        </div>
      )}
      {startIndex > 0 && (
        <div className="log-line plain" style={{ color: 'var(--text-muted)', fontStyle: 'italic' }}>
          ... {startIndex} earlier lines omitted ...
        </div>
      )}
      {visibleLogs.map((line, i) => (
        <AnsiLine key={startIndex + i} line={line} />
      ))}
      <div ref={logEndRef} />
    </div>
  );
}
