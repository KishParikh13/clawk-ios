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
const devices = new Map();
const pendingMessages = new Map();
const responses = new Map();

// Dashboard connections
const KISHOS_DASHBOARD_URL = process.env.KISHOS_DASHBOARD_URL || 'http://localhost:4004';
let dashboardEventSource = null;
let openclawStatusSource = null;
let latestDashboardData = null;
let latestOpenClawStatus = null;
let pollingInterval = null;

// Dashboard broadcaster
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
      if (device.ws?.readyState === WebSocket.OPEN) {
        try {
          device.ws.send(payload);
          sentCount++;
        } catch (err) {
          console.error(`Failed to send to ${token}:`, err.message);
        }
      }
    }
    if (sentCount > 0) {
      console.log(`📡 Broadcast ${type} to ${sentCount} device(s)`);
    }
  }
}

// Primary data fetching via polling (reliable)
async function fetchDashboardData() {
  try {
    // Ensure data structure exists
    if (!latestDashboardData) latestDashboardData = { data: {} };
    if (!latestDashboardData.data) latestDashboardData.data = {};

    // Fetch agents
    const agentsRes = await fetch(`${KISHOS_DASHBOARD_URL}/api/agents`);
    if (agentsRes.ok) {
      const agentsData = await agentsRes.json();
      // Handle both wrapped {agents: [...]} and direct array [...] formats
      latestDashboardData.data.agents = Array.isArray(agentsData) ? agentsData : (agentsData.agents || []);
    }

    // Fetch sessions
    const sessionsRes = await fetch(`${KISHOS_DASHBOARD_URL}/api/sessions`);
    if (sessionsRes.ok) {
      const sessionsData = await sessionsRes.json();
      // Handle both wrapped {sessions: [...]} and direct array [...] formats
      latestDashboardData.data.sessions = Array.isArray(sessionsData) ? sessionsData : (sessionsData.sessions || []);
    }

    // Fetch OpenClaw status
    const statusRes = await fetch(`${KISHOS_DASHBOARD_URL}/api/openclaw/status`);
    if (statusRes.ok) {
      latestOpenClawStatus = await statusRes.json();
    }

    return true;
  } catch (err) {
    console.error('❌ Dashboard fetch error:', err.message);
    return false;
  }
}

// Start polling
function startPolling() {
  if (pollingInterval) return;
  console.log('🔄 Starting dashboard polling (5s interval)');
  
  // Fetch immediately
  fetchDashboardData();
  
  pollingInterval = setInterval(async () => {
    const success = await fetchDashboardData();
    if (success) {
      DashboardBroadcaster.broadcast('update', latestDashboardData?.data);
    }
  }, 5000);
}

// SSE for real-time updates (enhancement)
function initSSE() {
  try {
    // OpenClaw status stream
    openclawStatusSource = new EventSource(`${KISHOS_DASHBOARD_URL}/api/openclaw/status/stream`);
    openclawStatusSource.onmessage = (e) => {
      try {
        const parsed = JSON.parse(e.data);
        if (parsed.type === 'snapshot') {
          latestOpenClawStatus = parsed.data;
          DashboardBroadcaster.broadcast('openclaw_status', parsed.data);
        }
      } catch (err) {}
    };
    openclawStatusSource.onerror = () => {};
    console.log('✅ SSE: OpenClaw status stream');
  } catch (err) {
    console.log('⚠️ SSE OpenClaw failed:', err.message);
  }

  try {
    // Events stream
    dashboardEventSource = new EventSource(`${KISHOS_DASHBOARD_URL}/api/events`);
    dashboardEventSource.onmessage = (e) => {
      try {
        const parsed = JSON.parse(e.data);
        latestDashboardData = parsed;
        DashboardBroadcaster.broadcast('events', parsed);
      } catch (err) {}
    };
    dashboardEventSource.onerror = () => {};
    console.log('✅ SSE: Events stream');
  } catch (err) {
    console.log('⚠️ SSE events failed:', err.message);
  }
}

// Auth middleware
const authMiddleware = (req, res, next) => {
  const token = req.headers['x-device-token'];
  if (!token) return res.status(401).json({ error: 'Missing device token' });
  req.deviceToken = token;
  next();
};

// Health check
app.get('/health', (req, res) => {
  res.json({ 
    status: 'ok', 
    devices: devices.size,
    dashboardConnected: !!latestDashboardData,
    openclawConnected: !!latestOpenClawStatus,
    hasData: {
      agents: latestDashboardData?.data?.agents?.length || 0,
      sessions: latestDashboardData?.data?.sessions?.length || 0
    }
  });
});

// Pair device
app.post('/pair', (req, res) => {
  const { deviceToken, deviceName } = req.body;
  if (!deviceToken) return res.status(400).json({ error: 'Missing deviceToken' });
  
  devices.set(deviceToken, {
    name: deviceName || 'Unknown',
    paired: true,
    ws: null,
    lastSeen: Date.now()
  });
  
  console.log(`📱 Device paired: ${deviceToken}`);
  res.json({ success: true, paired: true });
});

// Send message to device
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
  
  if (device?.ws?.readyState === WebSocket.OPEN) {
    device.ws.send(JSON.stringify(payload));
    res.json({ success: true, delivered: true, id: payload.id });
  } else {
    if (!pendingMessages.has(deviceToken)) pendingMessages.set(deviceToken, []);
    pendingMessages.get(deviceToken).push(payload);
    res.json({ success: true, delivered: false, queued: true, id: payload.id });
  }
});

// Poll for messages
app.get('/poll', authMiddleware, (req, res) => {
  const deviceToken = req.deviceToken;
  const pending = pendingMessages.get(deviceToken) || [];
  pendingMessages.set(deviceToken, []);
  res.json(pending);
});

// Dashboard Overview
app.get('/dashboard/overview', authMiddleware, (req, res) => {
  const sessions = latestDashboardData?.data?.sessions || [];
  const agents = latestDashboardData?.data?.agents || [];
  const totalTokens = sessions.reduce((sum, s) => 
    sum + (s.tokensUsed?.input || 0) + (s.tokensUsed?.output || 0), 0);
  const totalCost = sessions.reduce((sum, s) => sum + (s.totalCost || 0), 0);
  
  res.json({
    status: 'online',
    timestamp: Date.now(),
    live: !!latestDashboardData,
    sessions: {
      active: sessions.filter(s => 
        s.lastActivity && (Date.now() - new Date(s.lastActivity).getTime()) < 300000
      ).length,
      list: sessions.slice(0, 20).map(s => ({
        id: s.id,
        key: s.id,
        agentId: s.agentId,
        agentName: s.agent?.name || s.agentId,
        agentEmoji: s.agent?.emoji || '🤖',
        model: s.model,
        totalTokens: (s.tokensUsed?.input || 0) + (s.tokensUsed?.output || 0),
        totalCost: s.totalCost,
        updatedAt: s.lastActivity,
        messageCount: s.messageCount,
        status: s.lastActivity && 
          (Date.now() - new Date(s.lastActivity).getTime()) < 300000 ? 'active' : 'idle'
      }))
    },
    agents: {
      count: agents.length,
      list: agents.map(a => ({
        id: a.id,
        name: a.name,
        emoji: a.emoji,
        color: a.color,
        model: a.model,
        status: a.status,
        skillCount: a.skills?.length || 0
      }))
    },
    costs: {
      totalTokens,
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
});

// Dashboard Agents
app.get('/dashboard/agents', authMiddleware, (req, res) => {
  const agents = latestDashboardData?.data?.agents || [];
  res.json({
    agents: agents.map(a => ({
      id: a.id,
      name: a.name,
      emoji: a.emoji,
      color: a.color,
      model: a.model,
      status: a.status,
      skills: a.skills || [],
      activeSkills: a.activeSkills || []
    })),
    timestamp: Date.now()
  });
});

// Dashboard Sessions
app.get('/dashboard/sessions', authMiddleware, (req, res) => {
  const sessions = latestDashboardData?.data?.sessions || [];
  const agents = latestDashboardData?.data?.agents || [];
  const agentMap = new Map(agents.map(a => [a.id, a]));
  
  res.json({
    sessions: sessions.map(s => {
      const agent = agentMap.get(s.agentId);
      const isActive = s.lastActivity && 
        (Date.now() - new Date(s.lastActivity).getTime()) < 300000;
      
      return {
        id: s.id,
        key: s.id,
        agentId: s.agentId,
        agentName: agent?.name || s.agent?.name || s.agentId,
        agentEmoji: agent?.emoji || s.agent?.emoji || '🤖',
        agentColor: agent?.color || s.agent?.color || '#888888',
        model: s.model,
        projectPath: s.projectPath,
        startedAt: s.startedAt,
        lastActivity: s.lastActivity,
        messageCount: s.messageCount,
        totalCost: s.totalCost,
        tokensUsed: s.tokensUsed,
        source: s.source,
        status: isActive ? 'active' : 'idle'
      };
    }),
    activeCount: sessions.filter(s => 
      s.lastActivity && (Date.now() - new Date(s.lastActivity).getTime()) < 300000
    ).length,
    totalCount: sessions.length,
    timestamp: Date.now()
  });
});

// Session messages
app.get('/dashboard/sessions/:id/messages', authMiddleware, async (req, res) => {
  try {
    const response = await fetch(`${KISHOS_DASHBOARD_URL}/api/sessions/${req.params.id}/messages`);
    if (!response.ok) throw new Error('Failed to fetch');
    const data = await response.json();
    res.json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Dashboard Costs
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

// Get responses from device
app.get('/responses', authMiddleware, (req, res) => {
  const deviceToken = req.deviceToken;
  const deviceResponses = responses.get(deviceToken) || [];
  responses.set(deviceToken, []);
  res.json(deviceResponses);
});

// WebSocket connection
wss.on('connection', (ws, req) => {
  const token = new URL(req.url, 'http://localhost').searchParams.get('token');
  
  if (!token || !devices.has(token)) {
    ws.close(4001, 'Unauthorized');
    return;
  }
  
  console.log(`🔌 WebSocket connected: ${token}`);
  const device = devices.get(token);
  device.ws = ws;
  device.lastSeen = Date.now();
  
  // Send pending messages
  const pending = pendingMessages.get(token) || [];
  pending.forEach(msg => ws.send(JSON.stringify(msg)));
  pendingMessages.set(token, []);
  
  // Send current dashboard data
  if (latestDashboardData) {
    ws.send(JSON.stringify({
      type: 'dashboard',
      dashboardType: 'snapshot',
      data: latestDashboardData.data,
      timestamp: Date.now()
    }));
  }
  
  ws.on('message', (data) => {
    try {
      const response = JSON.parse(data);
      if (!responses.has(token)) responses.set(token, []);
      responses.get(token).push({ ...response, receivedAt: Date.now() });
    } catch (e) {
      console.error('Invalid message:', e);
    }
  });
  
  ws.on('close', () => {
    console.log(`🔌 WebSocket disconnected: ${token}`);
    if (devices.has(token)) devices.get(token).ws = null;
  });
  
  ws.on('error', (err) => console.error(`WebSocket error:`, err));
});

// Start server
const PORT = process.env.PORT || 3002;
server.listen(PORT, () => {
  console.log(`🚀 Clawk relay running on port ${PORT}`);
  console.log(`📊 Dashboard URL: ${KISHOS_DASHBOARD_URL}`);
  
  // Start polling immediately
  startPolling();
  
  // Try SSE for real-time updates
  setTimeout(initSSE, 2000);
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('Shutting down...');
  if (pollingInterval) clearInterval(pollingInterval);
  if (dashboardEventSource) dashboardEventSource.close();
  if (openclawStatusSource) openclawStatusSource.close();
  server.close(() => process.exit(0));
});
