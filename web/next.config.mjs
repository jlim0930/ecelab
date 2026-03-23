/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Allow long-running SSE connections for log streaming
  experimental: {
    serverActions: {
      bodySizeLimit: '2mb',
    },
  },
};

export default nextConfig;
