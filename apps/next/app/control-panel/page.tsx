import { headers } from "next/headers";

import { renderControlPanelPage } from "./render-control-panel-page";

async function readHeaders() {
  try {
    return await headers();
  } catch {
    return null;
  }
}

export default async function ControlPanelPage() {
  const headerList = await readHeaders();
  const csrfToken = headerList?.get("x-csrf-token") ?? "";

  return renderControlPanelPage(undefined, { csrfToken });
}
