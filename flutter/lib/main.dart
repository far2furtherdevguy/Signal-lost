import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Set your server URL at build time:
//   flutter build apk --release --dart-define=SERVER_URL=ws://your-server.onrender.com
const String kServerUrl = String.fromEnvironment('SERVER_URL',
    defaultValue: 'ws://localhost:8080');

void main() => runApp(const SignalLostApp());

enum AppState { connecting, home, queue, lobby, game, meeting, gameOver }

class GameClient {
  WebSocketChannel? _channel;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get stream => _controller.stream;

  void connect() {
    _channel = WebSocketChannel.connect(Uri.parse(kServerUrl));
    _channel!.stream.listen(
      (data) => _controller.add(jsonDecode(data as String) as Map<String, dynamic>),
      onError: (_) => _controller.add({'type': 'disconnect'}),
      onDone: () => _controller.add({'type': 'disconnect'}),
    );
  }

  void send(Map<String, dynamic> msg) {
    final c = _channel;
    if (c != null) c.sink.add(jsonEncode(msg));
  }

  void dispose() {
    _channel?.sink.close();
    _controller.close();
  }
}

class PlayerInfo {
  final String id, name;
  int elo;
  bool alive;
  PlayerInfo(this.id, this.name, this.elo, this.alive);
  factory PlayerInfo.fromJson(Map<String, dynamic> j) =>
      PlayerInfo(j['id'] as String, j['name'] as String, (j['elo'] ?? 1000) as int, (j['alive'] ?? true) as bool);
}

class SignalLostApp extends StatefulWidget {
  const SignalLostApp({super.key});
  @override
  State<SignalLostApp> createState() => _SignalLostAppState();
}

class _SignalLostAppState extends State<SignalLostApp> {
  final client = GameClient();
  AppState state = AppState.connecting;

  String myId = '';
  String myName = '';
  int myElo = 1000;
  String? role;
  String roomCode = '';
  String hostId = '';
  List<PlayerInfo> players = [];
  int queueCount = 0;

  int tasksDone = 0, totalTasks = 1, myTasksDone = 0, myTasksRequired = 0;
  int killAvailableAt = 0;
  Timer? killTimer;
  int meetingEndsAt = 0;
  Timer? meetingTimer;
  int meetingLeft = 0;
  int votedCount = 0, voteTotal = 0;
  Map<String, String> lastVotes = {};
  String? ejectedName;
  bool? ejectedWasImpostor;

  String winner = '', gameOverReason = '';
  Map<String, int> eloDeltas = {};
  String statusMsg = '';

  @override
  void initState() {
    super.initState();
    client.connect();
    client.stream.listen(onMessage);
    loadName();
  }

  Future<void> loadName() async {
    final prefs = await SharedPreferences.getInstance();
    myName = prefs.getString('name') ?? '';
    setState(() {});
  }

  void onMessage(Map<String, dynamic> m) {
    final t = m['type'] as String?;
    switch (t) {
      case 'welcome':
        myId = m['id'] as String;
        myElo = m['elo'] as int;
        if (myName.isNotEmpty) client.send({'type': 'join', 'name': myName});
        setState(() => state = AppState.home);
        break;
      case 'queue_update':
        queueCount = m['count'] as int;
        setState(() {});
        break;
      case 'lobby':
        roomCode = m['code'] as String;
        hostId = m['host'] as String;
        players = (m['players'] as List).map((e) => PlayerInfo.fromJson(e as Map<String, dynamic>)).toList();
        state = AppState.lobby;
        resetGameVars();
        setState(() {});
        break;
      case 'game_start':
        role = m['role'] as String;
        myTasksRequired = m['tasksRequired'] as int? ?? 0;
        state = AppState.game;
        resetGameVars();
        setState(() {});
        break;
      case 'game_state':
        players = (m['players'] as List).map((e) => PlayerInfo.fromJson(e as Map<String, dynamic>)).toList();
        tasksDone = m['tasksDone'] as int? ?? 0;
        totalTasks = m['totalTasks'] as int? ?? 1;
        setState(() {});
        break;
      case 'task_progress':
        tasksDone = m['tasksDone'] as int;
        totalTasks = m['totalTasks'] as int;
        setState(() {});
        break;
      case 'player_killed':
        players = (m['players'] as List).map((e) => PlayerInfo.fromJson(e as Map<String, dynamic>)).toList();
        killAvailableAt = m['killAvailableAt'] as int? ?? 0;
        startKillTimer();
        statusMsg = '${m['name']} was found dead...';
        setState(() {});
        break;
      case 'meeting_called':
        state = AppState.meeting;
        meetingEndsAt = m['endsAt'] as int;
        players = (m['players'] as List).map((e) => PlayerInfo.fromJson(e as Map<String, dynamic>)).toList();
        votedCount = 0;
        lastVotes = {};
        ejectedName = null;
        startMeetingTimer();
        setState(() {});
        break;
      case 'vote_update':
        votedCount = m['voted'] as int;
        voteTotal = m['total'] as int;
        setState(() {});
        break;
      case 'vote_result':
        players = (m['players'] as List).map((e) => PlayerInfo.fromJson(e as Map<String, dynamic>)).toList();
        final ej = m['ejected'];
        if (ej != null) {
          ejectedName = ej['name'] as String?;
          ejectedWasImpostor = ej['wasImpostor'] as bool?;
        }
        lastVotes = Map<String, String>.from(m['votes'] as Map? ?? {});
        meetingTimer?.cancel();
        setState(() {});
        break;
      case 'resume_game':
        players = (m['players'] as List).map((e) => PlayerInfo.fromJson(e as Map<String, dynamic>)).toList();
        state = AppState.game;
        setState(() {});
        break;
      case 'game_over':
        winner = m['winner'] as String;
        gameOverReason = m['reason'] as String? ?? '';
        eloDeltas = Map<String, int>.from(m['eloDeltas'] as Map);
        players = (m['players'] as List).map((e) => PlayerInfo.fromJson(e as Map<String, dynamic>)).toList();
        meetingTimer?.cancel();
        killTimer?.cancel();
        myElo = players.firstWhere((p) => p.id == myId, orElse: () => PlayerInfo(myId, myName, myElo, true)).elo;
        state = AppState.gameOver;
        setState(() {});
        break;
      case 'left_room':
        state = AppState.home;
        setState(() {});
        break;
      case 'error':
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m['message'] as String)));
        break;
      case 'disconnect':
        setState(() {
          state = AppState.connecting;
          statusMsg = 'Disconnected. Reconnecting...';
        });
        Future.delayed(const Duration(seconds: 3), () => client.connect());
        break;
    }
  }

  void resetGameVars() {
    role = state == AppState.lobby ? null : role;
    tasksDone = 0;
    totalTasks = 1;
    myTasksDone = 0;
    killAvailableAt = 0;
    killTimer?.cancel();
    meetingTimer?.cancel();
    votedCount = 0;
    voteTotal = 0;
    lastVotes = {};
    ejectedName = null;
    statusMsg = '';
  }

  void startKillTimer() {
    killTimer?.cancel();
    killTimer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  void startMeetingTimer() {
    meetingTimer?.cancel();
    meetingLeft = ((meetingEndsAt - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
    meetingTimer = Timer.periodic(const Duration(seconds: 1), (tm) {
      final left = ((meetingEndsAt - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
      if (left <= 0) { tm.cancel(); }
      setState(() => meetingLeft = left < 0 ? 0 : left);
    });
  }

  int get killLeft => ((killAvailableAt - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();

  Future<void> saveName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('name', name);
  }

  @override
  void dispose() {
    killTimer?.cancel();
    meetingTimer?.cancel();
    client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Signal Lost',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00E5FF), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF0B0E17),
      ),
      home: Scaffold(body: SafeArea(child: buildBody())),
    );
  }

  Widget buildBody() {
    switch (state) {
      case AppState.connecting: return centerMsg('Connecting to station...', statusMsg);
      case AppState.home: return homeScreen();
      case AppState.queue: return centerMsg('Searching for crew...', '$queueCount/4 in queue');
      case AppState.lobby: return lobbyScreen();
      case AppState.game: return gameScreen();
      case AppState.meeting: return meetingScreen();
      case AppState.gameOver: return gameOverScreen();
    }
  }

  Widget centerMsg(String title, String sub) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.satellite_alt, size: 72, color: Color(0xFF00E5FF)),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(sub, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          Text('Server: $kServerUrl', style: const TextStyle(fontSize: 11, color: Colors.white38)),
          if (state == AppState.connecting) const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
          if (state == AppState.queue)
            Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton(
                onPressed: () { client.send({'type': 'cancel_match'}); setState(() => state = AppState.home); },
                child: const Text('Cancel'),
              ),
            ),
        ]),
      );

  // ---------------- HOME ----------------
  final nameController = TextEditingController();
  Widget homeScreen() {
    nameController.text = myName;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Spacer(),
        const Icon(Icons.satellite_alt, size: 80, color: Color(0xFF00E5FF)),
        const SizedBox(height: 8),
        Text('SIGNAL LOST', textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 4)),
        const SizedBox(height: 4),
        const Text('3 crew. 1 impostor. Trust no one.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
        const SizedBox(height: 32),
        TextField(
          controller: nameController,
          maxLength: 20,
          decoration: const InputDecoration(labelText: 'Callsign', border: OutlineInputBorder()),
          onChanged: (v) => myName = v,
        ),
        const SizedBox(height: 8),
        Card(
          color: const Color(0xFF141A2A),
          child: ListTile(
            leading: const Icon(Icons.military_tech, color: Colors.amber),
            title: Text('$myElo ELO', style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text('Rating'),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: const Icon(Icons.rocket_launch),
          label: const Text('FIND MATCH'),
          style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
          onPressed: () {
            if (myName.trim().isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a callsign first')));
              return;
            }
            saveName(myName.trim());
            client.send({'type': 'join', 'name': myName.trim()});
            client.send({'type': 'find_match'});
            setState(() { state = AppState.queue; queueCount = 1; });
          },
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('CREATE PRIVATE'),
              onPressed: () {
                if (myName.trim().isEmpty) return;
                saveName(myName.trim());
                client.send({'type': 'join', 'name': myName.trim()});
                client.send({'type': 'create_private'});
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.key),
              label: const Text('JOIN PRIVATE'),
              onPressed: () async {
                if (myName.trim().isEmpty) return;
                final code = await showDialog<String>(
                  context: context,
                  builder: (ctx) {
                    final c = TextEditingController();
                    return AlertDialog(
                      title: const Text('Enter room code'),
                      content: TextField(controller: c, maxLength: 6, textCapitalization: TextCapitalization.characters),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim().toUpperCase()), child: const Text('Join')),
                      ],
                    );
                  },
                );
                if (code != null && code.length == 6) {
                  saveName(myName.trim());
                  client.send({'type': 'join', 'name': myName.trim()});
                  client.send({'type': 'join_private', 'code': code});
                }
              },
            ),
          ),
        ]),
        const Spacer(),
      ]),
    );
  }

  // ---------------- LOBBY ----------------
  Widget lobbyScreen() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 16),
          Text('ROOM $roomCode', textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 3)),
          const SizedBox(height: 4),
          Text('${players.length}/4 players', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 24),
          Expanded(
            child: Card(
              color: const Color(0xFF141A2A),
              child: ListView.builder(
                itemCount: players.length,
                itemBuilder: (_, i) => ListTile(
                  leading: CircleAvatar(child: Text(players[i].name.isEmpty ? '?' : players[i].name[0].toUpperCase())),
                  title: Text(players[i].name + (players[i].id == hostId ? '  (HOST)' : '')),
                  subtitle: Text('${players[i].elo} ELO'),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (hostId == myId)
            FilledButton(
              style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
              onPressed: players.length >= 4 ? () => client.send({'type': 'start_game'}) : null,
              child: const Text('LAUNCH'),
            )
          else
            const Text('Waiting for host to launch...', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          TextButton(onPressed: () => client.send({'type': 'leave_room'}), child: const Text('Leave room')),
        ]),
      );

  // ---------------- GAME ----------------
  bool taskInProgress = false;
  Widget gameScreen() {
    final me = players.where((p) => p.id == myId).firstOrNull;
    final isImpostor = role == 'impostor';
    final aliveTargets = players.where((p) => p.alive && p.id != myId).toList();
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Chip(
            avatar: Icon(isImpostor ? Icons.visibility_off : Icons.engineering, size: 18),
            label: Text(isImpostor ? 'IMPOSTOR' : 'CREWMATE',
                style: TextStyle(color: isImpostor ? Colors.redAccent : Colors.tealAccent, fontWeight: FontWeight.bold)),
          ),
          const Spacer(),
          Chip(label: Text('Room $roomCode')),
        ]),
        const SizedBox(height: 12),
        if (!isImpostor) ...[
          Row(children: [
            Text('Ship tasks: $tasksDone/$totalTasks'),
            const SizedBox(width: 12),
            Expanded(child: LinearProgressIndicator(value: tasksDone / totalTasks)),
          ]),
          const SizedBox(height: 6),
        ],
        if (statusMsg.isNotEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(statusMsg, style: const TextStyle(color: Colors.orangeAccent))),
        const SizedBox(height: 8),
        Expanded(
          child: Card(
            color: const Color(0xFF141A2A),
            child: ListView.builder(
              itemCount: players.length,
              itemBuilder: (_, i) {
                final p = players[i];
                return ListTile(
                  leading: Icon(Icons.circle, size: 12, color: p.alive ? Colors.greenAccent : Colors.redAccent),
                  title: Text(p.name, style: TextStyle(decoration: p.alive ? null : TextDecoration.lineThrough)),
                  subtitle: Text(p.alive ? 'On board' : 'Dead'),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (me?.alive ?? false) ...[
          if (!isImpostor)
            FilledButton.icon(
              icon: taskInProgress ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.build),
              label: Text(taskInProgress ? 'Working...' : 'COMPLETE TASK (${myTasksDone.clamp(0, myTasksRequired)}/$myTasksRequired)'),
              style: FilledButton.styleFrom(backgroundColor: Colors.teal.shade700, padding: const EdgeInsets.all(14)),
              onPressed: taskInProgress || myTasksDone >= myTasksRequired ? null : () {
                setState(() => taskInProgress = true);
                Timer(const Duration(seconds: 3), () {
                  client.send({'type': 'task_complete'});
                  setState(() { taskInProgress = false; myTasksDone++; });
                });
              },
            ),
          if (isImpostor) ...[
            FilledButton.icon(
              icon: const Icon(Icons.flash_on),
              label: Text(killLeft > 0 ? 'KILL (ready in ${killLeft}s)' : 'KILL'),
              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700, padding: const EdgeInsets.all(14)),
              onPressed: killLeft > 0 ? null : () {
                showModalBottomSheet(
                  context: context,
                  builder: (ctx) => SafeArea(
                    child: ListView(
                      shrinkWrap: true,
                      children: aliveTargets.map((p) => ListTile(
                        title: Text(p.name),
                        onTap: () { Navigator.pop(ctx); client.send({'type': 'kill', 'targetId': p.id}); },
                      )).toList(),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.build_circle_outlined),
              label: const Text('FAKE TASK (blend in)'),
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You pretend to fix the antenna...'))),
            ),
          ],
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.campaign),
                label: const Text('REPORT BODY'),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.orangeAccent),
                onPressed: () => client.send({'type': 'report'}),
              ),
            ),
            if (!isImpostor) ...[
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.warning_amber),
                  label: const Text('EMERGENCY'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.yellowAccent),
                  onPressed: () => client.send({'type': 'emergency'}),
                ),
              ),
            ],
          ]),
        ] else
          const Text('You are dead. Watch the chaos unfold.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
      ]),
    );
  }

  // ---------------- MEETING ----------------
  Widget meetingScreen() {
    final alive = players.where((p) => p.alive).toList();
    final meAlive = players.any((p) => p.id == myId && p.alive);
    final iVoted = lastVotes.containsKey(myId);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(ejectedName == null ? 'EMERGENCY MEETING' : 'EJECTED: $ejectedName${ejectedWasImpostor == true ? ' (was the Impostor!)' : ''}',
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
        if (ejectedName == null) ...[
          Text('Vote ends in ${meetingLeft}s  •  $votedCount/$voteTotal voted', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 12),
          if (meAlive && !iVoted)
            Expanded(
              child: ListView(
                children: [
                  ...alive.map((p) => Card(
                        color: const Color(0xFF141A2A),
                        child: ListTile(
                          title: Text(p.name + (p.id == myId ? ' (you)' : '')),
                          trailing: FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
                            onPressed: () => client.send({'type': 'vote', 'targetId': p.id}),
                            child: const Text('VOTE'),
                          ),
                        ),
                      )),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => client.send({'type': 'vote', 'skip': true}),
                    child: const Text('SKIP VOTE'),
                  ),
                ],
              ),
            )
          else
            Expanded(child: Center(child: Text(iVoted ? 'Vote recorded. Waiting for crew...' : 'You are dead. Observe the vote.', style: const TextStyle(color: Colors.white70)))),
        ] else ...[
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: lastVotes.entries.map((e) {
                final voter = players.firstWhere((p) => p.id == e.key, orElse: () => PlayerInfo(e.key, '?', 0, true));
                final target = e.value == 'skip' ? null : players.firstWhere((p) => p.id == e.value, orElse: () => PlayerInfo(e.value, '?', 0, true));
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.how_to_vote, size: 18),
                  title: Text('${voter.name} voted ${e.value == 'skip' ? 'to skip' : 'for ${target?.name ?? '?'}'}'),
                );
              }).toList(),
            ),
          ),
        ],
      ]),
    );
  }

  // ---------------- GAME OVER ----------------
  Widget gameOverScreen() {
    final crewWon = winner == 'crewmate';
    final iWon = (role == 'impostor') == !crewWon;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Spacer(),
        Icon(crewWon ? Icons.verified_user : Icons.visibility_off, size: 80, color: crewWon ? Colors.tealAccent : Colors.redAccent),
        const SizedBox(height: 12),
        Text(crewWon ? 'CREW WINS' : 'IMPOSTOR WINS',
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        Text(gameOverReason, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54)),
        const SizedBox(height: 8),
        Text(iWon ? 'Victory! +${eloDeltas[myId] ?? 0} ELO' : 'Defeat. ${eloDeltas[myId] ?? 0} ELO',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: iWon ? Colors.greenAccent : Colors.redAccent)),
        const SizedBox(height: 24),
        Card(
          color: const Color(0xFF141A2A),
          child: Column(
            children: players.map((p) {
              final d = eloDeltas[p.id] ?? 0;
              return ListTile(
                dense: true,
                leading: Icon(Icons.circle, size: 10, color: p.alive ? Colors.greenAccent : Colors.redAccent),
                title: Text(p.name),
                subtitle: Text('${p.elo} ELO'),
                trailing: Text('${d >= 0 ? '+' : ''}$d', style: TextStyle(color: d >= 0 ? Colors.greenAccent : Colors.redAccent, fontWeight: FontWeight.bold)),
              );
            }).toList(),
          ),
        ),
        const Spacer(),
        FilledButton(
          style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
          onPressed: () => setState(() => state = AppState.home),
          child: const Text('BACK TO BASE'),
        ),
        const SizedBox(height: 8),
        const Text('Room returns to lobby in a few seconds (rematch with same crew).',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.white38)),
      ]),
    );
  }
}

extension FirstOrNullExt<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
