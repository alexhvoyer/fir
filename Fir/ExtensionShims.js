// Fir: loaded first in a Firefox add-on's background. Stands in for Firefox APIs WebKit lacks, which
// add-ons such as Tampermonkey and Violentmonkey call unchecked at startup.
(() => {
  const api = globalThis.browser;
  if (!api) return;
  const event = () => ({ addListener() {}, removeListener() {}, hasListener() { return false; } });
  // Callback style and promise style both.
  const answer = (value, args) => {
    const callback = args.find(arg => typeof arg === 'function');
    if (callback) callback(value);
    return Promise.resolve(value);
  };

  if (!api.notifications) {
    api.notifications = {
      create: (...args) => answer(typeof args[0] === 'string' ? args[0] : '', args),
      clear: (...args) => answer(false, args),
      update: (...args) => answer(false, args),
      getAll: (...args) => answer({}, args),
      onClicked: event(), onClosed: event(), onButtonClicked: event(), onShown: event(),
    };
  }

  if (api.storage && !api.storage.managed) {
    api.storage.managed = { get: (...args) => answer({}, args), getBytesInUse: (...args) => answer(0, args), onChanged: event() };
  }

  if (api.runtime && !api.runtime.getBrowserInfo) {
    api.runtime.getBrowserInfo = (...args) => answer({ name: 'Firefox', vendor: 'Mozilla', version: '128.0', buildID: '20260101000000' }, args);
  }

  // contentScripts.register: injected on each navigation instead, through tabs.executeScript.
  if (!(api.contentScripts && api.contentScripts.register) && api.tabs && api.tabs.executeScript && api.webNavigation) {
    const patternToRegExp = pattern => {
      if (pattern === '<all_urls>') return /^(https?|wss?|file|ftp):\/\//;
      const parts = /^(\*|https?|wss?|file|ftp):\/\/([^/]*)(\/.*)$/.exec(pattern);
      if (!parts) return null;
      const escape = text => text.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
      const scheme = parts[1] === '*' ? 'https?' : escape(parts[1]);
      const host = parts[2] === '*' ? '[^/]*'
        : parts[2].startsWith('*.') ? '([^/]*\\.)?' + escape(parts[2].slice(2)) : escape(parts[2]);
      const path = escape(parts[3]).replace(/\*/g, '.*');
      return new RegExp('^' + scheme + '://' + host + path + '$');
    };
    const matchesAny = (patterns, url) => (patterns || []).some(pattern => {
      const expression = patternToRegExp(pattern);
      return expression ? expression.test(url) : false;
    });
    const registered = new Set();
    // A navigation that wakes the background arrives before the add-on registers again; it gets replayed.
    const started = Date.now();
    let waiting = [];
    const inject = (details, early) => {
      if (!registered.size && waiting && Date.now() - started < 5000) { waiting.push([details, early]); return; }
      for (const script of registered) {
        const runAt = script.runAt || 'document_idle';
        if ((runAt === 'document_start') !== early) continue;
        if (details.frameId !== 0 && !script.allFrames) continue;
        if (!matchesAny(script.matches, details.url) || matchesAny(script.excludeMatches, details.url)) continue;
        for (const source of script.js || []) {
          const options = { frameId: details.frameId, runAt, matchAboutBlank: !!script.matchAboutBlank };
          if (source.code !== undefined) options.code = source.code; else options.file = source.file;
          api.tabs.executeScript(details.tabId, options).catch(() => {});
        }
      }
    };
    api.webNavigation.onCommitted.addListener(details => inject(details, true));
    api.webNavigation.onDOMContentLoaded.addListener(details => inject(details, false));
    api.contentScripts = {
      register: async options => {
        const script = { ...options };
        registered.add(script);
        const replay = waiting || [];
        waiting = null;
        for (const [details, early] of replay) inject(details, early);
        return { unregister: async () => { registered.delete(script); } };
      },
    };
  }
})();
