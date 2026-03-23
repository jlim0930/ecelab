// =============================================================================
// /api/deploy — POST to start a deploy, GET for SSE log stream, DELETE to abort
// =============================================================================

import { NextResponse } from 'next/server';
import { getProcessManager } from '@/lib/process-manager';

// POST: start a new deployment
export async function POST(request) {
  const pm = getProcessManager();

  try {
    const body = await request.json();
    const { installtype, version, os, debug, cversion, container } = body;

    if (!installtype || !version || !os) {
      return NextResponse.json(
        { error: 'Missing required fields: installtype, version, os' },
        { status: 400 }
      );
    }

    pm.startDeploy({ installtype, version, os, debug: !!debug, cversion: cversion || '', container: container || '' });

    return NextResponse.json({ ok: true, message: 'Deployment started' });
  } catch (error) {
    return NextResponse.json(
      { error: error.message },
      { status: 409 }
    );
  }
}

// GET: SSE stream of deployment logs
export async function GET() {
  const pm = getProcessManager();
  const encoder = new TextEncoder();

  // Track listeners so they can be cleaned up when the client disconnects
  let onLog, onDone;

  const stream = new ReadableStream({
    start(controller) {
      const send = (data) => {
        try {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(data)}\n\n`));
        } catch {
          // Controller closed
        }
      };

      // Send current state
      send({ type: 'state', ...pm.getState() });

      if (pm.status !== 'running' && pm.status !== 'cleaning') {
        controller.close();
        return;
      }

      // Stream new logs
      onLog = (line) => send({ type: 'log', text: line });
      onDone = ({ code, status }) => {
        send({ type: 'done', code, status });
        pm.off('log', onLog);
        pm.off('done', onDone);
        try { controller.close(); } catch { /* already closed */ }
      };

      pm.on('log', onLog);
      pm.on('done', onDone);
    },
    // Clean up listeners if the client disconnects before the process finishes
    cancel() {
      if (onLog) pm.off('log', onLog);
      if (onDone) pm.off('done', onDone);
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      'Connection': 'keep-alive',
      'X-Accel-Buffering': 'no',
    },
  });
}

// DELETE: abort current deployment
export async function DELETE() {
  const pm = getProcessManager();
  pm.abort();
  return NextResponse.json({ ok: true });
}
