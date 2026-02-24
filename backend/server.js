const express = require('express');
const WebSocket = require('ws');
const http = require('http');
const { v4: uuidv4 } = require('uuid');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

app.use(express.json());

// In-memory storage (use Redis for prod)
const devices = new Map(); // deviceToken -> { ws, paired, lastSeen }
const pendingMessages = new Map(); // deviceToken -> [messages]
const responses = new Map(); // deviceToken -> [responses]

// Middleware to check auth token
const authMiddleware = (req, res, next) => {
  const token = req.headers['x-device-token'];
  if (!token) {
    return res.status(401).json({ error: 'Missing device token' });
  }
  req.deviceToken = token;
  next();
};

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'ok', devices: devices.size });
});

// Pair device (called from iOS app after QR scan)
app.post('/pair', (req, res) => {
  const { deviceToken, deviceName } = req.body;
  
  if (!deviceToken) {
    return res.status(400).json({ error: 'Missing deviceToken' });
  }
  
  devices.set(deviceToken, {
    name: deviceName || 'Unknown',
    paired: true,
    ws: null,
    lastSeen: Date.now()
  });
  
  console.log(`Device paired: ${deviceToken} (${deviceName})`);
  res.json({ success: true, paired: true });
});

// Send message from OpenClaw to device
app.post('/message', authMiddleware, (req, res) => {
  const { message, actions = [], type = 'card' } = req.body;
  const deviceToken = req.deviceToken;
  
  const payload = {
    id: uuidv4(),
    type,
    message,
    actions,
    timestamp: Date.now(),
    responded: false
  };
  
  const device = devices.get(deviceToken);
  
  // If device is connected via WebSocket, send immediately
  if (device && device.ws && device.ws.readyState === WebSocket.OPEN) {
    device.ws.send(JSON.stringify(payload));
    console.log(`Message sent to ${deviceToken}: ${message.substring(0, 50)}...`);
    res.json({ success: true, delivered: true, id: payload.id });
  } else {
    // Queue for later delivery
    if (!pendingMessages.has(deviceToken)) {
      pendingMessages.set(deviceToken, []);
    }
    pendingMessages.get(deviceToken).push(payload);
    console.log(`Message queued for ${deviceToken}: ${message.substring(0, 50)}...`);
    res.json({ success: true, delivered: false, queued: true, id: payload.id });
  }
});

// Get message status
app.get('/message/:id/status', authMiddleware, (req, res) => {
  const { id } = req.params;
  // TODO: Track message status properly
  res.json({ id, status: 'unknown' });
});

// Poll for pending messages (fallback when WebSocket is down)
app.get('/poll', authMiddleware, (req, res) => {
  const deviceToken = req.deviceToken;
  const pending = pendingMessages.get(deviceToken) || [];

  // Clear pending messages after returning them
  pendingMessages.set(deviceToken, []);

  res.json(pending);
});

// Dashboard API - System Overview
app.get('/dashboard/overview', authMiddleware, async (req, res) => {
  try {
    // Get session data from OpenClaw gateway
    const { execSync } = require('child_process');
    let sessions = [];
    let agents = [];
    
    try {
      // Try to get sessions list
      const sessionsOutput = execSync('curl -s http://localhost:18789/api/sessions 2>/dev/null || echo "[]"', { encoding: 'utf8' });
      sessions = JSON.parse(sessionsOutput);
    } catch (e) {
      console.log('Could not fetch sessions:', e.message);
    }
    
    // Get agent list from config
    try {
      const configOutput = execSync('cat /Users/kishparikh/.openclaw/openclaw.json 2>/dev/null || echo "{}"', { encoding: 'utf8' });
      const config = JSON.parse(configOutput);
      agents = config.agents?.list?.map(a => ({
        id: a.id,
        model: a.model?.primary,
        heartbeat: a.heartbeat?.every,
        workspace: a.workspace
      })) || [];
    } catch (e) {
      console.log('Could not fetch agents:', e.message);
    }
    
    // Calculate costs (mock for now - would need real usage data)
    const totalTokens = sessions.reduce((sum, s) => sum + (s.totalTokens || 0), 0);
    
    res.json({
      status: 'online',
      timestamp: Date.now(),
      sessions: {
        active: sessions.length,
        list: sessions.slice(0, 5).map(s => ({
          key: s.key,
          kind: s.kind,
          model: s.model,
          totalTokens: s.totalTokens,
          updatedAt: s.updatedAt
        }))
      },
      agents: {
        count: agents.length,
        list: agents
      },
      costs: {
        totalTokens: totalTokens,
        // Rough estimate: $0.50 per 1M tokens
        estimatedCost: (totalTokens / 1000000 * 0.50).toFixed(2)
      },
      clawk: {
        deviceConnected: devices.has(req.deviceToken),
        pendingMessages: pendingMessages.get(req.deviceToken)?.length || 0,
        totalDevices: devices.size
      }
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Dashboard API - Agent Details
app.get('/dashboard/agents/:agentId', authMiddleware, async (req, res) => {
  try {
    const { agentId } = req.params;
    const { execSync } = require('child_process');
    
    // Get agent sessions
    const sessionsOutput = execSync(
      `curl -s "http://localhost:18789/api/sessions?agent=${agentId}" 2>/dev/null || echo "[]"`,
      { encoding: 'utf8' }
    );
    const sessions = JSON.parse(sessionsOutput);
    
    res.json({
      agentId,
      activeSessions: sessions.length,
      sessions: sessions,
      timestamp: Date.now()
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Get responses from device (for OpenClaw to poll)
app.get('/responses', authMiddleware, (req, res) => {
  const deviceToken = req.deviceToken;
  const deviceResponses = responses.get(deviceToken) || [];

  // Clear responses after returning them
  responses.set(deviceToken, []);

  res.json(deviceResponses);
});

// WebSocket connection from iOS app
wss.on('connection', (ws, req) => {
  const token = new URL(req.url, 'http://localhost').searchParams.get('token');
  
  if (!token || !devices.has(token)) {
    ws.close(4001, 'Unauthorized');
    return;
  }
  
  console.log(`WebSocket connected: ${token}`);
  const device = devices.get(token);
  device.ws = ws;
  device.lastSeen = Date.now();
  
  // Send any pending messages
  const pending = pendingMessages.get(token) || [];
  pending.forEach(msg => {
    ws.send(JSON.stringify(msg));
  });
  pendingMessages.set(token, []);
  
  ws.on('message', (data) => {
    try {
      const response = JSON.parse(data);
      console.log(`Response from ${token}:`, response);

      // Store response for OpenClaw to retrieve
      if (!responses.has(token)) {
        responses.set(token, []);
      }
      responses.get(token).push({
        ...response,
        receivedAt: Date.now()
      });
    } catch (e) {
      console.error('Invalid message from device:', e);
    }
  });
  
  ws.on('close', () => {
    console.log(`WebSocket disconnected: ${token}`);
    if (devices.has(token)) {
      devices.get(token).ws = null;
    }
  });
  
  ws.on('error', (err) => {
    console.error(`WebSocket error for ${token}:`, err);
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`Clawk relay running on port ${PORT}`);
});
