import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'package:geolocator/geolocator.dart';

const String googleApiKey = 'AIzaSyCdjW-kD7rfoZ7xieNJPTZGNQPDAbc-Td4';

void main() {
  runApp(const YakitRadarApp());
}

class YakitRadarApp extends StatelessWidget {
  const YakitRadarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yakıt Radar',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        fontFamily: null,
      ),
      home: const FuelStationsPage(),
    );
  }
}

class ShellPrice {
  final double gasoline95;
  final double diesel;

  ShellPrice({required this.gasoline95, required this.diesel});
}

class StationItem {
  final String placeId;
  final String name;
  final double lat;
  final double lng;

  final bool isOpen;
  final bool isShell;

  final double? gasoline95;
  final double? distanceMeters;

  StationItem({
    required this.placeId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.isOpen,
    required this.isShell,
    this.gasoline95,
    this.distanceMeters,
  });
}

enum RecommendMode { nearest, smartest }

class FuelStationsPage extends StatefulWidget {
  const FuelStationsPage({super.key});

  @override
  State<FuelStationsPage> createState() => _FuelStationsPageState();
}

class _FuelStationsPageState extends State<FuelStationsPage> {
  GoogleMapController? _mapController;

  BitmapDescriptor? _customMarker;
  final Set<Marker> _markers = {};
  final List<StationItem> _stations = [];

  Map<String, ShellPrice> _shellPrices = {};

  Position? _userPos;
  bool _locationGranted = false;

  bool _loading = true;
  String? _error;

  LatLng _center = const LatLng(41.0082, 28.9784); // fallback İstanbul

  // UI State
  RecommendMode _mode = RecommendMode.nearest;
  StationItem? _nearestStation;
  List<StationItem> _nearestAlternatives = [];
  final List<_ForecastItem> _forecast = const [
    _ForecastItem(
      title: 'Bu gece 00:00',
      message: 'Benzin -0,80 TL düşüyor • Depoyu doldurmak için son saatler.',
    ),
  ];

  // “Rota” (şimdilik demo)
  String _toLabel = 'İş Adresi';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrap();
    });
  }

  Future<void> _bootstrap() async {
    try {
      setState(() {
        _loading = true;
        _error = null;
      });

      await _loadMarker();
      await _loadShellPrices();
      await _tryGetLocation();

      await _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _center, zoom: 13.6),
        ),
      );

      await _loadStations(_center);
      _computeNearest();

      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _tryGetLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _locationGranted = false;
        _userPos = null;
        _center = const LatLng(41.0082, 28.9784);
        return;
      }

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        _locationGranted = false;
        _userPos = null;
        _center = const LatLng(41.0082, 28.9784);
        return;
      }

      _locationGranted = true;
      _userPos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      );

      _center = LatLng(_userPos!.latitude, _userPos!.longitude);
    } catch (_) {
      _locationGranted = false;
      _userPos = null;
      _center = const LatLng(41.0082, 28.9784);
    }
  }

  Future<void> _loadMarker() async {
    final data = await rootBundle.load('assets/icons/BenzinChargeIcon.png');
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
      targetWidth: 70,
    );
    final frame = await codec.getNextFrame();
    final bytes = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    _customMarker = BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  Future<void> _loadShellPrices() async {
    final jsonStr = await rootBundle.loadString('assets/data/shell_istanbul.json');
    final data = json.decode(jsonStr);
    final districts = data['districts'] as Map<String, dynamic>;

    _shellPrices = districts.map((k, v) {
      return MapEntry(
        k,
        ShellPrice(
          gasoline95: (v['gasoline_95'] as num).toDouble(),
          diesel: (v['diesel'] as num).toDouble(),
        ),
      );
    });
  }

  Future<void> _loadStations(LatLng center) async {
    _markers.clear();
    _stations.clear();

    const int radius = 2500;
    const int maxMarkers = 15;

    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/nearbysearch/json'
          '?location=${center.latitude},${center.longitude}'
          '&radius=$radius'
          '&type=gas_station'
          '&key=$googleApiKey',
    );

    final res = await http.get(url).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('Places API hata: ${res.statusCode}');
    }

    final data = json.decode(res.body) as Map<String, dynamic>;
    final results = (data['results'] as List<dynamic>? ?? []);

    for (final place in results.take(maxMarkers)) {
      final loc = place['geometry']['location'];
      final lat = (loc['lat'] as num).toDouble();
      final lng = (loc['lng'] as num).toDouble();

      final name = (place['name'] as String?) ?? 'Benzin İstasyonu';
      final placeId = (place['place_id'] as String?) ?? '$lat,$lng';

      final opening = place['opening_hours'];
      final bool isOpen = opening != null ? opening['open_now'] == true : false;

      final upper = name.toUpperCase();
      final bool isShell = upper.contains('SHELL');

      double? price;
      if (isShell) {
        price = null; // şimdilik boş (ilçe eşlemesi ekleyince dolduracağız)
      }

      double? dist;
      if (_userPos != null) {
        dist = Geolocator.distanceBetween(
          _userPos!.latitude,
          _userPos!.longitude,
          lat,
          lng,
        );
      }

      final item = StationItem(
        placeId: placeId,
        name: name,
        lat: lat,
        lng: lng,
        isOpen: isOpen,
        isShell: isShell,
        gasoline95: price,
        distanceMeters: dist,
      );

      _stations.add(item);

      _markers.add(
        Marker(
          markerId: MarkerId(placeId),
          position: LatLng(lat, lng),
          icon: _customMarker ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          onTap: () => _openStationSheet(item),
        ),
      );
    }

    setState(() {});
  }

  void _computeNearest() {
    if (_stations.isEmpty) {
      _nearestStation = null;
      _nearestAlternatives = [];
      return;
    }

    final sorted = List<StationItem>.of(_stations);

    if (_mode == RecommendMode.nearest) {
      sorted.sort(
            (a, b) => (a.distanceMeters ?? 1e18).compareTo(b.distanceMeters ?? 1e18),
      );
    } else {
      sorted.sort((a, b) => _smartScore(b).compareTo(_smartScore(a)));
    }

    _nearestStation = sorted.first;
    _nearestAlternatives = sorted.skip(1).take(8).toList();
  }

  double _smartScore(StationItem s) {
    final d = (s.distanceMeters ?? 999999);
    final openBonus = s.isOpen ? 2500 : 0;
    final distScore = max(0.0, 4500 - d);
    return openBonus + distScore;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: _center, zoom: 13.6),
            onMapCreated: (c) => _mapController = c,
            markers: _markers,
            myLocationEnabled: _locationGranted,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: false,
            mapToolbarEnabled: false,
          ),

          // Top route bar (mock hissi)
          Positioned(
            left: 14,
            right: 14,
            top: MediaQuery.of(context).padding.top + 10,
            child: _TopRouteBar(
              toLabel: _toLabel,
              onTapPick: _openRoutePickerDemo,
              onTapLocate: _recenterToUser,
            ),
          ),

          // Bottom premium panel
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _BottomHomePanel(
              loading: _loading,
              error: _error,
              onRetry: _bootstrap,
              nearest: _nearestStation,
              alternatives: _nearestAlternatives,
              formatDistance: _formatDistance,
              onTapStation: _openStationSheet,
              forecast: _forecast,
              primaryColor: cs.primary,
              mode: _mode,
              onModeChange: (m) {
                setState(() => _mode = m);
                _computeNearest();
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _recenterToUser() async {
    await _tryGetLocation();
    await _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: _center, zoom: 13.9),
      ),
    );
    await _loadStations(_center);
    _computeNearest();
    setState(() {});
  }

  Future<void> _openRoutePickerDemo() async {
    // Şimdilik demo: seçilebilir 3 hedef.
    // Sonraki adım: Places Autocomplete ile "Google Maps gibi" arama.
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _GlassSheet(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _SheetHandle(),
              const Text('Hedef seç (demo)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              _SheetOption(title: 'İş Adresi', subtitle: 'Kaydedilmiş', onTap: () => Navigator.pop(ctx, 'İş Adresi')),
              _SheetOption(title: 'Ev', subtitle: 'Kaydedilmiş', onTap: () => Navigator.pop(ctx, 'Ev')),
              _SheetOption(title: 'Yeni hedef…', subtitle: 'Sonra autocomplete yapacağız', onTap: () => Navigator.pop(ctx, 'Yeni hedef')),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (choice == null) return;
    setState(() => _toLabel = choice);
  }

  void _openStationSheet(StationItem s) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        final dist = _formatDistance(s.distanceMeters);
        return _GlassSheet(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: 16 + MediaQuery.of(context).padding.bottom,
              top: 6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _SheetHandle(),
                Row(
                  children: [
                    _BrandBubble(name: s.name),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (dist.isNotEmpty) _Pill(text: dist),
                              _Pill(
                                text: s.isOpen ? 'Açık' : 'Kapalı',
                                bg: (s.isOpen ? const Color(0xFF16A34A) : const Color(0xFFDC2626))
                                    .withOpacity(0.12),
                                textColor: s.isOpen ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        ),
                        onPressed: () => _openDirections(s.lat, s.lng),
                        icon: const Icon(Icons.navigation_rounded),
                        label: const Text('Yol Tarifi Al', style: TextStyle(fontWeight: FontWeight.w900)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    )
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDistance(double? meters) {
    if (meters == null) return '';
    if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  Future<void> _openDirections(double lat, double lng) async {
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

// -------------------- UI WIDGETS (Mock’a benzer modern görünüm) --------------------

class _TopRouteBar extends StatelessWidget {
  final String toLabel;
  final VoidCallback onTapPick;
  final VoidCallback onTapLocate;

  const _TopRouteBar({
    required this.toLabel,
    required this.onTapPick,
    required this.onTapLocate,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 0,
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: Colors.white.withOpacity(0.92),
          border: Border.all(color: Colors.black.withOpacity(0.06)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 20,
              offset: const Offset(0, 12),
            )
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.my_location_rounded, size: 18),
            const SizedBox(width: 8),
            const Text('Konumum', style: TextStyle(fontWeight: FontWeight.w900)),
            const SizedBox(width: 10),
            const Icon(Icons.arrow_forward_rounded, size: 18, color: Colors.black54),
            const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onTapPick,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    toLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onTapLocate,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: Colors.black.withOpacity(0.05),
                ),
                child: const Icon(Icons.near_me_rounded, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomHomePanel extends StatelessWidget {
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  final StationItem? nearest;
  final List<StationItem> alternatives;

  final String Function(double? meters) formatDistance;
  final void Function(StationItem s) onTapStation;

  final List<_ForecastItem> forecast;
  final Color primaryColor;

  final RecommendMode mode;
  final void Function(RecommendMode m) onModeChange;

  const _BottomHomePanel({
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.nearest,
    required this.alternatives,
    required this.formatDistance,
    required this.onTapStation,
    required this.forecast,
    required this.primaryColor,
    required this.mode,
    required this.onModeChange,
  });

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(34),
          gradient: LinearGradient(
            colors: [
              Colors.white.withOpacity(0.94),
              Colors.white.withOpacity(0.82),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: Colors.black.withOpacity(0.06)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.18),
              blurRadius: 36,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetHandle(),

            if (loading) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.6)),
                    SizedBox(width: 10),
                    Text('Yakındaki istasyonlar yükleniyor...'),
                  ],
                ),
              ),
            ] else if (error != null) ...[
              _ErrorBanner(text: error!, onRetry: onRetry),
            ] else ...[
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'En Yakın İstasyon',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(height: 10),

              if (nearest != null)
                _NearestHeroCard(
                  station: nearest!,
                  distanceText: formatDistance(nearest!.distanceMeters),
                  primaryColor: primaryColor,
                  onTap: () => onTapStation(nearest!),
                ),

              const SizedBox(height: 12),

              _ModeToggle(
                primaryColor: primaryColor,
                mode: mode,
                onChange: onModeChange,
              ),

              const SizedBox(height: 14),

              _AlternativesRow(
                title: 'Yakındaki Diğer Seçenekler',
                items: alternatives,
                formatDistance: formatDistance,
                onTap: onTapStation,
              ),

              const SizedBox(height: 14),

              _ForecastBand(items: forecast),
            ],

            SizedBox(height: (bottomInset > 0 ? bottomInset - 4 : 0)),
          ],
        ),
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final Color primaryColor;
  final RecommendMode mode;
  final void Function(RecommendMode m) onChange;

  const _ModeToggle({
    required this.primaryColor,
    required this.mode,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.05),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black.withOpacity(0.06)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _TogglePill(
              selected: mode == RecommendMode.nearest,
              label: 'En Yakın',
              primaryColor: primaryColor,
              onTap: () => onChange(RecommendMode.nearest),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _TogglePill(
              selected: mode == RecommendMode.smartest,
              label: 'En Mantıklı',
              primaryColor: primaryColor,
              onTap: () => onChange(RecommendMode.smartest),
            ),
          ),
        ],
      ),
    );
  }
}

class _TogglePill extends StatelessWidget {
  final bool selected;
  final String label;
  final Color primaryColor;
  final VoidCallback onTap;

  const _TogglePill({
    required this.selected,
    required this.label,
    required this.primaryColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: selected ? primaryColor.withOpacity(0.22) : Colors.transparent,
          border: Border.all(
            color: selected ? primaryColor.withOpacity(0.35) : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (selected) ...[
              Icon(Icons.check_circle_rounded, color: primaryColor, size: 18),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: selected ? Colors.black87 : Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NearestHeroCard extends StatelessWidget {
  final StationItem station;
  final String distanceText;
  final Color primaryColor;
  final VoidCallback onTap;

  const _NearestHeroCard({
    required this.station,
    required this.distanceText,
    required this.primaryColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final openText = station.isOpen ? 'Açık' : 'Kapalı';
    final openColor = station.isOpen ? const Color(0xFF16A34A) : const Color(0xFFDC2626);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(26),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          color: Colors.white.withOpacity(0.86),
          border: Border.all(color: Colors.black.withOpacity(0.06)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.07),
              blurRadius: 18,
              offset: const Offset(0, 10),
            )
          ],
        ),
        child: Row(
          children: [
            _BrandBubble(name: station.name),
            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    station.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _Pill(text: distanceText.isEmpty ? '—' : distanceText),
                      _Pill(text: openText, bg: openColor.withOpacity(0.10), textColor: openColor),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(width: 10),

            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: primaryColor,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.arrow_forward_rounded, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlternativesRow extends StatelessWidget {
  final String title;
  final List<StationItem> items;
  final String Function(double? meters) formatDistance;
  final void Function(StationItem s) onTap;

  const _AlternativesRow({
    required this.title,
    required this.items,
    required this.formatDistance,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
        const SizedBox(height: 10),
        SizedBox(
          height: 64,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              final s = items[i];
              final dist = formatDistance(s.distanceMeters);
              return InkWell(
                onTap: () => onTap(s),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.86),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.black.withOpacity(0.06)),
                  ),
                  child: Row(
                    children: [
                      _BrandMiniBubble(name: s.name),
                      const SizedBox(width: 10),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 120,
                            child: Text(
                              _shortBrandName(s.name),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w900),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(dist.isEmpty ? '—' : dist,
                              style: const TextStyle(color: Colors.black54, fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _shortBrandName(String name) {
    final up = name.toUpperCase();
    if (up.contains('SHELL')) return 'Shell';
    if (up.contains('OPET')) return 'Opet';
    if (up.contains('PETROL OFİS') || up.contains('PETROL OFISI')) return 'Petrol Ofisi';
    if (up.contains('BP')) return 'BP';
    if (up.contains('TOTAL')) return 'Total';
    return name;
  }
}

class _ForecastBand extends StatelessWidget {
  final List<_ForecastItem> items;
  const _ForecastBand({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final it = items.first;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9).withOpacity(0.85),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(0.06)),
      ),
      child: Row(
        children: [
          const Icon(Icons.trending_down_rounded, color: Color(0xFFDC2626)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(it.title, style: const TextStyle(fontWeight: FontWeight.w900)),
                const SizedBox(height: 2),
                Text(it.message, style: const TextStyle(color: Colors.black87)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color? bg;
  final Color? textColor;

  const _Pill({required this.text, this.bg, this.textColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg ?? Colors.black.withOpacity(0.05),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black.withOpacity(0.06)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: textColor ?? Colors.black87,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _BrandBubble extends StatelessWidget {
  final String name;
  const _BrandBubble({required this.name});

  @override
  Widget build(BuildContext context) {
    final b = _brand(name);
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: b.bg,
        border: Border.all(color: Colors.black.withOpacity(0.06)),
      ),
      child: Center(
        child: Text(
          b.label,
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: b.fg,
          ),
        ),
      ),
    );
  }

  _BrandStyle _brand(String n) {
    final up = n.toUpperCase();
    if (up.contains('SHELL')) return const _BrandStyle('Shell', Color(0xFFFFF3CD), Color(0xFFB45309));
    if (up.contains('OPET')) return const _BrandStyle('Opet', Color(0xFFDDEBFF), Color(0xFF1D4ED8));
    if (up.contains('PETROL OFİS') || up.contains('PETROL OFISI')) {
      return const _BrandStyle('PO', Color(0xFFFFE4E6), Color(0xFFBE123C));
    }
    if (up.contains('BP')) return const _BrandStyle('BP', Color(0xFFD1FAE5), Color(0xFF047857));
    if (up.contains('TOTAL')) return const _BrandStyle('Total', Color(0xFFFEE2E2), Color(0xFFB91C1C));
    return const _BrandStyle('⛽', Color(0xFFF3F4F6), Color(0xFF111827));
  }
}

class _BrandMiniBubble extends StatelessWidget {
  final String name;
  const _BrandMiniBubble({required this.name});

  @override
  Widget build(BuildContext context) {
    final b = _brand(name);
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: b.bg,
        border: Border.all(color: Colors.black.withOpacity(0.06)),
      ),
      child: Center(
        child: Text(
          b.label.length > 2 ? b.label.substring(0, 2) : b.label,
          style: TextStyle(fontWeight: FontWeight.w900, color: b.fg, fontSize: 12),
        ),
      ),
    );
  }

  _BrandStyle _brand(String n) {
    final up = n.toUpperCase();
    if (up.contains('SHELL')) return const _BrandStyle('SH', Color(0xFFFFF3CD), Color(0xFFB45309));
    if (up.contains('OPET')) return const _BrandStyle('OP', Color(0xFFDDEBFF), Color(0xFF1D4ED8));
    if (up.contains('PETROL OFİS') || up.contains('PETROL OFISI')) return const _BrandStyle('PO', Color(0xFFFFE4E6), Color(0xFFBE123C));
    if (up.contains('BP')) return const _BrandStyle('BP', Color(0xFFD1FAE5), Color(0xFF047857));
    if (up.contains('TOTAL')) return const _BrandStyle('TO', Color(0xFFFEE2E2), Color(0xFFB91C1C));
    return const _BrandStyle('⛽', Color(0xFFF3F4F6), Color(0xFF111827));
  }
}

class _BrandStyle {
  final String label;
  final Color bg;
  final Color fg;
  const _BrandStyle(this.label, this.bg, this.fg);
}

class _ErrorBanner extends StatelessWidget {
  final String text;
  final VoidCallback onRetry;

  const _ErrorBanner({required this.text, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black87,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(color: Colors.white),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: onRetry,
              child: const Text('Tekrar dene'),
            ),
          ],
        ),
      ),
    );
  }
}

// Premium sheet helpers
class _GlassSheet extends StatelessWidget {
  final Widget child;
  const _GlassSheet({required this.child});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          color: Colors.white.withOpacity(0.92),
          border: Border.all(color: Colors.black.withOpacity(0.06)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.18),
              blurRadius: 30,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 54,
      height: 6,
      margin: const EdgeInsets.only(top: 10, bottom: 14),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.10),
        borderRadius: BorderRadius.circular(99),
      ),
    );
  }
}

class _SheetOption extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SheetOption({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.place_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(color: Colors.black54)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}

class _ForecastItem {
  final String title;
  final String message;
  const _ForecastItem({required this.title, required this.message});
}
