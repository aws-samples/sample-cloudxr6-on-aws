/**
 * CloudXR 6 Signaling Proxy
 *
 * Handles two responsibilities:
 * 1. HTTP API: /api/session (Cognito JWT validation + instance allocation), /health, and static file serving
 * 2. WebSocket signaling: TRANSPARENT TCP-level proxy to GPU instances
 *
 * The WebSocket proxy operates at the transport level — after the HTTP upgrade,
 * raw TCP bytes are piped bidirectionally between client and backend. This is
 * critical because CloudXR Runtime's signaling protocol relies on connection
 * identity (peer registration is tied to the TCP socket). A message-level relay
 * breaks this assumption. HAProxy and nginx work the same way — tunnel after upgrade.
 *
 * Static web client is served from the bundled public/ directory.
 */

const http = require("http");
const net = require("net");
const fs = require("fs");
const path = require("path");
const jwt = require("jsonwebtoken");
const jwksClient = require("jwks-rsa");
const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const {
  DynamoDBDocumentClient,
  ScanCommand,
  UpdateCommand,
} = require("@aws-sdk/lib-dynamodb");

// Configuration from environment (set by ECS task definition)
const PORT = parseInt(process.env.PORT || "8080");
const AWS_REGION = process.env.AWS_REGION;
const COGNITO_USER_POOL_ID = process.env.COGNITO_USER_POOL_ID;
const COGNITO_APP_CLIENT_ID = process.env.COGNITO_APP_CLIENT_ID;
const DYNAMODB_TABLE = process.env.DYNAMODB_TABLE || "CloudXRInstances";

// JWKS client for Cognito token validation
const jwks = jwksClient({
  jwksUri: `https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}/.well-known/jwks.json`,
  cache: true,
  cacheMaxAge: 600000,
});

/**
 * Verify Cognito JWT token
 * Validates signature (via JWKS), issuer, and audience/client_id.
 * Returns decoded token payload on success, throws on failure.
 */
async function verifyToken(token) {
  const decoded = jwt.decode(token, { complete: true });
  if (!decoded || !decoded.header || !decoded.header.kid) {
    throw new Error("Invalid token format");
  }

  const key = await jwks.getSigningKey(decoded.header.kid);
  const publicKey = key.getPublicKey();

  const payload = jwt.verify(token, publicKey, {
    issuer: `https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}`,
  });

  // Cognito ID tokens have "aud" = app client ID
  // Cognito access tokens have "client_id" = app client ID
  const tokenClientId = payload.aud || payload.client_id;
  if (tokenClientId !== COGNITO_APP_CLIENT_ID) {
    throw new Error("Token was not issued for this application");
  }

  return payload;
}

// DynamoDB client
const ddbClient = new DynamoDBClient({ region: AWS_REGION });
const ddb = DynamoDBDocumentClient.from(ddbClient);

/**
 * Find an available GPU instance in DynamoDB for the given device type
 */
async function findAvailableInstance(deviceType) {
  const pool = deviceType === "native" ? "native" : "webrtc";

  const result = await ddb.send(
    new ScanCommand({
      TableName: DYNAMODB_TABLE,
      // Strongly consistent: claimInstance() retries after losing a race, and an
      // eventually-consistent read would hand back the same stale row again.
      ConsistentRead: true,
      FilterExpression: "#s = :available AND #p = :pool",
      ExpressionAttributeNames: { "#s": "status", "#p": "pool" },
      ExpressionAttributeValues: { ":available": "available", ":pool": pool },
    })
  );

  if (!result.Items || result.Items.length === 0) {
    return null;
  }

  return result.Items[0];
}

/**
 * Update instance status in DynamoDB
 */
async function updateInstanceStatus(instanceId, status) {
  await ddb.send(
    new UpdateCommand({
      TableName: DYNAMODB_TABLE,
      Key: { instanceId },
      UpdateExpression: "SET #s = :status, lastUpdated = :ts",
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: {
        ":status": status,
        ":ts": new Date().toISOString(),
      },
    })
  );
}

/**
 * Atomically claim an available instance for a session.
 *
 * The scan-then-write sequence is racy on its own: the service runs two proxy tasks, so
 * two concurrent upgrades can read the same "available" row and both mark it occupied,
 * handing one GPU to two clients. The ConditionExpression makes the claim atomic — only
 * one writer can transition a row out of "available" — and a failed condition just means
 * someone else won, so we retry with whatever is still free.
 */
async function claimInstance(deviceType, attempts = 5) {
  for (let i = 0; i < attempts; i++) {
    const instance = await findAvailableInstance(deviceType);
    if (!instance) return null;

    try {
      await ddb.send(
        new UpdateCommand({
          TableName: DYNAMODB_TABLE,
          Key: { instanceId: instance.instanceId },
          UpdateExpression: "SET #s = :occupied, lastUpdated = :ts",
          ConditionExpression: "#s = :available",
          ExpressionAttributeNames: { "#s": "status" },
          ExpressionAttributeValues: {
            ":occupied": "occupied",
            ":available": "available",
            ":ts": new Date().toISOString(),
          },
        })
      );
      return instance;
    } catch (err) {
      if (err.name === "ConditionalCheckFailedException") {
        console.log(`  ${instance.instanceId} was claimed by another session; retrying`);
        continue;
      }
      throw err;
    }
  }
  return null;
}

/**
 * Serve static files from public/ directory
 */
function serveStatic(req, res) {
  const urlPath = req.url.split('?')[0];
  const filePath = path.join(__dirname, "public", urlPath === "/" ? "index.html" : urlPath);

  if (!filePath.startsWith(path.join(__dirname, "public"))) {
    res.writeHead(403, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "forbidden" }));
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "not_found" }));
      return;
    }
    const ext = path.extname(filePath).toLowerCase();
    const contentTypes = {
      ".html": "text/html",
      ".js": "application/javascript",
      ".css": "text/css",
      ".json": "application/json",
      ".svg": "image/svg+xml",
      ".ico": "image/x-icon",
      ".glb": "model/gltf-binary",
    };
    res.writeHead(200, { "Content-Type": contentTypes[ext] || "application/octet-stream" });
    res.end(data);
  });
}

/**
 * Handle HTTP requests (API + static files)
 */
async function handleRequest(req, res) {
  // Health check
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "healthy" }));
    return;
  }

  // Session API: allocate a GPU instance
  if (req.url === "/api/session" && req.method === "POST") {
    let body = "";
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", async () => {
      try {
        const { token, deviceType } = JSON.parse(body || "{}");

        if (!token) {
          res.writeHead(401, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "unauthorized", message: "Missing auth token" }));
          return;
        }

        // Validate Cognito JWT
        try {
          await verifyToken(token);
        } catch (authErr) {
          console.error("Token validation failed:", authErr.message);
          res.writeHead(401, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "unauthorized", message: "Invalid or expired token" }));
          return;
        }

        const instance = await findAvailableInstance(deviceType || "webrtc");
        if (!instance) {
          res.writeHead(503, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "no_capacity", message: "No streaming instances available." }));
          return;
        }

        console.log(`Session allocated: ${instance.instanceId} (${deviceType || "webrtc"})`);

        // Media is established by ICE (the runtime is configured with a STUN server),
        // so no media address or port is handed to the client.
        res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
        res.end(JSON.stringify({
          signalingUrl: `wss://${req.headers.host}`,
          instanceId: instance.instanceId,
        }));
      } catch (err) {
        console.error("Session API error:", err.message);
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "internal", message: "Failed to allocate session" }));
      }
    });
    return;
  }

  // CORS preflight
  if (req.url === "/api/session" && req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
    });
    res.end();
    return;
  }

  // Static files
  serveStatic(req, res);
}

/**
 * Extract a Cognito JWT from an upgrade request.
 *
 * The signaling upgrade must be authenticated: without this, anyone who can reach the
 * endpoint can open a WSS upgrade and be allocated a GPU instance, since /api/session
 * is only an advisory capacity check and does not gate the binding.
 *
 * Three sources, because the two client paths carry credentials differently:
 *   - Authorization: Bearer <jwt>  — native clients (CloudXR Framework `signalingHeaders`)
 *   - ?token=<jwt> query parameter — web clients via CloudXR.js `signalingQueryParameters`
 *   - cxr_token cookie             — the bundled login page sets this after Cognito auth,
 *                                    and the browser sends it automatically on the
 *                                    same-origin WSS upgrade
 * CloudFront's AllViewer origin request policy forwards all three to the ALB.
 */
function extractUpgradeToken(req) {
  const auth = req.headers["authorization"];
  if (auth && auth.toLowerCase().startsWith("bearer ")) {
    return { token: auth.slice(7).trim(), source: "header" };
  }

  const url = new URL(req.url, "http://localhost");
  const qsToken = url.searchParams.get("token");
  if (qsToken) return { token: qsToken, source: "query" };

  const cookieHeader = req.headers["cookie"];
  if (cookieHeader) {
    for (const part of cookieHeader.split(";")) {
      const [k, ...v] = part.trim().split("=");
      if (k === "cxr_token" && v.length) {
        return { token: decodeURIComponent(v.join("=")), source: "cookie" };
      }
    }
  }
  return { token: null, source: null };
}

/**
 * Handle WebSocket upgrade — TRANSPARENT TCP TUNNEL
 *
 * After the HTTP upgrade handshake, we pipe raw TCP bytes between client and
 * backend. This preserves the connection identity that CloudXR Runtime's
 * signaling protocol requires (peer registration is tied to the TCP socket).
 */
async function handleUpgrade(req, clientSocket, head) {
  const clientIp = req.headers['x-forwarded-for'] || clientSocket.remoteAddress;
  console.log(`WebSocket upgrade: ${req.url} from ${clientIp}`);

  try {
    // Authenticate before allocating any GPU capacity
    const { token, source: tokenSource } = extractUpgradeToken(req);
    if (!token) {
      console.warn(`Upgrade rejected (no credential) from ${clientIp}`);
      clientSocket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
      clientSocket.destroy();
      return;
    }
    try {
      await verifyToken(token);
    } catch (authErr) {
      console.warn(`Upgrade rejected (invalid ${tokenSource} token) from ${clientIp}: ${authErr.message}`);
      clientSocket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
      clientSocket.destroy();
      return;
    }
    console.log(`Upgrade authenticated via ${tokenSource}`);

    // Determine device type and find instance
    const deviceType = req.headers["x-cloudxr-device-type"] === "native" ? "native" : "webrtc";
    const signalingPort = deviceType === "native" ? 48010 : 49100;

    // Atomically claim an instance — see claimInstance() for why this cannot be a
    // plain scan followed by an unconditional write.
    const instance = await claimInstance(deviceType);
    if (!instance) {
      clientSocket.write('HTTP/1.1 503 Service Unavailable\r\n\r\n');
      clientSocket.destroy();
      return;
    }

    console.log(`Signaling session: ${instance.instanceId} (${deviceType}) → ${instance.privateIp}:${signalingPort}`);

    // Construct the backend URL path
    // Client sends: /cloudxr.example.com/sign_in?peer_id=...
    // We strip the first path segment (signalingResourcePath) and forward the rest
    const clientUrl = new URL(req.url, 'http://localhost');
    const pathParts = clientUrl.pathname.split('/').filter(Boolean);
    const backendPath = pathParts.length > 1
      ? '/' + pathParts.slice(1).join('/')
      : clientUrl.pathname;

    // Strip our auth parameter before forwarding. It is consumed by this proxy and is
    // not part of CloudXR's signaling protocol — the runtime should never see it.
    clientUrl.searchParams.delete("token");
    const forwardedSearch = clientUrl.searchParams.toString();
    const backendFullPath = backendPath + (forwardedSearch ? `?${forwardedSearch}` : '');

    // Open TCP connection to the backend GPU instance
    const backendSocket = net.createConnection(signalingPort, instance.privateIp, () => {
      // Construct the HTTP upgrade request to send to the backend
      // This recreates the WebSocket handshake but directed at the backend
      const upgradeHeaders = [
        `GET ${backendFullPath} HTTP/1.1`,
        `Host: ${instance.privateIp}:${signalingPort}`,
        `Upgrade: websocket`,
        `Connection: Upgrade`,
        `Sec-WebSocket-Key: ${req.headers['sec-websocket-key']}`,
        `Sec-WebSocket-Version: ${req.headers['sec-websocket-version'] || '13'}`,
      ];

      // Forward subprotocol if present
      if (req.headers['sec-websocket-protocol']) {
        upgradeHeaders.push(`Sec-WebSocket-Protocol: ${req.headers['sec-websocket-protocol']}`);
      }

      upgradeHeaders.push('', ''); // End headers with blank line
      backendSocket.write(upgradeHeaders.join('\r\n'));
    });

    // Wait for backend's upgrade response, then start piping
    let upgradeResponseReceived = false;
    let responseBuffer = Buffer.alloc(0);

    backendSocket.on('data', (data) => {
      if (!upgradeResponseReceived) {
        // Accumulate the HTTP upgrade response from backend
        responseBuffer = Buffer.concat([responseBuffer, data]);
        const responseStr = responseBuffer.toString();
        const headerEnd = responseStr.indexOf('\r\n\r\n');

        if (headerEnd !== -1) {
          upgradeResponseReceived = true;

          // Forward the entire upgrade response to the client
          const responseHeader = responseBuffer.slice(0, headerEnd + 4);
          const remaining = responseBuffer.slice(headerEnd + 4);

          clientSocket.write(responseHeader);

          // If there's data after the headers, forward it too
          if (remaining.length > 0) {
            clientSocket.write(remaining);
          }

          // Send any buffered head data from the original upgrade request
          if (head && head.length > 0) {
            backendSocket.write(head);
          }

          // Clear the connect deadline. setTimeout is an IDLE timer, not a connect
          // timeout — leaving it armed would fire 10s after the last signaling message
          // and tear down a perfectly healthy session, since media is out-of-band UDP
          // and the signaling socket goes quiet during streaming.
          backendSocket.setTimeout(0);

          // Now pipe bidirectionally — raw TCP tunnel
          clientSocket.pipe(backendSocket);
          backendSocket.pipe(clientSocket);

          console.log(`  Tunnel established: client ↔ ${instance.privateIp}:${signalingPort}`);
        }
      }
      // After upgrade response is handled, piping takes over (data handler is replaced)
    });

    // Handle disconnects — release instance
    const cleanup = (source) => {
      return () => {
        console.log(`  ${source} disconnected: ${instance.instanceId}`);
        clientSocket.destroy();
        backendSocket.destroy();
        updateInstanceStatus(instance.instanceId, "available").catch(() => {});
      };
    };

    clientSocket.on('close', cleanup('Client'));
    clientSocket.on('error', cleanup('Client error'));
    backendSocket.on('close', cleanup('Backend'));
    backendSocket.on('error', (err) => {
      console.error(`  Backend connection error: ${err.message}`);
      // Only safe to send an HTTP status before the upgrade completes. Afterwards the
      // socket carries WebSocket frames and raw HTTP bytes would corrupt the stream.
      if (!upgradeResponseReceived) {
        clientSocket.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
      }
      clientSocket.destroy();
      updateInstanceStatus(instance.instanceId, "available").catch(() => {});
    });

    // Connect deadline only — cleared above once the tunnel is established.
    backendSocket.setTimeout(10000, () => {
      if (upgradeResponseReceived) return;   // belt and braces
      console.error(`  Backend connection timeout: ${instance.privateIp}:${signalingPort}`);
      clientSocket.write('HTTP/1.1 504 Gateway Timeout\r\n\r\n');
      clientSocket.destroy();
      backendSocket.destroy();
      updateInstanceStatus(instance.instanceId, "available").catch(() => {});
    });

  } catch (err) {
    console.error("Upgrade handling failed:", err.message);
    clientSocket.write('HTTP/1.1 500 Internal Server Error\r\n\r\n');
    clientSocket.destroy();
  }
}

// Create HTTP server
const server = http.createServer(handleRequest);

// Handle WebSocket upgrades at the transport level
server.on("upgrade", handleUpgrade);

// Start
server.listen(PORT, () => {
  console.log(`CloudXR Proxy listening on port ${PORT}`);
  console.log(`  API:       http://localhost:${PORT}/api/session`);
  console.log(`  Health:    http://localhost:${PORT}/health`);
  console.log(`  Static:    http://localhost:${PORT}/`);
  console.log(`  WebSocket: transparent TCP tunnel on upgrade`);
  console.log(`  Region:    ${AWS_REGION}`);
  console.log(`  Cognito:   ${COGNITO_USER_POOL_ID}`);
  console.log(`  DynamoDB:  ${DYNAMODB_TABLE}`);
});
