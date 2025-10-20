const isDev = process.env.NODE_ENV !== "production";
const basePath =
  process.env.NEXT_BASE_PATH ?? (isDev ? "" : "/app/react");

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  basePath,
  assetPrefix: process.env.NEXT_ASSET_PREFIX || undefined,
};

export default nextConfig;
