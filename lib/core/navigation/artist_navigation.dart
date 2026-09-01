/// 播放页 → 歌手页的跨 Navigator 导航回调。
///
/// 播放页在根 Navigator 上，歌手页需要推到当前 tab Navigator。
/// 由 MainScaffold 设置回调，PlayerPage 调用。
abstract final class ArtistNavigation {
  static void Function(int, String)? onNavigateToArtist;
}
