import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.spotbeats.app.channel.audio',
    androidNotificationChannelName: 'SpotBeats Audio Playback',
    androidNotificationOngoing: true,
  );

  runApp(const SpotBeatsApp());
}

// ============================================================================
// 1. DATA MODEL (WITH JSON & OFFLINE FILE PATH SUPPORT)
// ============================================================================
class MusicTrack {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String genre;
  final String coverUrl;
  final String audioUrl;
  final String? localAudioPath;
  final String? localCoverPath;

  const MusicTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.genre,
    required this.coverUrl,
    required this.audioUrl,
    this.localAudioPath,
    this.localCoverPath,
  });

  bool get hasLocalAudio =>
      localAudioPath != null && File(localAudioPath!).existsSync();

  bool get hasLocalCover =>
      localCoverPath != null && File(localCoverPath!).existsSync();

  MusicTrack copyWith({
    String? localAudioPath,
    String? localCoverPath,
  }) {
    return MusicTrack(
      id: id,
      title: title,
      artist: artist,
      album: album,
      genre: genre,
      coverUrl: coverUrl,
      audioUrl: audioUrl,
      localAudioPath: localAudioPath ?? this.localAudioPath,
      localCoverPath: localCoverPath ?? this.localCoverPath,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'genre': genre,
        'coverUrl': coverUrl,
        'audioUrl': audioUrl,
        'localAudioPath': localAudioPath,
        'localCoverPath': localCoverPath,
      };

  factory MusicTrack.fromJson(Map<String, dynamic> json) => MusicTrack(
        id: json['id'],
        title: json['title'],
        artist: json['artist'],
        album: json['album'],
        genre: json['genre'],
        coverUrl: json['coverUrl'],
        audioUrl: json['audioUrl'],
        localAudioPath: json['localAudioPath'],
        localCoverPath: json['localCoverPath'],
      );
}

// ============================================================================
// 2. OFFLINE DOWNLOAD & LOCAL STORAGE MANAGER
// ============================================================================
class OfflineStorageManager {
  static const String _kDownloadedKey = 'spotbeats_downloaded_tracks';
  static const String _kLikedKey = 'spotbeats_liked_tracks';

  Future<Map<String, MusicTrack>> loadDownloadedTracks() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList(_kDownloadedKey) ?? [];
    final Map<String, MusicTrack> map = {};

    for (final item in rawList) {
      final track = MusicTrack.fromJson(jsonDecode(item));
      if (track.hasLocalAudio) {
        map[track.id] = track;
      }
    }
    return map;
  }

  Future<Map<String, MusicTrack>> loadLikedTracks() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList(_kLikedKey) ?? [];
    final Map<String, MusicTrack> map = {};

    for (final item in rawList) {
      final track = MusicTrack.fromJson(jsonDecode(item));
      map[track.id] = track;
    }
    return map;
  }

  Future<void> saveDownloadedTracks(Map<String, MusicTrack> tracks) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded =
        tracks.values.map((t) => jsonEncode(t.toJson())).toList();
    await prefs.setStringList(_kDownloadedKey, encoded);
  }

  Future<void> saveLikedTracks(Map<String, MusicTrack> tracks) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded =
        tracks.values.map((t) => jsonEncode(t.toJson())).toList();
    await prefs.setStringList(_kLikedKey, encoded);
  }

  Future<MusicTrack?> downloadTrack(MusicTrack track) async {
    try {
      final baseDir = await getApplicationDocumentsDirectory();
      final tracksDir = Directory('${baseDir.path}/tracks');
      final coversDir = Directory('${baseDir.path}/covers');

      if (!await tracksDir.exists()) await tracksDir.create(recursive: true);
      if (!await coversDir.exists()) await coversDir.create(recursive: true);

      final audioResponse = await http.get(Uri.parse(track.audioUrl));
      if (audioResponse.statusCode != 200) return null;

      final audioFile = File('${tracksDir.path}/${track.id}.m4a');
      await audioFile.writeAsBytes(audioResponse.bodyBytes);

      String? savedCoverPath;
      try {
        final coverResponse = await http.get(Uri.parse(track.coverUrl));
        if (coverResponse.statusCode == 200) {
          final coverFile = File('${coversDir.path}/${track.id}.jpg');
          await coverFile.writeAsBytes(coverResponse.bodyBytes);
          savedCoverPath = coverFile.path;
        }
      } catch (_) {}

      return track.copyWith(
        localAudioPath: audioFile.path,
        localCoverPath: savedCoverPath,
      );
    } catch (e) {
      debugPrint('Download error: $e');
      return null;
    }
  }

  Future<void> deleteDownloadedFiles(MusicTrack track) async {
    try {
      if (track.localAudioPath != null) {
        final audioFile = File(track.localAudioPath!);
        if (await audioFile.exists()) await audioFile.delete();
      }
      if (track.localCoverPath != null) {
        final coverFile = File(track.localCoverPath!);
        if (await coverFile.exists()) await coverFile.delete();
      }
    } catch (e) {
      debugPrint('Error deleting offline files: $e');
    }
  }
}

// ============================================================================
// 3. LIVE GLOBAL & SPOTIFY MUSIC SERVICE
// ============================================================================
class MusicApiService {
  static const String spotifyClientId = '';
  static const String spotifyClientSecret = '';

  String? _spotifyToken;
  DateTime? _tokenExpiry;

  Future<List<MusicTrack>> searchSongs(String query, {int limit = 35}) async {
    if (query.trim().isEmpty) return [];

    if (spotifyClientId.isNotEmpty && spotifyClientSecret.isNotEmpty) {
      final spotifyResults = await _searchSpotify(query, limit: limit);
      if (spotifyResults.isNotEmpty) return spotifyResults;
    }
    return _searchGlobalCatalog(query, limit: limit);
  }

  Future<String?> _getSpotifyToken() async {
    if (_spotifyToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _spotifyToken;
    }
    final creds =
        base64Encode(utf8.encode('$spotifyClientId:$spotifyClientSecret'));
    final res = await http.post(
      Uri.parse('https://accounts.spotify.com/api/token'),
      headers: {
        'Authorization': 'Basic $creds',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {'grant_type': 'client_credentials'},
    );
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      _spotifyToken = data['access_token'];
      _tokenExpiry =
          DateTime.now().add(Duration(seconds: data['expires_in'] - 60));
      return _spotifyToken;
    }
    return null;
  }

  Future<List<MusicTrack>> _searchSpotify(String query,
      {int limit = 25}) async {
    try {
      final token = await _getSpotifyToken();
      if (token == null) return [];
      final uri = Uri.https('api.spotify.com', '/v1/search', {
        'q': query,
        'type': 'track',
        'limit': '$limit',
      });
      final res =
          await http.get(uri, headers: {'Authorization': 'Bearer $token'});
      if (res.statusCode == 200) {
        final items = jsonDecode(res.body)['tracks']['items'] as List? ?? [];
        final List<MusicTrack> list = [];
        for (final item in items) {
          final preview = item['preview_url'];
          if (preview == null) continue;
          final images = item['album']['images'] as List;
          final cover = images.isNotEmpty ? images.first['url'] : '';
          final artists = (item['artists'] as List)
              .map((a) => a['name'].toString())
              .join(', ');
          list.add(MusicTrack(
            id: item['id'],
            title: item['name'] ?? 'Unknown',
            artist: artists,
            album: item['album']['name'] ?? 'Single',
            genre: 'Spotify',
            coverUrl: cover,
            audioUrl: preview,
          ));
        }
        return list;
      }
    } catch (_) {}
    return [];
  }

  Future<List<MusicTrack>> _searchGlobalCatalog(String query,
      {int limit = 35}) async {
    try {
      final uri = Uri.https('itunes.apple.com', '/search', {
        'term': query,
        'media': 'music',
        'entity': 'song',
        'limit': '$limit',
      });
      final res = await http.get(uri);
      if (res.statusCode == 200) {
        final results = jsonDecode(res.body)['results'] as List? ?? [];
        return results
            .where((item) => item['previewUrl'] != null)
            .map<MusicTrack>((item) {
          final art = (item['artworkUrl100']?.toString() ?? '')
              .replaceAll('100x100bb', '600x600bb');
          return MusicTrack(
            id: item['trackId'].toString(),
            title: item['trackName'] ?? 'Unknown Track',
            artist: item['artistName'] ?? 'Unknown Artist',
            album: item['collectionName'] ?? 'Single',
            genre: item['primaryGenreName'] ?? 'Pop',
            coverUrl: art,
            audioUrl: item['previewUrl'],
          );
        }).toList();
      }
    } catch (_) {}
    return [];
  }
}

// ============================================================================
// 4. ROOT APP WIDGET
// ============================================================================
class SpotBeatsApp extends StatelessWidget {
  const SpotBeatsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SpotBeats',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF09090B),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF1DB954),
          secondary: Color(0xFFF59E0B),
          surface: Color(0xFF18181B),
        ),
        useMaterial3: true,
      ),
      home: const MainShell(),
    );
  }
}

// ============================================================================
// 5. MAIN SHELL (NAVIGATION + OFFLINE/ONLINE AUDIO ENGINE)
// ============================================================================
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final MusicApiService _api = MusicApiService();
  final OfflineStorageManager _storage = OfflineStorageManager();
  final TextEditingController _searchController = TextEditingController();
  late final AudioPlayer _player;

  int _selectedTab = 0;
  String _librarySubTab = 'Downloaded';
  Timer? _debounce;

  bool _isLoadingHome = true;
  bool _isLoadingSearch = false;
  List<MusicTrack> _trendingTracks = [];
  List<MusicTrack> _hollywoodOstTracks = [];
  List<MusicTrack> _searchResults = [];

  Map<String, MusicTrack> _downloadedTracks = {};
  Map<String, MusicTrack> _likedTracks = {};
  final Set<String> _downloadingTrackIds = {};

  List<MusicTrack> _activeQueue = [];
  int _currentIndex = 0;
  bool _isShuffle = false;
  LoopMode _loopMode = LoopMode.off;

  final Map<String, String> _genreChips = {
    'Top Hits': 'Billboard Hot 100 Pop Hits',
    'Hollywood Pop': 'The Weeknd Taylor Swift Dua Lipa Bruno Mars',
    'Hip-Hop': 'Drake Kendrick Lamar Travis Scott Eminem',
    'Movie OST': 'Hans Zimmer Ludwig Goransson Marvel Soundtrack',
    'Rock & Alt': 'Coldplay Linkin Park Imagine Dragons',
    'EDM': 'Calvin Harris Avicii David Guetta',
    'R&B': 'SZA Rihanna Post Malone',
    'Global Viral': 'Global Top 50 Viral Songs',
  };
  String _selectedGenre = 'Top Hits';

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();

    _player.currentIndexStream.listen((idx) {
      if (idx != null && mounted && idx < _activeQueue.length) {
        setState(() => _currentIndex = idx);
      }
    });

    _initApp();
  }

  Future<void> _initApp() async {
    final downloaded = await _storage.loadDownloadedTracks();
    final liked = await _storage.loadLikedTracks();

    if (mounted) {
      setState(() {
        _downloadedTracks = downloaded;
        _likedTracks = liked;
      });
    }

    await _loadInitialCatalogs();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadInitialCatalogs() async {
    setState(() => _isLoadingHome = true);
    final results = await Future.wait([
      _api.searchSongs('The Weeknd Taylor Swift Bruno Mars Billie Eilish',
          limit: 20),
      _api.searchSongs('Hans Zimmer Oppenheimer Inception Interstellar Top Gun',
          limit: 20),
    ]);

    if (mounted) {
      setState(() {
        _trendingTracks = results[0];
        _hollywoodOstTracks = results[1];
        _searchResults = results[0];
        _isLoadingHome = false;
      });

      if (_trendingTracks.isNotEmpty) {
        await _setQueue(_trendingTracks, startIndex: 0, autoPlay: false);
      } else if (_downloadedTracks.isNotEmpty) {
        await _setQueue(
          _downloadedTracks.values.toList(),
          startIndex: 0,
          autoPlay: false,
        );
      }
    }
  }

  Future<void> _loadGenre(String genreKey) async {
    setState(() {
      _selectedGenre = genreKey;
      _isLoadingSearch = true;
    });
    final query = _genreChips[genreKey] ?? genreKey;
    final tracks = await _api.searchSongs(query, limit: 35);
    if (mounted) {
      setState(() {
        _searchResults = tracks;
        _isLoadingSearch = false;
      });
    }
  }

  void _onSearchChanged(String val) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      if (val.trim().isEmpty) {
        _loadGenre(_selectedGenre);
        return;
      }
      setState(() => _isLoadingSearch = true);
      final res = await _api.searchSongs(val, limit: 40);
      if (mounted) {
        setState(() {
          _searchResults = res;
          _isLoadingSearch = false;
        });
      }
    });
  }

  Future<void> _setQueue(
    List<MusicTrack> tracks, {
    required int startIndex,
    required bool autoPlay,
  }) async {
    if (tracks.isEmpty) return;

    _activeQueue = tracks.map((t) => _downloadedTracks[t.id] ?? t).toList();
    setState(() => _currentIndex = startIndex);

    final source = ConcatenatingAudioSource(
      children: _activeQueue.map((t) {
        final artUri = t.hasLocalCover
            ? Uri.file(t.localCoverPath!)
            : Uri.parse(t.coverUrl);

        final mediaItem = MediaItem(
          id: t.id,
          album: t.album,
          title: t.title,
          artist: t.artist,
          artUri: artUri,
        );

        if (t.hasLocalAudio) {
          return AudioSource.file(t.localAudioPath!, tag: mediaItem);
        } else {
          return AudioSource.uri(Uri.parse(t.audioUrl), tag: mediaItem);
        }
      }).toList(),
    );

    try {
      await _player.setAudioSource(source, initialIndex: startIndex);
      if (autoPlay) _player.play();
    } catch (e) {
      debugPrint('Audio load error: $e');
    }
  }

  Future<void> _handleDownloadToggle(MusicTrack track) async {
    if (_downloadingTrackIds.contains(track.id)) return;

    if (_downloadedTracks.containsKey(track.id)) {
      final cached = _downloadedTracks.remove(track.id)!;
      await _storage.deleteDownloadedFiles(cached);
      await _storage.saveDownloadedTracks(_downloadedTracks);
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Removed "${track.title}" from offline downloads'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    setState(() => _downloadingTrackIds.add(track.id));

    final downloadedTrack = await _storage.downloadTrack(track);

    if (mounted) {
      setState(() {
        _downloadingTrackIds.remove(track.id);
        if (downloadedTrack != null) {
          _downloadedTracks[track.id] = downloadedTrack;
        }
      });

      if (downloadedTrack != null) {
        await _storage.saveDownloadedTracks(_downloadedTracks);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: const Color(0xFF1DB954),
              content: Text(
                'Downloaded "${track.title}" for offline playback!',
                style: const TextStyle(
                    color: Colors.black, fontWeight: FontWeight.bold),
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  Future<void> _toggleLike(MusicTrack track) async {
    setState(() {
      if (_likedTracks.containsKey(track.id)) {
        _likedTracks.remove(track.id);
      } else {
        _likedTracks[track.id] = track;
      }
    });
    await _storage.saveLikedTracks(_likedTracks);
  }

  Future<void> _toggleShuffle() async {
    _isShuffle = !_isShuffle;
    await _player.setShuffleModeEnabled(_isShuffle);
    setState(() {});
  }

  Future<void> _toggleRepeat() async {
    if (_loopMode == LoopMode.off) {
      _loopMode = LoopMode.all;
    } else if (_loopMode == LoopMode.all) {
      _loopMode = LoopMode.one;
    } else {
      _loopMode = LoopMode.off;
    }
    await _player.setLoopMode(_loopMode);
    setState(() {});
  }

  String _formatDuration(Duration? d) {
    if (d == null) return '0:00';
    final min = d.inMinutes;
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$min:$sec';
  }

  Widget _buildCoverArt(MusicTrack track,
      {double size = 52, double radius = 8}) {
    final cached = _downloadedTracks[track.id] ?? track;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: cached.hasLocalCover
          ? Image.file(
              File(cached.localCoverPath!),
              width: size,
              height: size,
              fit: BoxFit.cover,
            )
          : Image.network(
              cached.coverUrl,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: size,
                height: size,
                color: Colors.white10,
                child: Icon(Icons.music_note, size: size * 0.45),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MusicTrack? currentTrack =
        (_activeQueue.isNotEmpty && _currentIndex < _activeQueue.length)
            ? _activeQueue[_currentIndex]
            : null;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF09090B),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(
