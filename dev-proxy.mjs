// Single-port reverse proxy for exposing this dev environment publicly via
// one ngrok tunnel (the free plan allows exactly one simultaneous
// endpoint). Routes /api/* (including WebSocket upgrades -- VM Console,
// live log tails, agent connect endpoints) to the Go backend on :8080;
// everything else (the Next.js app, including its own HMR websocket) to
// :3000. Having both reachable under one origin also means the frontend
// and API appear same-origin to the browser, so session cookies and CORS
// need no special cross-site configuration.
import http from "node:http";

const BACKEND = { host: "127.0.0.1", port: 8080 };
const FRONTEND = { host: "127.0.0.1", port: 3001 };
const LISTEN_PORT = 4000;

const proxy = http.createServer();

function targetFor(req) {
  return req.url.startsWith("/api/") ? BACKEND : FRONTEND;
}

proxy.on("request", (req, res) => {
  const target = targetFor(req);
  const proxyReq = http.request(
    { host: target.host, port: target.port, path: req.url, method: req.method, headers: req.headers },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode ?? 502, proxyRes.headers);
      proxyRes.pipe(res, { end: true });
    }
  );
  proxyReq.on("error", (err) => {
    console.error("proxy request error:", err.message);
    if (!res.headersSent) res.writeHead(502);
    res.end("Bad gateway");
  });
  req.pipe(proxyReq, { end: true });
});

proxy.on("upgrade", (req, socket, head) => {
  // The client socket (the browser's end of the WS connection, arriving
  // through ngrok) resets constantly in normal operation -- a closed tab,
  // a dropped tunnel hop, a page navigating away mid-handshake. A raw
  // net.Socket's 'error' event has no default handler, so leaving this
  // unlistened crashes the ENTIRE proxy process (and every other
  // in-flight connection through it) on the very first such reset. This
  // is what actually took the proxy down earlier -- fixed here for real,
  // not just restarted.
  socket.on("error", (err) => {
    console.error("client socket error:", err.message);
  });

  const target = targetFor(req);
  const upstream = http.request({
    host: target.host, port: target.port, path: req.url, method: req.method, headers: req.headers,
  });
  upstream.on("upgrade", (upstreamRes, upstreamSocket, upstreamHead) => {
    upstreamSocket.on("error", (err) => {
      console.error("upstream socket error:", err.message);
      socket.destroy();
    });
    socket.write(
      `HTTP/1.1 101 Switching Protocols\r\n` +
        Object.entries(upstreamRes.headers)
          .map(([k, v]) => `${k}: ${v}`)
          .join("\r\n") +
        "\r\n\r\n"
    );
    if (upstreamHead && upstreamHead.length) socket.write(upstreamHead);
    upstreamSocket.pipe(socket);
    socket.pipe(upstreamSocket);
  });
  // If the upstream rejects the upgrade (e.g. the backend's own
  // CheckOrigin/auth check on this endpoint fails), it answers with a
  // plain HTTP response instead of a 101 -- Node's http.request fires
  // 'response' for that, never 'upgrade'. Without a handler here, that
  // rejection response is read but never relayed anywhere: the browser's
  // WebSocket just sits there with no close/error frame ever arriving,
  // looking exactly like a hang instead of the clean, fast rejection it
  // actually is. Relay it so a real error reaches the client instead.
  upstream.on("response", (upstreamRes) => {
    const statusLine = `HTTP/1.1 ${upstreamRes.statusCode} ${upstreamRes.statusMessage || ""}\r\n`;
    const headers =
      Object.entries(upstreamRes.headers)
        .map(([k, v]) => `${k}: ${v}`)
        .join("\r\n") + "\r\n\r\n";
    socket.write(statusLine + headers);
    upstreamRes.pipe(socket);
  });
  upstream.on("error", (err) => {
    console.error("proxy upgrade error:", err.message);
    socket.destroy();
  });
  upstream.end();
});

proxy.on("error", (err) => {
  console.error("proxy server error:", err.message);
});

// Last-resort safety net: this is a dev proxy standing between a public
// tunnel and everything else, so staying up through an unexpected error
// matters far more than failing loudly. Anything that reaches here is
// logged, never silently swallowed, but never takes the process down.
process.on("uncaughtException", (err) => {
  console.error("uncaught exception (proxy kept running):", err);
});

proxy.listen(LISTEN_PORT, () => {
  console.log(`dev-proxy listening on http://127.0.0.1:${LISTEN_PORT} -> /api/* to :${BACKEND.port}, everything else to :${FRONTEND.port}`);
});
