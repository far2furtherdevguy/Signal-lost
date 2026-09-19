# SIGNAL LOST

A 4-player social deception game (Among Us style) for Android, with a WebSocket backend, ELO matchmaking, and **zero local setup** — everything builds in GitHub Actions.

**3 crew. 1 impostor. Trust no one.**

---

## Architecture

```
signal-lost/
├── server/                  # Node.js WebSocket game server (deploy to Render)
│   ├── index.js             # rooms, matchmaking, game logic, ELO, JSON persistence
│   └── package.json
├── flutter/                 # Android app (built by GitHub Actions -> APK)
│   ├── lib/main.dart
│   └── pubspec.yaml
├── keepalive/
│   └── index.html           # static status page (deploy to Netlify, keeps server awake)
├── .github/workflows/
│   └── build-apk.yml        # builds APK on push / manual dispatch
└── render.yaml              # Render blueprint (auto-detects the service)
```

**Features**
- Random matchmaking queue (auto-starts at 4 players)
- Private rooms with 6-character codes
- Roles: 1 impostor (kill cooldown 20s, fake tasks), 3 crewmates (5 tasks each)
- Report dead bodies + emergency meetings, timed voting with skip
- Win conditions: tasks done / impostor ejected (crew) vs. crew reduced to 1 (impostor)
- ELO system (K=32, expected-score) persisted in `server/data/players.json`
- Server-enforced cooldowns & vote resolution (clients can't cheat)

---

## Deploy steps (no local setup, everything in the cloud)

### 1. Create the GitHub repository
1. Create a new repo on github.com (e.g. `signal-lost`).
2. Upload **all files from this folder** to it (via web upload, or `git push` — no build tools needed locally).
3. Go to **Settings → Secrets and variables → Actions → Variables** and add:
   - Name: `SERVER_URL`  Value: `wss://your-app.onrender.com` (set this after step 2 below; you can update it later and re-run the workflow).

### 2. Deploy the WebSocket server on Render
1. On [render.com](https://render.com), click **New → Web Service** and connect your GitHub repo.
2. Render will auto-detect `render.yaml` (or configure manually):
   - **Root directory:** `server`
   - **Build command:** `npm install`
   - **Start command:** `node index.js`
   - **Plan:** Free
3. Deploy. When it finishes, copy your URL: `https://your-app.onrender.com`.
   - WebSocket clients connect with `wss://your-app.onrender.com` (Render supports WSS).
   - The `/health` endpoint returns live server stats as JSON (used by the keep-alive page & UptimeRobot).

> **Note:** the Render free tier spins down after ~15 min of inactivity. Steps 3 + 4 keep it awake. Also, the free tier disk is **ephemeral** — `players.json` resets if the service is redeployed/restarted. ELO persists across sleep/wake, but not across redeploys. (Render persistent disks are a paid upgrade if you need that.)

### 3. Keep the server alive — UptimeRobot
1. Create a free account at [uptimerobot.com](https://uptimerobot.com).
2. **Add New Monitor → HTTP(s)**:
   - URL: `https://your-app.onrender.com/health`
   - Interval: **5 minutes**
3. Done — the server never sleeps.

### 4. Keep-alive page on Netlify (free)
1. Edit `keepalive/index.html`: replace `https://signal-lost-server.onrender.com` with your Render URL (one line, marked with `>>>`).
2. Drag the `keepalive/` folder onto [app.netlify.com/drop](https://app.netlify.com/drop).
3. You now have a status page showing live player/room counts, and it pings the server every 5 min from any open browser tab.

### 5. Build the APK with GitHub Actions
1. In your repo: **Actions → "Build Flutter APK" → Run workflow**.
2. When it finishes, open the run → **Artifacts → signal-lost-apk** → download `app-release.apk`.
3. Install on any Android phone (allow "install from unknown sources").
4. Every push to `main` that touches `flutter/` rebuilds the APK automatically. Manual dispatch also creates a GitHub Release with the APK attached.

---

## Game protocol (JSON over WebSocket)

| Direction | Message | Purpose |
|---|---|---|
| C→S | `join {name}` | identify, get ELO |
| C→S | `find_match` / `cancel_match` | random queue |
| C→S | `create_private` / `join_private {code}` | private rooms |
| C→S | `start_game` | host launches |
| C→S | `task_complete` | crew finishes a task |
| C→S | `kill {targetId}` | impostor kill (server cooldown) |
| C→S | `report` / `emergency` | call a meeting |
| C→S | `vote {targetId}` / `vote {skip:true}` | cast vote |
| S→C | `welcome`, `queue_update`, `lobby`, `game_start`, `task_progress`, `player_killed`, `meeting_called`, `vote_result`, `game_over`, `error` | — |

`game_over` includes per-player ELO deltas, and the room automatically returns to lobby for a rematch.

---

## Changing game tuning

All constants are at the top of `server/index.js`: `KILL_COOLDOWN_MS`, `MEETING_VOTE_MS`, `TASKS_PER_CREW`, `K_ELO`, `START_ELO`, `MIN_PLAYERS/MAX_PLAYERS`.
