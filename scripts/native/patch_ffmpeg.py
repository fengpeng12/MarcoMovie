"""Small, explicit Media3 1.5.1 TrueHD fix; included in corresponding sources.

Initialise the declared TrueHD channel layout, then preserve it on seek.
Upstream reproduction: https://github.com/androidx/media/issues/1843
"""
def patch(path):
    source = path.read_text()
    start = source.index('  AVCodecID codecId = context->codec_id;\n')
    end = source.index('  avcodec_flush_buffers(context);', start)
    source = source[:start] + source[end:]
    old = 'context->codec_id == AV_CODEC_ID_PCM_ALAW) {'
    assert source.count(old) == 1
    source = source.replace(old, 'context->codec_id == AV_CODEC_ID_PCM_ALAW ||\n      context->codec_id == AV_CODEC_ID_TRUEHD) {')
    path.write_text(source)
