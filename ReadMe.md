# MusicBox

用 SwiftUI 实现的网易云播放器

## Novelty

- 基于 AVPlayer / AVSampleBufferAudioRenderer (removed) 实现音频播放，可以实现空间音频
- 直接上传至音乐云盘并与在线歌曲进行匹配
- 原生界面

## Limitation

- 缺少大量功能
  - 播客
  - 账户管理
  - 私信
  - 私人漫游
  - 视频
  - 关注
- 项目组织、性能可能不太好

## Screenshots

![歌单](./Screenshots/playlist.png)

![歌词](./Screenshots/lyric.png)

## Note & Usage

- 建议使用扫码登录，手机号登录如果需要登入验证，没有做对应的处理
- 播放的时候会在 ~/Music/MusicBox 下边播放边进行缓存，文件名以网易云的歌曲 ID 命名，默认为可以下载到的最高音质
  - 第一次播放时的缓存过程中因为存在跳转的目标与实际播放目标不匹配的问题，禁用了拖动进度条功能，待到缓存完成后才可拖动进度条
  - 在歌单的功能栏处的 "Download All" ![Download ALl](./Screenshots/download_all.png) 按钮会在后台对所有歌曲进行缓存
  - ![play_all_add_all](./Screenshots/play_all_add_all.png) 分别是将当前的歌单替换为播放列表和添加当前歌单添加到播放列表
- 歌单、歌词的加载缓存，如果需要对歌单进行刷新，可以点 "Refresh Playlist" ![Refresh Playlist](./Screenshots/refresh_playlist.png) 按钮
- 歌曲列表标题右侧的图标表示当前歌曲的状态
  - ![cloud](./Screenshots/cloud.png) 歌曲在云盘中
  - ![dollar](./Screenshots/dollar.png) VIP 歌曲或需要单独购买专辑
  - ![gift](./Screenshots/gift.png) 非会员可免费播放低音质，会员可播放高音质及下载
- 点左下角的歌曲封面会切换到歌词界面
  - 歌词界面右上角 ![timestamp_roma](./Screenshots/timestamp_roma.png) 分别是显示某一句歌词的时间戳和显示罗马音（如果有）
  - 歌词的上下句切换可能存在一些延迟

## Acknowledgment

- [QCloudMusicApi](https://github.com/s12mmm3/QCloudMusicApi): 网易云 API 接口
- [CachingPlayerItem](https://github.com/sukov/CachingPlayerItem): 音频缓存
- [AudioStreaming](https://github.com/dimitris-c/AudioStreaming)
- [iOSAACStreamPlayer](https://github.com/UFOooX/iOSAACStreamPlayer)
