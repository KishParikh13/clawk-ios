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
    ok: true,
    status: 'ok', 
    service: 'clawk-relay',
    devices: devices.size,
    dashboardConnected: !!latestDashboardData,
    openclawConnected: !!latestOpenClawStatus,
    hasData: {
      agents: latestDashboardData?.data?.agents?.length || 0,
      sessions: latestDashboardData?.data?.sessions?.length || 0
    }
  });
});

// Minimal tool inventory for KishAgentClient health refresh.
app.get('/tools', (req, res) => {
  res.json({
    ok: true,
    commands: [],
    engines: [],
    recentTools: [],
    updatedAt: new Date().toISOString()
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

// Autonomy MVP development fixtures. The real contract is owned by kish-agent;
// these routes exist so the restored iOS/macOS UI can be exercised locally.
const autonomyNow = () => new Date().toISOString();
const autonomyMinutesAgo = (minutes) => new Date(Date.now() - minutes * 60 * 1000).toISOString();
const autonomyTrace = () => `dev_trace_${Date.now()}`;
const autonomyEnvelope = (data) => ({
  ok: true,
  schemaVersion: 1,
  traceId: autonomyTrace(),
  data
});

const dailyRoutineId = 'routine_daily_brief';
const ideaRoutineId = 'routine_ideas';
const dailyPolicyId = 'policy_daily_brief';
const ideaPolicyId = 'policy_ideas';
let dailyRunCount = 1;

const autonomyState = {
  memory: [
    {
      id: 'mem_concise_updates',
      state: 'pinned',
      text: 'Kish prefers concise engineering updates with concrete verification.',
      summary: 'Prefers concise, verified updates.',
      reviewFlags: [],
      confidence: 0.92,
      provenance: [
        {
          id: 'prov_mem_concise_updates',
          sourceType: 'conversation',
          sourceId: 'conv_memory_restore',
          threadId: 'thread_memory_restore',
          routineRunId: null,
          quote: 'Keep the final answer focused on what changed and what passed.',
          observedAt: autonomyMinutesAgo(70),
          url: null
        }
      ],
      createdAt: autonomyMinutesAgo(70),
      updatedAt: autonomyMinutesAgo(70),
      lastUsedAt: autonomyMinutesAgo(40),
      forgottenAt: null,
      tombstoneReason: null
    },
    {
      id: 'mem_routines_goal',
      state: 'active',
      text: 'Memory and routines should become supervised autonomy: propose recurring work, require approval before enabling, and run safe enabled routines.',
      summary: 'Routines are the path to supervised autonomy.',
      reviewFlags: ['needsReview'],
      confidence: 0.84,
      provenance: [],
      createdAt: autonomyMinutesAgo(65),
      updatedAt: autonomyMinutesAgo(65),
      lastUsedAt: null,
      forgottenAt: null,
      tombstoneReason: null
    }
  ],
  routines: [
    {
      id: dailyRoutineId,
      name: 'Daily brief',
      template: 'dailyBrief',
      state: 'enabled',
      policyId: dailyPolicyId,
      trigger: {
        type: 'scheduled',
        schedule: '0 8 * * *',
        timezone: 'America/Los_Angeles',
        eventName: null
      },
      allowedContextSources: ['conversation', 'memory', 'projectContext'],
      allowedProjectPaths: [],
      allowedActionClasses: ['readContext', 'summarize', 'createReviewCard'],
      outputMode: 'newConversationPerRun',
      createdAt: autonomyMinutesAgo(60),
      updatedAt: autonomyMinutesAgo(60)
    },
    {
      id: ideaRoutineId,
      name: 'Suggest useful routines',
      template: 'ideaGeneration',
      state: 'proposed',
      policyId: ideaPolicyId,
      trigger: {
        type: 'manual',
        schedule: null,
        timezone: null,
        eventName: null
      },
      allowedContextSources: ['conversation', 'memory'],
      allowedProjectPaths: [],
      allowedActionClasses: ['readContext', 'summarize', 'draftArtifact', 'createReviewCard'],
      outputMode: 'newConversationPerRun',
      createdAt: autonomyMinutesAgo(55),
      updatedAt: autonomyMinutesAgo(55)
    }
  ],
  policies: [
    {
      id: dailyPolicyId,
      routineId: dailyRoutineId,
      allowedActions: ['readContext', 'summarize', 'createReviewCard'],
      blockedActions: ['startCoding', 'sendExternalMessage', 'deleteOrDestructive', 'mergeDeployPublish'],
      allowedContextSources: ['conversation', 'memory', 'projectContext'],
      allowedProjectPaths: [],
      maxRuntimeClass: 'short',
      maxCostClass: 'low',
      notificationBehavior: 'dailyBriefDigest',
      createdAt: autonomyMinutesAgo(60),
      approvedAt: autonomyMinutesAgo(59),
      updatedAt: autonomyMinutesAgo(59)
    },
    {
      id: ideaPolicyId,
      routineId: ideaRoutineId,
      allowedActions: ['readContext', 'summarize', 'draftArtifact', 'createReviewCard'],
      blockedActions: ['startCoding', 'sendExternalMessage', 'deleteOrDestructive', 'mergeDeployPublish'],
      allowedContextSources: ['conversation', 'memory'],
      allowedProjectPaths: [],
      maxRuntimeClass: 'medium',
      maxCostClass: 'low',
      notificationBehavior: 'autonomyInbox',
      createdAt: autonomyMinutesAgo(55),
      approvedAt: null,
      updatedAt: autonomyMinutesAgo(55)
    }
  ],
  runs: [
    {
      id: 'run_daily_seed',
      routineId: dailyRoutineId,
      idempotencyKey: 'routine:daily:seed',
      status: 'done',
      conversationId: 'conv_daily_seed',
      threadId: 'thread_daily_seed',
      startedAt: autonomyMinutesAgo(40),
      finishedAt: autonomyMinutesAgo(39),
      priorRunIdsUsed: [],
      error: null,
      retryOfRunId: null,
      reviewCardIdsCreated: ['review_idea_routine'],
      createdAt: autonomyMinutesAgo(40),
      updatedAt: autonomyMinutesAgo(39)
    }
  ],
  reviewCards: [
    {
      id: 'review_idea_routine',
      kind: 'approveRoutine',
      state: 'open',
      title: 'Enable routine suggestions',
      body: 'KishOS found a recurring pattern: review recent chats and propose useful routines. Approve it before it can run on its own.',
      routineId: ideaRoutineId,
      routineRunId: 'run_daily_seed',
      memoryId: null,
      policyId: ideaPolicyId,
      conversationId: 'conv_daily_seed',
      threadId: 'thread_daily_seed',
      reviewFlags: [],
      recommendedAction: 'approve',
      notificationBehavior: 'autonomyInbox',
      createdAt: autonomyMinutesAgo(39),
      updatedAt: autonomyMinutesAgo(39),
      resolvedAt: null
    }
  ],
  latestBrief: {
    id: 'brief_seed',
    routineRunId: 'run_daily_seed',
    conversationId: 'conv_daily_seed',
    threadId: 'thread_daily_seed',
    previousBriefRunId: null,
    summary: 'Memory/routines autonomy is ready for simulator review.',
    sections: [
      { title: 'What changed', items: ['Autonomy UI is restored.', 'Local dev data is available for memory, routines, runs, and review cards.'] },
      { title: 'Needs review', items: ['Approve or reject the proposed routine suggestion card.'] }
    ],
    reviewCardIds: ['review_idea_routine'],
    createdAt: autonomyMinutesAgo(39)
  }
};

function autonomyCounts() {
  const memoryCounts = {
    active: autonomyState.memory.filter((item) => item.state === 'active').length,
    pinned: autonomyState.memory.filter((item) => item.state === 'pinned').length,
    archived: autonomyState.memory.filter((item) => item.state === 'archived').length,
    forgotten: autonomyState.memory.filter((item) => item.state === 'forgotten').length,
    needsReview: autonomyState.memory.filter((item) => item.reviewFlags.includes('needsReview')).length,
    sensitive: autonomyState.memory.filter((item) => item.reviewFlags.includes('sensitive')).length,
    conflicted: autonomyState.memory.filter((item) => item.reviewFlags.includes('conflicted')).length
  };
  const routineCounts = {
    proposed: autonomyState.routines.filter((item) => item.state === 'proposed').length,
    enabled: autonomyState.routines.filter((item) => item.state === 'enabled').length,
    paused: autonomyState.routines.filter((item) => item.state === 'paused').length,
    disabled: autonomyState.routines.filter((item) => item.state === 'disabled').length
  };
  return { memoryCounts, routineCounts };
}

function buildAutonomySummary() {
  const { memoryCounts, routineCounts } = autonomyCounts();
  return {
    latestBrief: autonomyState.latestBrief,
    pendingReviewCount: autonomyState.reviewCards.filter((card) => card.state === 'open').length,
    urgentReviewCount: 0,
    recentRuns: autonomyState.runs.slice(-5).reverse(),
    memoryCounts,
    routineCounts,
    policyIssues: [
      {
        id: 'policy_issue_proposed_routine',
        policyId: ideaPolicyId,
        routineId: ideaRoutineId,
        severity: 'info',
        message: 'One proposed routine is waiting for durable approval.',
        reviewCardId: 'review_idea_routine'
      }
    ],
    updatedAt: autonomyNow()
  };
}

app.get('/autonomy/summary', (req, res) => {
  res.json(autonomyEnvelope({ summary: buildAutonomySummary() }));
});

app.get('/memory', (req, res) => {
  const includeForgotten = req.query.includeForgotten === 'true';
  const memory = includeForgotten
    ? autonomyState.memory
    : autonomyState.memory.filter((item) => item.state !== 'forgotten');
  res.json(autonomyEnvelope({ memory, nextCursor: null }));
});

app.patch('/memory/:id', (req, res) => {
  const memory = autonomyState.memory.find((item) => item.id === req.params.id);
  if (!memory) return res.status(404).json({ ok: false, schemaVersion: 1, traceId: autonomyTrace(), error: { code: 'not_found', message: 'Memory not found.' } });
  Object.assign(memory, {
    state: req.body.state ?? memory.state,
    text: req.body.text ?? memory.text,
    summary: req.body.summary ?? memory.summary,
    reviewFlags: req.body.reviewFlags ?? memory.reviewFlags,
    updatedAt: autonomyNow()
  });
  res.json(autonomyEnvelope({ memory, reviewCards: [] }));
});

app.post('/memory/:id/forget', (req, res) => {
  const memory = autonomyState.memory.find((item) => item.id === req.params.id);
  if (!memory) return res.status(404).json({ ok: false, schemaVersion: 1, traceId: autonomyTrace(), error: { code: 'not_found', message: 'Memory not found.' } });
  memory.state = 'forgotten';
  memory.reviewFlags = [];
  memory.forgottenAt = autonomyNow();
  memory.tombstoneReason = req.body.reason || 'Forgotten from simulator.';
  memory.updatedAt = memory.forgottenAt;
  res.json(autonomyEnvelope({ memory, reviewCards: [] }));
});

app.post('/briefs/daily', (req, res) => {
  const now = autonomyNow();
  dailyRunCount += 1;
  const runId = `run_daily_${dailyRunCount}`;
  const briefId = `brief_${dailyRunCount}`;
  const reviewId = `review_daily_${dailyRunCount}`;
  const run = {
    id: runId,
    routineId: dailyRoutineId,
    idempotencyKey: req.body.idempotencyKey || `routine:daily:${dailyRunCount}`,
    status: 'needsReview',
    conversationId: `conv_daily_${dailyRunCount}`,
    threadId: `thread_daily_${dailyRunCount}`,
    startedAt: now,
    finishedAt: now,
    priorRunIdsUsed: autonomyState.runs.map((item) => item.id).slice(-3),
    error: null,
    retryOfRunId: null,
    reviewCardIdsCreated: [reviewId],
    createdAt: now,
    updatedAt: now
  };
  const reviewCard = {
    id: reviewId,
    kind: 'reviewIdea',
    state: 'open',
    title: 'Review today\'s autonomy brief',
    body: 'The local simulator backend generated a fresh daily brief so you can test the review flow.',
    routineId: dailyRoutineId,
    routineRunId: runId,
    memoryId: null,
    policyId: dailyPolicyId,
    conversationId: run.conversationId,
    threadId: run.threadId,
    reviewFlags: [],
    recommendedAction: 'openConversation',
    notificationBehavior: 'autonomyInbox',
    createdAt: now,
    updatedAt: now,
    resolvedAt: null
  };
  const brief = {
    id: briefId,
    routineRunId: runId,
    conversationId: run.conversationId,
    threadId: run.threadId,
    previousBriefRunId: autonomyState.latestBrief?.routineRunId ?? null,
    summary: 'A new simulator daily brief was generated.',
    sections: [
      { title: 'Routines', items: ['Daily brief ran from the local dev backend.', 'One review card was created.'] },
      { title: 'Memory', items: [`${autonomyState.memory.length} memory items are available for review.`] }
    ],
    reviewCardIds: [reviewId],
    createdAt: now
  };
  autonomyState.runs.push(run);
  autonomyState.reviewCards.push(reviewCard);
  autonomyState.latestBrief = brief;
  res.json(autonomyEnvelope({ brief, run, reviewCards: [reviewCard], conversationId: run.conversationId, threadId: run.threadId }));
});

app.get('/routines', (req, res) => {
  res.json(autonomyEnvelope({ routines: autonomyState.routines }));
});

app.patch('/routines/:id', (req, res) => {
  const routine = autonomyState.routines.find((item) => item.id === req.params.id);
  if (!routine) return res.status(404).json({ ok: false, schemaVersion: 1, traceId: autonomyTrace(), error: { code: 'not_found', message: 'Routine not found.' } });
  routine.name = req.body.name ?? routine.name;
  routine.state = req.body.state ?? routine.state;
  routine.trigger = req.body.trigger ?? routine.trigger;
  routine.allowedContextSources = req.body.allowedContextSources ?? routine.allowedContextSources;
  routine.allowedProjectPaths = req.body.allowedProjectPaths ?? routine.allowedProjectPaths;
  routine.allowedActionClasses = req.body.allowedActionClasses ?? routine.allowedActionClasses;
  routine.updatedAt = autonomyNow();
  res.json(autonomyEnvelope({ routine }));
});

app.delete('/routines/:id', (req, res) => {
  const index = autonomyState.routines.findIndex((item) => item.id === req.params.id);
  if (index === -1) return res.status(404).json({ ok: false, schemaVersion: 1, traceId: autonomyTrace(), error: { code: 'not_found', message: 'Routine not found.' } });
  const [routine] = autonomyState.routines.splice(index, 1);
  autonomyState.policies = autonomyState.policies.filter((item) => item.routineId !== routine.id);
  autonomyState.reviewCards = autonomyState.reviewCards.filter((item) => item.routineId !== routine.id);
  res.json(autonomyEnvelope({}));
});

app.post('/routines/:id/run', (req, res) => {
  const routine = autonomyState.routines.find((item) => item.id === req.params.id);
  if (!routine) return res.status(404).json({ ok: false, schemaVersion: 1, traceId: autonomyTrace(), error: { code: 'not_found', message: 'Routine not found.' } });
  const now = autonomyNow();
  const run = {
    id: `run_${routine.id}_${Date.now()}`,
    routineId: routine.id,
    idempotencyKey: req.body.idempotencyKey || `routine:${routine.id}:manual:${Date.now()}`,
    status: routine.state === 'enabled' ? 'done' : 'needsApproval',
    conversationId: `conv_${routine.id}`,
    threadId: `thread_${routine.id}`,
    startedAt: now,
    finishedAt: now,
    priorRunIdsUsed: [],
    error: null,
    retryOfRunId: null,
    reviewCardIdsCreated: [],
    createdAt: now,
    updatedAt: now
  };
  autonomyState.runs.push(run);
  res.json(autonomyEnvelope({ run, reviewCards: [], conversationId: run.conversationId, threadId: run.threadId, duplicate: false }));
});

app.get('/routine-runs', (req, res) => {
  const runs = req.query.routineId
    ? autonomyState.runs.filter((item) => item.routineId === req.query.routineId)
    : autonomyState.runs;
  res.json(autonomyEnvelope({ runs, nextCursor: null }));
});

app.get('/review-cards', (req, res) => {
  const state = req.query.state || 'open';
  const reviewCards = autonomyState.reviewCards.filter((card) => state === 'all' || card.state === state);
  res.json(autonomyEnvelope({ reviewCards, nextCursor: null }));
});

app.patch('/review-cards/:id', (req, res) => {
  const reviewCard = autonomyState.reviewCards.find((card) => card.id === req.params.id);
  if (!reviewCard) return res.status(404).json({ ok: false, schemaVersion: 1, traceId: autonomyTrace(), error: { code: 'not_found', message: 'Review card not found.' } });
  const now = autonomyNow();
  reviewCard.state = req.body.decision === 'reject' ? 'rejected' : 'approved';
  reviewCard.updatedAt = now;
  reviewCard.resolvedAt = now;
  const relatedRoutine = autonomyState.routines.find((item) => item.id === reviewCard.routineId) || null;
  const relatedPolicy = autonomyState.policies.find((item) => item.id === reviewCard.policyId) || null;
  if (relatedRoutine && reviewCard.kind === 'approveRoutine' && req.body.decision === 'approve') {
    relatedRoutine.state = 'enabled';
    relatedRoutine.updatedAt = now;
  }
  res.json(autonomyEnvelope({
    reviewCard,
    relatedMemory: reviewCard.memoryId ? autonomyState.memory.find((item) => item.id === reviewCard.memoryId) || null : null,
    relatedRoutine,
    relatedPolicy
  }));
});

app.get('/policies', (req, res) => {
  const policies = req.query.routineId
    ? autonomyState.policies.filter((item) => item.routineId === req.query.routineId)
    : autonomyState.policies;
  res.json(autonomyEnvelope({ policies }));
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
