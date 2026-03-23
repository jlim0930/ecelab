// =============================================================================
// Vars Parser — reads the bash 'vars' config file and returns structured data
// =============================================================================
// Parses ECE_VERSIONS[], OS_OPTIONS_V* arrays, and simple VAR=value assignments
// from the project's vars file so the web UI can populate its dropdowns.
// =============================================================================

import fs from 'fs';
import path from 'path';

const PROJECT_DIR = path.resolve(process.cwd(), '..');
const VARS_FILE = path.join(PROJECT_DIR, 'vars');

/**
 * Parse a bash array from the vars file.
 * Handles arrays spanning multiple lines with quoted strings.
 */
function parseBashArray(content, arrayName) {
  // Match ARRAY_NAME=( ... ) across multiple lines
  const regex = new RegExp(`${arrayName}=\\(([^)]+)\\)`, 's');
  const match = content.match(regex);
  if (!match) return [];

  // Extract all quoted strings
  const items = [];
  const strRegex = /"([^"]+)"/g;
  let m;
  while ((m = strRegex.exec(match[1])) !== null) {
    items.push(m[1]);
  }
  return items;
}

/**
 * Parse a simple variable assignment: VAR="value" or VAR=value
 */
function parseVar(content, varName) {
  const regex = new RegExp(`^${varName}="?([^"\\n]+)"?`, 'm');
  const match = content.match(regex);
  return match ? match[1].trim() : null;
}

/**
 * Convert version string to comparable integer (e.g., "3.8.0" -> 30800)
 */
function versionToInt(version) {
  const parts = version.split('.').map(Number);
  return (parts[0] || 0) * 10000 + (parts[1] || 0) * 100 + (parts[2] || 0);
}

/**
 * Parse an OS option entry (pipe-delimited) into a structured object.
 */
function parseOsEntry(entry) {
  const parts = entry.split('|');
  return {
    display: parts[0],
    image: parts[1],
    container: parts[2],
    cversion: parts[3],
    disk2_x86: parts[4],
    disk2_arm: parts[5],
    selinux: parts[6],
    type_single_x86: parts[7],
    type_small_x86: parts[8],
    type_single_arm: parts[9],
    type_small_arm: parts[10],
  };
}

/**
 * Read and parse the vars file.
 * Returns all deployment options.
 */
export function getDeployOptions() {
  const content = fs.readFileSync(VARS_FILE, 'utf-8');

  const projectId = parseVar(content, 'PROJECT_ID');
  const region = parseVar(content, 'REGION');

  const versions = parseBashArray(content, 'ECE_VERSIONS');

  // Parse all OS option arrays
  const osOptionsV4 = parseBashArray(content, 'OS_OPTIONS_V4').map(parseOsEntry);
  const osOptionsV38 = parseBashArray(content, 'OS_OPTIONS_V38').map(parseOsEntry);
  const osOptionsV37 = parseBashArray(content, 'OS_OPTIONS_V37').map(parseOsEntry);
  const osOptionsV3 = parseBashArray(content, 'OS_OPTIONS_V3').map(parseOsEntry);

  return {
    projectId,
    region,
    versions,
    osOptionsByRange: {
      v4: osOptionsV4,    // >= 4.0.0
      v38: osOptionsV38,  // >= 3.8.0, < 4.0.0
      v37: osOptionsV37,  // >= 3.7.0, < 3.8.0
      v3: osOptionsV3,    // < 3.7.0
    },
  };
}

/**
 * Get OS options for a specific ECE version.
 */
export function getOsOptionsForVersion(version, osOptionsByRange) {
  const v = versionToInt(version);
  if (v >= versionToInt('4.0.0')) return osOptionsByRange.v4;
  if (v >= versionToInt('3.8.0')) return osOptionsByRange.v38;
  if (v >= versionToInt('3.7.0')) return osOptionsByRange.v37;
  return osOptionsByRange.v3;
}
