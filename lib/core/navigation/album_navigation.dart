/// 播放页 → 专辑页的跨 Navigator 导航回调。
///
/// 播放页在根 Navigator 上，专辑页需要推到当前 tab Navigator。
/// 由 MainScaffold 设置回调，PlayerPage / ArtistDetailPage 调用。
abstract final class AlbumNavigation {
  static void Function(int, String)? onNavigateToAlbum;
}
