const basePath = process.env.NEXT_BASE_PATH ?? "/app/react";
const allowedDevOrigins = [
  process.env.NEXT_PUBLIC_PHOENIX_ORIGIN,
  "http://localhost:4000",
  "http://127.0.0.1:4000",
].filter(Boolean);

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  basePath,
  allowedDevOrigins,
  assetPrefix: process.env.NEXT_ASSET_PREFIX || undefined,
};

export default nextConfig;
