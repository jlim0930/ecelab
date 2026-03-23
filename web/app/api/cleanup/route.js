// =============================================================================
// /api/cleanup — POST to start a cleanup (destroy all GCP resources)
// =============================================================================

import { NextResponse } from 'next/server';
import { getProcessManager } from '@/lib/process-manager';

export async function POST() {
  const pm = getProcessManager();

  try {
    pm.startCleanup();
    return NextResponse.json({ ok: true, message: 'Cleanup started' });
  } catch (error) {
    return NextResponse.json(
      { error: error.message },
      { status: 409 }
    );
  }
}
