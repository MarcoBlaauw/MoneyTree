import { JSDOM } from "jsdom";

export function setupDom() {
  const dom = new JSDOM("<!doctype html><html><body></body></html>", {
    url: "http://localhost:3000",
  });

  const jsdomWindow = dom.window as unknown as Window & typeof globalThis;

  globalThis.window = jsdomWindow;
  globalThis.document = jsdomWindow.document;
  globalThis.HTMLElement = jsdomWindow.HTMLElement;
  globalThis.Node = jsdomWindow.Node;
  try {
    globalThis.navigator = jsdomWindow.navigator;
  } catch {
    Object.defineProperty(globalThis, "navigator", {
      configurable: true,
      enumerable: true,
      writable: true,
      value: jsdomWindow.navigator,
    });
  }
  globalThis.CustomEvent = jsdomWindow.CustomEvent;
  globalThis.self = jsdomWindow;
  // Create global bindings for environments where `window` is not defined by default.
  Function("window = globalThis.window; self = globalThis.self;")();

  if (!jsdomWindow.requestIdleCallback) {
    jsdomWindow.requestIdleCallback = (callback) =>
      jsdomWindow.setTimeout(() =>
        callback({
          didTimeout: false,
          timeRemaining: () => 0,
        } as IdleDeadline),
      1);
  }

  if (!jsdomWindow.cancelIdleCallback) {
    jsdomWindow.cancelIdleCallback = (handle: number) => jsdomWindow.clearTimeout(handle);
  }

  globalThis.requestIdleCallback = jsdomWindow.requestIdleCallback;
  globalThis.cancelIdleCallback = jsdomWindow.cancelIdleCallback;

  return () => {
    dom.window.close();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    delete (globalThis as any).window;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    delete (globalThis as any).document;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    delete (globalThis as any).self;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    delete (globalThis as any).requestIdleCallback;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    delete (globalThis as any).cancelIdleCallback;
  };
}
