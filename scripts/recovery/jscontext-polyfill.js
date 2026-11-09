// JavaScriptCore has typed arrays but lacks the browser's UTF-8 encoder.
globalThis.TextEncoder ??= class {
  encode(text = "") {
    return Uint8Array.from(unescape(encodeURIComponent(text)), (byte) => byte.charCodeAt(0));
  }
};
