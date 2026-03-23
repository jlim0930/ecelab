// =============================================================================
// /api/options — GET available ECE versions and OS options from the vars file
// =============================================================================

import { NextResponse } from 'next/server';
import { getDeployOptions, getOsOptionsForVersion } from '@/lib/vars-parser';

export async function GET(request) {
  try {
    const options = getDeployOptions();

    // If a version is provided as query param, return filtered OS options
    const { searchParams } = new URL(request.url);
    const version = searchParams.get('version');

    if (version) {
      const osOptions = getOsOptionsForVersion(version, options.osOptionsByRange);
      return NextResponse.json({
        ...options,
        osOptions: osOptions.map(o => o.display),
        // Include structured data so frontend can access container version
        osOptionsDetail: osOptions.map(o => ({
          display: o.display,
          container: o.container,
          cversion: o.cversion,
        })),
      });
    }

    return NextResponse.json({
      ...options,
      osOptions: [],
      osOptionsDetail: [],
    });
  } catch (error) {
    return NextResponse.json(
      { error: `Failed to parse vars file: ${error.message}` },
      { status: 500 }
    );
  }
}
