const express = require('express');
const WebSocket = require('ws');
const http = require('http');
const { v4: uuidv4 } = require('uuid');
const EventSource = require('eventsource');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

app.use(express.json());

// In-memory storage (use Redis for prod)
const devices = new Map(); // deviceToken -> { ws, paired, lastSeen }
const pendingMessages = new Map(); // deviceToken -> [messages]
const responses = new Map(); // deviceToken -> [responses]

// Dashboard SSE connections
const KISHOS_DASHBOARD_URL = process.env.KISHOS_DASHBOARD_URL || 'http://localhost:3000';
let dashboardEventSource = null;
let openclawStatusSource = null;
let latestDashboardData = null;
let latestOpenClawStatus = null;

// Dashboard broadcaster - sends to all connected devices
class DashboardBroadcaster {
  static broadcast(type, data) {
    const payload = JSON.stringify({
      type: 'dashboard',
      dashboardType: type,
      data,
      timestamp: Date.now()
    });

    let sentCount = 0;
    for (const [token, device] of devices) {
      if (device.ws && device.ws.readyState === WebSocket.OPEN) {
        try {
          device.ws.send(payload);
          sentCount++;
        } catch (err) {
          console.error(`Failed to send dashboard update to ${token}:`, err.message);
        }
      }
    }
    if (sentCount > 0) {
      console.log(`Dashboard ${type} broadcast to ${sentCount} device(s)`);
    }
  }
}

// Initialize SSE connections to kishos-dashboard
function initDashboardStreams() {
  // Stream 1: OpenClaw status (cron jobs, heartbeats)
  try {
    openclawStatusSource = new EventSource(`${KISHOS_DASHBOARD_URL}/api/openclaw/status/stream`);
    
    openclawStatusSource.onmessage = (event) => {
      try {
        const parsed = JSON.parse(event.data);
        if (parsed.type === 'snapshot') {
          latestOpenClawStatus = parsed.data;
          DashboardBroadcaster.broadcast('openclaw_status', parsed.data);
        }
      } catch (err) {
        console.error('Failed to parse openclaw status:', err.message);
      }
    };

    openclawStatusSource.onerror = (err) => {
      console.error('OpenClaw status SSE error:', err.message || 'Connection failed');
    };

    console.log(`Connected to OpenClaw status stream: ${KISHOS_DASHBOARD_URL}/api/openclaw/status/stream`);
  } catch (err) {
    console.error('Failed to connect to OpenClaw status stream:', err.message);
  }

  // Stream 2: Events (sessions, tasks, agents)
  try {
    dashboardEventSource = new EventSource(`${KISHOS_DASHBOARD_URL}/api/events?days=7`);
    
    dashboardEventSource.onmessage = (event) => {
      try {
        const parsed = JSON.parse(event.data);
        latestDashboardData = parsed;
        
        if (parsed.type === 'snapshot') {
          DashboardBroadcaster.broadcast('snapshot', parsed.data);
        } else if (parsed.type === 'sessions_update') {
          DashboardBroadcaster.broadcast('sessions', parsed.data);
        } else if (parsed.type === 'tasks_snapshot') {
          DashboardBroadcaster.broadcast('tasks', parsed.data);
        } else if (parsed.type === 'agent_status') {
          DashboardBroadcaster.broadcast('agent_status', parsed.data);
        } else if (parsed.type === 'cost_update') {
          DashboardBroadcaster.broadcast('costs', parsed.data);
        }
      } catch (err) {
        console.error('Failed to parse dashboard event:', err.message);
      }
    };

    dashboardEventSource.onerror = (err) => {
      console.error('Dashboard events SSE error:', err.message || 'Connection failed');
    };

    console.log(`Connected to dashboard events stream: ${KISHOS_DASHBOARD_URL}/api/events`);
  } catch (err) {
    console.error('Failed to connect to dashboard events stream:', err.message);
  }
}

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
  res.json({ 
    status: 'ok', 
    devices: devices.size,
    dashboardConnected: !!dashboardEventSource,
    openclawConnected: !!openclawStatusSource,
    latestData: {
      hasDashboard: !!latestDashboardData,
      hasOpenClaw: !!latestOpenClawStatus
    }
  });
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

// Dashboard API - System Overview (now returns cached live data)
app.get('/dashboard/overview', authMiddleware, async (req, res) => {
  try {
    // Build response from cached live data
    const sessions = latestDashboardData?.data?.sessions || [];
    const agents = latestDashboardData?.data?.agents || [];
    const totalTokens = sessions.reduce((sum, s) => sum + (s.tokensUsed?.input || 0) + (s.tokensUsed?.output || 0), 0);
    const totalCost = sessions.reduce((sum, s) => sum + (s.totalCost || 0), 0);
    
    res.json({
      status: 'online',
      timestamp: Date.now(),
      live: !!latestDashboardData,
      sessions: {
        active: sessions.length,
        list: sessions.slice(0, 10).map(s => ({
          id: s.id,
          key: s.id,
          agentId: s.agentId,
          kind: s.agent?.name || s.agentId,
          model: s.model,
          totalTokens: (s.tokensUsed?.input || 0) + (s.tokensUsed?.output || 0),
          totalCost: s.totalCost,
          updatedAt: s.lastActivity,
          messageCount: s.messageCount
        }))
      },
      agents: {
        count: agents.length,
        list: agents.map(a => ({
          id: a.id,
          name: a.name,
          emoji: a.emoji,
          model: a.model,
          status: a.status,
          skillCount: a.skills?.length || 0
        }))
      },
      costs: {
        totalTokens: totalTokens,
        totalCost: totalCost.toFixed(4),
        estimatedCost: totalCost.toFixed(2)
      },
      cron: latestOpenClawStatus ? {
        totalJobs: latestOpenClawStatus.summary?.totalCronJobs || 0,
        enabledJobs: latestOpenClawStatus.summary?.enabledCronJobs || 0,
        errors: latestOpenClawStatus.summary?.cronErrors || 0,
        heartbeats: latestOpenClawStatus.summary?.heartbeatCount || 0,
        staleHeartbeats: latestOpenClawStatus.summary?.staleHeartbeats || 0
      } : null,
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

// Dashboard API - Agents with live status
app.get('/dashboard/agents', authMiddleware, async (req, res) => {
  try {
    const agents = latestDashboardData?.data?.agents || [];
    res.json({
      agents: agents.map(a => ({
        id: a.id,
        name: a.name,
        emoji: a.emoji,
        model: a.model,
        status: a.status,
        skills: a.skills || [],
        activeSkills: a.activeSkills || []
      })),
      timestamp: Date.now()
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Dashboard API - Costs
app.get('/dashboard/costs', authMiddleware, async (req, res) => {
  try {
    const period = req.query.period || 'week';
    const response = await fetch(`${KISHOS_DASHBOARD_URL}/api/costs?period=${period}`);
    const data = await response.json();
    res.json(data);
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
  
  // Send initial dashboard data if available
  if (latestDashboardData) {
    ws.send(JSON.stringify({
      type: 'dashboard',
      dashboardType: 'snapshot',
      data: latestDashboardData.data,
      timestamp: Date.now()
    }));
  }
  if (latestOpenClawStatus) {
    ws.send(JSON.stringify({
      type: 'dashboard',
      dashboardType: 'openclaw_status',
      data: latestOpenClawStatus,
      timestamp: Date.now()
    }));
  }
  
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
  console.log(`Kishos Dashboard URL: ${KISHOS_DASHBOARD_URL}`);
  
  // Initialize SSE streams after server starts
  setTimeout(initDashboardStreams, 1000);
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('Shutting down...');
  if (dashboardEventSource) dashboardEventSource.close();
  if (openclawStatusSource) openclawStatusSource.close();
  server.close(() => {
    process.exit(0);
  });
});
