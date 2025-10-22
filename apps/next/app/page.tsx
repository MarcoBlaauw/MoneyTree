import { headers } from "next/headers";

import { renderHomePage } from "./render-home-page";

export default async function Home() {
  const forwardedPrefix = await readForwardedPrefix();
  return renderHomePage({ forwardedPrefix });
}

async function readForwardedPrefix() {
  try {
    const headerList = await headers();
    return headerList.get("x-forwarded-prefix");
  } catch {
    return null;
  }
}

