import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';

/// Plays device sounds. A sound failure must never interrupt the simulation.
///
/// The Windows audio plugin crashes the whole app (an access violation inside the plugin) when a player is disposed
/// while its native callbacks are still running, or when calls to one player overlap. Explosions trigger exactly that:
/// a new one-shot, a loop starting and others stopping all at once. So players here are made once, reused and never
/// disposed while the app runs, and every call to a given player waits for the previous one to finish.
class SoundPlayer {
  static const _singleTake = {'short_circuit'};

  /// How many one-shot sounds can overlap. When all are busy the oldest is cut off and reused.
  static const _shotVoices = 8;

  final _random = Random();

  /// One reusable player per continuous sound, created the first time it is needed.
  final Map<String, AudioPlayer> _loopPlayers = {};

  /// The loops that should be playing now, and the ones whose player has actually been started.
  final Set<String> _wanted = {};
  final Set<String> _playing = {};
  final Map<String, (double, double)> _mix = {};

  final List<AudioPlayer> _shots = [];
  int _nextShot = 0;

  /// The tail of each player's queue of calls.
  final Map<AudioPlayer, Future<void>> _queues = {};

  /// Runs [action] on [player] after everything already queued for it. Errors are swallowed.
  Future<void> _on(AudioPlayer player, Future<void> Function() action) {
    final next = (_queues[player] ?? Future<void>.value()).then((_) async {
      try {
        await action();
      } catch (_) {}
    });
    _queues[player] = next;
    return next;
  }

  /// A player that never polls its position. By default the plugin asks the native side for the position on every
  /// frame for every playing player and keeps frames coming to do it; with the motor's speed layers all looping, that
  /// alone made the app lag. Nothing here listens to the position stream; [loopPosition] asks directly.
  static AudioPlayer _newPlayer() => AudioPlayer()..positionUpdater = null;

  AudioPlayer _shotPlayer() {
    if (_shots.length < _shotVoices) {
      final player = _newPlayer();
      _shots.add(player);
      // Keep the loaded file after it ends instead of releasing it, so the native side never tears itself down.
      _on(player, () => player.setReleaseMode(ReleaseMode.stop));
      return player;
    }
    final player = _shots[_nextShot];
    _nextShot = (_nextShot + 1) % _shotVoices;
    return player;
  }

  Future<void> play(String name, bool enabled) {
    if (!enabled) return Future<void>.value();
    final file = _singleTake.contains(name) ? name : '${name}_${_random.nextInt(3) + 1}';
    final player = _shotPlayer();
    return _on(player, () async {
      await player.stop();
      await player.play(AssetSource('sounds/$file.wav'));
    });
  }

  /// Silences every one-shot sound that is still playing.
  Future<void> stopShots() => Future.wait([for (final player in _shots) _on(player, player.stop)]);

  /// Makes exactly these continuous sounds play: starts the missing ones and stops the rest.
  Future<void> setLoops(Set<String> names) {
    final changed = {..._wanted.difference(names), ...names.difference(_wanted)};
    _wanted
      ..clear()
      ..addAll(names);
    return Future.wait([for (final name in changed) _syncLoop(name)]);
  }

  /// Loops whose file is already loaded in their player, so starting them is only a resume.
  final Set<String> _loaded = {};

  AudioPlayer _loopPlayer(String name) => _loopPlayers.putIfAbsent(name, () {
        final created = _newPlayer();
        _on(created, () => created.setReleaseMode(ReleaseMode.loop));
        return created;
      });

  /// Loads loop files ahead of time. Loading takes about a second per file, longer when several load at once, which
  /// would leave the start of a motor's spin-up silent.
  ///
  /// One file at a time: Windows Media Foundation fails ("byte stream type unsupported") when several players open
  /// files at once, which left some layers unloaded and a motor starting seconds late. A failed load is tried once
  /// more; a loop still not loaded falls back to loading when it is first played.
  Future<void> preload(Iterable<String> names) async {
    for (final name in names) {
      for (var attempt = 0; attempt < 2 && !_loaded.contains(name); attempt++) {
        await _on(_loopPlayer(name), () async {
          if (_loaded.contains(name)) return;
          final player = _loopPlayers[name]!;
          await player.setVolume(0);
          await player.setSource(AssetSource('sounds/$name.wav'));
          _loaded.add(name);
        });
      }
    }
  }

  /// Brings one loop's player in line with whatever is wanted by the time its turn in the queue comes, so a quick
  /// start-then-stop always ends stopped.
  Future<void> _syncLoop(String name) {
    final player = _loopPlayer(name);
    return _on(player, () async {
      final want = _wanted.contains(name);
      if (want && !_playing.contains(name)) {
        final (volume, rate) = _mix[name] ?? (1.0, 1.0);
        await player.setVolume(volume);
        // stop() keeps the file loaded, so a loop that has played or been preloaded only needs a resume.
        if (_loaded.contains(name)) {
          await player.resume();
        } else {
          await player.play(AssetSource('sounds/$name.wav'), volume: volume);
          _loaded.add(name);
        }
        if (rate != 1) await player.setPlaybackRate(rate);
        _applied[name] = (volume, rate);
        _playing.add(name);
        // The mix may have moved on while the file loaded.
        await _applyMix(name, player);
      } else if (!want && _playing.contains(name)) {
        _playing.remove(name);
        _mix.remove(name);
        _applied.remove(name);
        await player.stop();
      }
    });
  }

  /// What each playing loop's player was last actually set to.
  final Map<String, (double, double)> _applied = {};

  /// Sets a playing loop's player to the latest requested mix, sending only what changed. Reading the latest value
  /// when its turn comes means a backlog of requests collapses into one.
  Future<void> _applyMix(String name, AudioPlayer player) async {
    final want = _mix[name];
    final have = _applied[name];
    if (want == null || have == null || !_playing.contains(name)) return;
    if ((want.$1 - have.$1).abs() >= 0.005) await player.setVolume(want.$1);
    if ((want.$2 - have.$2).abs() >= 0.005) await player.setPlaybackRate(want.$2);
    _applied[name] = want;
  }

  /// Shapes a running loop, which is how a motor speeds up and slows down audibly.
  Future<void> mixLoop(String name, double volume, double rate) {
    final previous = _mix[name];
    if (previous != null && (previous.$1 - volume).abs() < 0.01 && (previous.$2 - rate).abs() < 0.01) return Future<void>.value();
    _mix[name] = (volume, rate);
    final player = _loopPlayers[name];
    if (player == null || !_wanted.contains(name)) return Future<void>.value();
    return _on(player, () => _applyMix(name, player));
  }

  Set<String> get activeLoops => _wanted.toSet();

  /// Playback position of a running loop, for checking that it really advances.
  Future<Duration?> loopPosition(String name) async {
    final player = _loopPlayers[name];
    if (player == null || !_playing.contains(name)) return null;
    Duration? position;
    await _on(player, () async {
      if (!_playing.contains(name)) return;
      position = await player.getCurrentPosition();
    });
    return position;
  }
}
