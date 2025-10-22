import { headers } from "next/headers";

import { renderHomePage } from "./render-home-page";
import { buildPhoenixUrl } from "./lib/build-phoenix-url";
import type { HeaderList } from "./lib/build-phoenix-url";

export default async function Home() {
  const headerList = await readHeaders();
  const forwardedPrefix = readForwardedPrefix(headerList);

  return renderHomePage({
    forwardedPrefix,
    buildPhoenixUrl: (path: string) => buildPhoenixUrl(path, headerList ?? undefined),
    headerList: headerList ?? undefined,
  });
}

async function readHeaders(): Promise<HeaderList | null> {
  try {
    return await headers();
  } catch {
    return null;
  }
}

function readForwardedPrefix(headerList: HeaderList | null) {
  if (!headerList) {
    return null;
  }

  return headerList.get("x-forwarded-prefix") ?? null;
}

