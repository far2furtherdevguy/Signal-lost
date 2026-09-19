const http = require('http');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 8080;
const DATA_DIR = path.join(__dirname, 'data');
const DATA_FILE = path.join(DATA_DIR, 'players.json');
const K_ELO = 32;
const START_ELO = 1000;
const TASKS_PER_CREW = 5;
const KILL_COOLDOWN_MS = 20000;
const MEETING_VOTE_MS = 30000;
const MIN_PLAYERS = 4;
const MAX_PLAYERS = 4;

// ---------- persistence ----------
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
let playersDB = {};
try { playersDB = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); } catch (e) { playersDB = {}; }
let dirty = false;
function saveDB() {
  if (!dirty) return;
  try { fs.writeFileSync(DATA_FILE, JSON.stringify(playersDB)); dirty = false; } catch (e) { console.error('save failed', e); }
}
setInterval(saveDB, 10000);
process.on('exit', saveDB);

function getPlayer(id) {
  if (!playersDB[id]) playersDB[id] = { name: '', elo: START_ELO, games: 0, wins: 0, impostorWins: 0 };
  return playersDB[id];
}

// ---------- http server (health check for uptime robot / netlify page) ----------
const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      ok: true, name: 'Signal Lost Server', uptime: process.uptime(),
      playersOnline: clients.size, rooms: rooms.size, queue: matchmakingQueue.length
    }));
  } else {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Signal Lost server is running. Connect via WebSocket.');
  }
});

// ---------- websocket ----------
const wss = new WebSocketServer({ server });
const clients = new Map();   // ws -> player object
const rooms = new Map();     // code -> room
const matchmakingQueue = []; // ws list

function send(ws, msg) { if (ws.readyState === 1) ws.send(JSON.stringify(msg)); }
function broadcast(room, msg, exceptWs = null) {
  for (const p of room.players) if (p.ws !== exceptWs) send(p.ws, msg);
}
function makeCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let c = '';
  do { c = Array.from({length: 6}, () => chars[Math.floor(Math.random()*chars.length)]).join(''); } while (rooms.has(c));
  return c;
}
function publicPlayer(p) { return { id: p.id, name: p.name, elo: p.elo, alive: p.alive, connected: p.ws.readyState === 1 }; }
function lobbyState(room) {
  return { type: 'lobby', code: room.code, host: room.host, players: room.players.map(publicPlayer) };
}

// ---------- elo ----------
function eloDelta(winnerElo, loserElo, won) {
  const expected = 1 / (1 + Math.pow(10, (loserElo - winnerElo) / 400));
  return Math.round(K_ELO * ((won ? 1 : 0) - expected));
}

// ---------- room / game ----------
function createRoom(hostWs) {
  const host = clients.get(hostWs);
  const code = makeCode();
  const room = {
    code, host: host.id, phase: 'lobby', players: [host],
    impostorId: null, tasksDone: 0, totalTasks: 0,
    killAvailableAt: 0, meeting: null, interval: null
  };
  host.room = code;
  rooms.set(code, room);
  return room;
}

function joinRoom(ws, room) {
  const p = clients.get(ws);
  if (room.players.length >= MAX_PLAYERS) { send(ws, { type: 'error', message: 'Room is full' }); return false; }
  if (room.phase !== 'lobby') { send(ws, { type: 'error', message: 'Game already started' }); return false; }
  p.room = room.code;
  room.players.push(p);
  broadcast(room, lobbyState(room));
  return true;
}

function leaveCurrentRoom(ws) {
  const p = clients.get(ws);
  if (!p || !p.room) return;
  const room = rooms.get(p.room);
  p.room = null;
  if (!room) return;
  if (room.phase === 'lobby') {
    room.players = room.players.filter(x => x.ws !== ws);
    if (room.players.length === 0) { rooms.delete(room.code); return; }
    if (room.host === p.id) room.host = room.players[0].id;
    broadcast(room, lobbyState(room));
  } else {
    // in-game: treat as disconnect, mark dead
    p.alive = false;
    broadcast(room, { type: 'player_left', id: p.id });
    checkWin(room);
  }
}

function tryMatchmake() {
  while (matchmakingQueue.length >= MIN_PLAYERS) {
    const group = matchmakingQueue.splice(0, MIN_PLAYERS);
    const room = createRoom(group[0]);
    for (let i = 1; i < group.length; i++) { clients.get(group[i]).room = room.code; room.players.push(clients.get(group[i])); }
    broadcast(room, lobbyState(room));
    setTimeout(() => startGame(room), 4000); // short countdown then auto-start
  }
  for (const ws of matchmakingQueue) send(ws, { type: 'queue_update', count: matchmakingQueue.length });
}

function startGame(room) {
  if (room.phase !== 'lobby' || room.players.length < MIN_PLAYERS) return;
  room.phase = 'game';
  room.impostorId = room.players[Math.floor(Math.random() * room.players.length)].id;
  const crew = room.players.filter(p => p.id !== room.impostorId);
  room.totalTasks = crew.length * TASKS_PER_CREW;
  room.tasksDone = 0;
  room.killAvailableAt = Date.now() + KILL_COOLDOWN_MS;
  for (const p of room.players) {
    p.alive = true;
    p.vote = null;
    p.tasksDone = 0;
    send(p.ws, {
      type: 'game_start',
      code: room.code,
      role: p.id === room.impostorId ? 'impostor' : 'crewmate',
      impostorId: p.id === room.impostorId ? p.id : null,
      players: room.players.map(publicPlayer),
      tasksRequired: p.id === room.impostorId ? 0 : TASKS_PER_CREW
    });
  }
  broadcast(room, { type: 'game_state', phase: 'game', players: room.players.map(publicPlayer), tasksDone: 0, totalTasks: room.totalTasks });
}

function alivePlayers(room) { return room.players.filter(p => p.alive); }
function aliveCrew(room) { return room.players.filter(p => p.alive && p.id !== room.impostorId); }

function checkWin(room) {
  if (room.phase !== 'game' && room.phase !== 'meeting') return;
  const impostor = room.players.find(p => p.id === room.impostorId);
  const crewLeft = aliveCrew(room).length;
  if (!impostor.alive) return endGame(room, 'crewmate', 'The Impostor was ejected.');
  if (room.tasksDone >= room.totalTasks) return endGame(room, 'crewmate', 'All tasks completed.');
  if (crewLeft <= 1) return endGame(room, 'impostor', 'The Impostor eliminated the crew.');
}

function endGame(room, winner, reason) {
  clearInterval(room.interval);
  room.phase = 'over';
  const deltas = {};
  for (const p of room.players) {
    const db = getPlayer(p.id);
    const won = (winner === 'impostor') === (p.id === room.impostorId);
    const avgOther = room.players.filter(x => x.id !== p.id).reduce((s, x) => s + x.elo, 0) / (room.players.length - 1);
    const d = eloDelta(p.elo, avgOther, won);
    db.elo = Math.max(100, db.elo + d);
    db.games += 1;
    if (won) db.wins += 1;
    if (won && p.id === room.impostorId) db.impostorWins += 1;
    p.elo = db.elo;
    deltas[p.id] = d;
    dirty = true;
  }
  broadcast(room, { type: 'game_over', winner, reason, eloDeltas: deltas, players: room.players.map(publicPlayer) });
  // reset room to lobby for rematch
  setTimeout(() => {
    if (room.players.length > 0) {
      room.phase = 'lobby';
      for (const p of room.players) { p.alive = true; p.vote = null; }
      broadcast(room, lobbyState(room));
    } else rooms.delete(room.code);
  }, 8000);
}

function startMeeting(room, caller, bodyId) {
  if (room.phase !== 'game') return;
  room.phase = 'meeting';
  for (const p of room.players) p.vote = null;
  room.meeting = { endsAt: Date.now() + MEETING_VOTE_MS };
  broadcast(room, { type: 'meeting_called', by: caller.name, bodyId: bodyId || null, endsAt: room.meeting.endsAt, players: room.players.map(publicPlayer) });
  room.interval = setInterval(() => {
    if (Date.now() >= room.meeting.endsAt) resolveVotes(room);
  }, 1000);
}

function resolveVotes(room) {
  if (room.phase !== 'meeting') return;
  clearInterval(room.interval);
  const votes = {};
  let skip = 0, voted = 0;
  for (const p of room.players) {
    if (!p.alive) continue;
    if (!p.vote) continue;
    voted++;
    if (p.vote === 'skip') skip++;
    else votes[p.vote] = (votes[p.vote] || 0) + 1;
  }
  let top = null, topN = 0, tie = false;
  for (const [id, n] of Object.entries(votes)) {
    if (n > topN) { top = id; topN = n; tie = false; }
    else if (n === topN) tie = true;
  }
  const totalAlive = alivePlayers(room).length;
  let ejected = null;
  // require majority of alive votes and no tie; low turnout = skip
  if (!tie && top && topN > skip && topN > totalAlive / 2) {
    ejected = room.players.find(p => p.id === top);
    if (ejected) ejected.alive = false;
  }
  broadcast(room, { type: 'vote_result', ejected: ejected ? { id: ejected.id, name: ejected.name, wasImpostor: ejected.id === room.impostorId } : null, votes: Object.fromEntries(room.players.filter(p=>p.vote).map(p => [p.id, p.vote])), players: room.players.map(publicPlayer) });
  room.meeting = null;
  if (checkWinOver(room, ejected)) return;
  room.phase = 'game';
  room.killAvailableAt = Date.now() + KILL_COOLDOWN_MS;
  broadcast(room, { type: 'resume_game', players: room.players.map(publicPlayer) });
}

function checkWinOver(room, ejected) {
  if (ejected && ejected.id === room.impostorId) { endGame(room, 'crewmate', 'The Impostor was ejected.'); return true; }
  if (aliveCrew(room).length <= 1) { endGame(room, 'impostor', 'The Impostor eliminated the crew.'); return true; }
  return false;
}

// ---------- connection handling ----------
wss.on('connection', (ws) => {
  const id = 'p' + Math.random().toString(36).slice(2, 10);
  const p = { ws, id, name: 'Player', elo: START_ELO, room: null, alive: true, vote: null, tasksDone: 0 };
  clients.set(ws, p);

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch (e) { return; }
    const player = clients.get(ws);
    if (!player) return;

    switch (msg.type) {
      case 'join': {
        player.name = String(msg.name || 'Player').slice(0, 20);
        const db = getPlayer(id);
        db.name = player.name;
        player.elo = db.elo;
        dirty = true;
        send(ws, { type: 'welcome', id, name: player.name, elo: player.elo, games: db.games, wins: db.wins });
        break;
      }
      case 'find_match': {
        if (player.room) { send(ws, { type: 'error', message: 'Already in a room' }); break; }
        if (!matchmakingQueue.includes(ws)) {
          matchmakingQueue.push(ws);
          send(ws, { type: 'queue_update', count: matchmakingQueue.length });
          tryMatchmake();
        }
        break;
      }
      case 'cancel_match': {
        const i = matchmakingQueue.indexOf(ws);
        if (i >= 0) { matchmakingQueue.splice(i, 1); send(ws, { type: 'queue_update', count: matchmakingQueue.length }); }
        break;
      }
      case 'create_private': {
        if (player.room) { send(ws, { type: 'error', message: 'Already in a room' }); break; }
        const room = createRoom(ws);
        send(ws, lobbyState(room));
        break;
      }
      case 'join_private': {
        if (player.room) { send(ws, { type: 'error', message: 'Already in a room' }); break; }
        const room = rooms.get(String(msg.code || '').toUpperCase().trim());
        if (!room) { send(ws, { type: 'error', message: 'Room not found' }); break; }
        joinRoom(ws, room);
        break;
      }
      case 'start_game': {
        const room = rooms.get(player.room);
        if (room && room.host === player.id) startGame(room);
        break;
      }
      case 'leave_room': {
        leaveCurrentRoom(ws);
        send(ws, { type: 'left_room' });
        break;
      }
      case 'task_complete': {
        const room = rooms.get(player.room);
        if (!room || room.phase !== 'game' || player.id === room.impostorId || !player.alive) break;
        if (player.tasksDone >= TASKS_PER_CREW) break;
        player.tasksDone++;
        room.tasksDone++;
        broadcast(room, { type: 'task_progress', by: player.name, tasksDone: room.tasksDone, totalTasks: room.totalTasks });
        if (room.tasksDone >= room.totalTasks) endGame(room, 'crewmate', 'All tasks completed.');
        break;
      }
      case 'kill': {
        const room = rooms.get(player.room);
        if (!room || room.phase !== 'game' || player.id !== room.impostorId || !player.alive) break;
        if (Date.now() < room.killAvailableAt) { send(ws, { type: 'error', message: 'Kill on cooldown' }); break; }
        const target = room.players.find(x => x.id === msg.targetId);
        if (!target || !target.alive || target.id === room.impostorId) break;
        target.alive = false;
        room.killAvailableAt = Date.now() + KILL_COOLDOWN_MS;
        broadcast(room, { type: 'player_killed', id: target.id, name: target.name, killAvailableAt: room.killAvailableAt, players: room.players.map(publicPlayer) }, ws);
        send(ws, { type: 'player_killed', id: target.id, name: target.name, killAvailableAt: room.killAvailableAt, players: room.players.map(publicPlayer) });
        checkWin(room);
        break;
      }
      case 'report': {
        const room = rooms.get(player.room);
        if (!room || room.phase !== 'game' || !player.alive) break;
        startMeeting(room, player, msg.bodyId);
        break;
      }
      case 'emergency': {
        const room = rooms.get(player.room);
        if (!room || room.phase !== 'game' || !player.alive || player.id === room.impostorId) break;
        startMeeting(room, player, null);
        break;
      }
      case 'vote': {
        const room = rooms.get(player.room);
        if (!room || room.phase !== 'meeting' || !player.alive) break;
        if (msg.skip) player.vote = 'skip';
        else {
          const t = room.players.find(x => x.id === msg.targetId);
          if (!t || !t.alive) break;
          player.vote = t.id;
        }
        const alive = alivePlayers(room).length;
        const voted = room.players.filter(x => x.alive && x.vote).length;
        broadcast(room, { type: 'vote_update', voted, total: alive });
        if (voted >= alive) resolveVotes(room);
        break;
      }
      case 'ping': send(ws, { type: 'pong', t: msg.t }); break;
    }
  });

  ws.on('close', () => {
    const i = matchmakingQueue.indexOf(ws);
    if (i >= 0) matchmakingQueue.splice(i, 1);
    leaveCurrentRoom(ws);
    clients.delete(ws);
    saveDB();
  });
});

setInterval(() => { for (const ws of clients.keys()) { if (ws.readyState === 1) ws.ping(); } }, 30000);

server.listen(PORT, () => console.log('Signal Lost server listening on port ' + PORT));
