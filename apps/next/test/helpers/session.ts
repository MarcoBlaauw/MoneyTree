export const SESSION_COOKIE = "_money_tree_session";
export const BASE_URL = process.env.PLAYWRIGHT_BASE_URL || "http://127.0.0.1:4000";

export function extractSessionToken(headers: { name: string; value: string }[]): string | null {
  for (const header of headers) {
    if (header.name.toLowerCase() !== "set-cookie") {
      continue;
    }

    const [cookiePair] = header.value.split(";");
    const [name, ...valueParts] = cookiePair.split("=");

    if (name === SESSION_COOKIE) {
      return valueParts.join("=");
    }
  }

  return null;
}
