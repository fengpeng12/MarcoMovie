"""Owned memory package exercising the shared native source host on iOS.

This module only constructs its bundled fixture; callers cannot supply source
text, module names, arbitrary package files or filesystem paths.
"""
import json

from native_source_host import NativePythonSource


FILES = {
    "owned_source/__init__.py": b"PACKAGE_MARK = 'owned-memory-package'\n",
    "owned_source/helpers.py": "def label():\n    return '内存包相对模块'\n".encode(),
    "owned_source/data/catalog.json": '{"label":"内存包资源"}'.encode(),
    "owned_source/main.py": r'''
import json
from importlib.resources import files
from base.spider import Spider as BaseSpider
from .helpers import label

MODULE_INSTANCES = 0

class Spider(BaseSpider):
    def __init__(self):
        global MODULE_INSTANCES
        MODULE_INSTANCES += 1
        self.calls = 0
        self.initializations = 0

    def init(self, extension):
        self.initializations += 1
        self.extension = extension
        self.origin = json.loads(extension)['origin']

    def homeContent(self, filtered):
        self.calls += 1
        response = self.fetch(self.origin + '/echo')
        resource = json.loads(files('owned_source').joinpath('data/catalog.json').read_text(encoding='utf-8'))
        return {'class': [{'type_id': 'film', 'type_name': '电影'}],
                'relative_module': label(), 'resource': resource['label'],
                'raw_extension': self.extension.startswith('  ') and self.extension.endswith('\n'),
                'request_method': response.json()['method'],
                'initializations': self.initializations, 'module_instances': MODULE_INSTANCES,
                'calls': self.calls}

    def homeVideoContent(self):
        self.calls += 1
        return {'list': [{'vod_id': 'owned', 'vod_name': '内存包推荐'}]}

    def categoryContent(self, category, page, filtered, extend):
        self.calls += 1
        return json.dumps({'page': page, 'category': category, 'filtered': filtered,
                           'extend': extend, 'list': []}, ensure_ascii=False)

    def searchContent(self, word, quick, page='1'):
        self.calls += 1
        return json.dumps({'list': [{'vod_id': 'owned', 'vod_name': word}],
                           'page': page, 'quick': quick}, ensure_ascii=False)

    def detailContent(self, ids):
        self.calls += 1
        return {'ids': ids, 'list': [{'vod_id': ids[0], 'vod_name': '内存包详情',
                    'vod_play_from': 'owned', 'vod_play_url': '第一集$episode-1'}]}

    def playerContent(self, flag, id, vipFlags):
        self.calls += 1
        return {'parse': 0, 'url': self.getProxyUrl({'item': id}), 'calls': self.calls}

    def liveContent(self, url):
        self.calls += 1
        if url == 'text':
            return '#EXTM3U\n#EXTINF:-1,Owned\nrelative/stream.m3u8\n'
        return json.dumps({'url': url, 'list': []})

    def localProxy(self, params):
        self.calls += 1
        if params.get('range') != 'bytes=0-5' or params.get('method') not in ('GET', 'HEAD'):
            return [416, 'text/plain', 'Expected owned Range fixture']
        return [206, 'application/octet-stream', bytes([0,255,128,13,10,65]),
                {'Content-Range': 'bytes 0-5/6', 'X-Instance-Calls': str(self.calls)}]
'''.encode(),
}


def create(origin, proxy_url, bridge):
    extension = '  ' + json.dumps({'origin': origin}) + '\n'
    return NativePythonSource(
        "owned_source/main.py", FILES, bridge=bridge,
        raw_extension=extension, proxy_url=proxy_url,
    )


def dispatch(source, method, args, operation_id):
    return source.invoke(method, args, budget=12, operation_id=operation_id)


def close(source):
    source.close()
