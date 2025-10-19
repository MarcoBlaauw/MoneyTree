export type RedactionRule = string | RegExp;

const DEFAULT_RULES: RedactionRule[] = [
  /token$/i,
  /secret$/i,
  /access_key$/i,
  /account_number$/i,
  /routing_number$/i,
  /ssn$/i,
  /document/i,
  /email/i,
];

const DEFAULT_REPLACEMENT = "***";

function cloneValue<T>(value: T): T {
  if (typeof structuredClone === "function") {
    return structuredClone(value);
  }

  return JSON.parse(JSON.stringify(value)) as T;
}

function shouldRedact(key: string, rules: RedactionRule[]): boolean {
  return rules.some((rule) => {
    if (typeof rule === "string") {
      return key === rule;
    }

    return rule.test(key);
  });
}

function maskValue(value: unknown, replacement: string): unknown {
  if (typeof value === "string" && value.length > replacement.length) {
    const tail = value.slice(-4);
    return `${replacement}${tail}`;
  }

  if (typeof value === "number") {
    return replacement;
  }

  return replacement;
}

export type Redacted<T> = T extends object ? { [K in keyof T]: Redacted<T[K]> } : T;

export function redactSensitiveFields<T>(
  payload: T,
  rules: RedactionRule[] = DEFAULT_RULES,
  replacement: string = DEFAULT_REPLACEMENT,
): Redacted<T> {
  if (payload === null || typeof payload !== "object") {
    return payload as Redacted<T>;
  }

  const cloned = cloneValue(payload) as Record<string, unknown> | unknown[];

  if (Array.isArray(cloned)) {
    return cloned.map((item) => redactSensitiveFields(item, rules, replacement)) as Redacted<T>;
  }

  return Object.entries(cloned).reduce((acc, [key, value]) => {
    if (shouldRedact(key, rules)) {
      return { ...acc, [key]: maskValue(value, replacement) };
    }

    return { ...acc, [key]: redactSensitiveFields(value, rules, replacement) };
  }, {} as Record<string, unknown>) as Redacted<T>;
}

export const DEFAULT_REDACTION_RULES = DEFAULT_RULES;
export const DEFAULT_REDACTION_REPLACEMENT = DEFAULT_REPLACEMENT;
