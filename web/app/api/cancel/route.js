// =============================================================================
// /api/cancel — POST to cancel a running deploy and auto-start cleanup
// =============================================================================

import { NextResponse } from 'next/server';
import { getProcessManager } from '@/lib/process-manager';

// Kill the running deploy process (SIGKILL), then start cleanup
export async function POST() {
  const pm = getProcessManager();

  if (pm.status !== 'running') {
    return NextResponse.json(
      { error: 'No deployment is currently running' },
      { status: 409 }
    );
  }

  try {
    // Kill the running deploy
    await pm.cancelDeploy();

    // Now start cleanup to return to a clean state
    pm.startCleanup();

    return NextResponse.json({ ok: true, message: 'Deployment cancelled, cleanup started' });
  } catch (error) {
    return NextResponse.json(
      { error: error.message },
      { status: 500 }
    );
  }
}
