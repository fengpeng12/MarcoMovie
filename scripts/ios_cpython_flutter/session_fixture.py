"""Owned-only native session fixture; no user script/module execution entry."""
import base64
import hashlib
import importlib.metadata
import sys

import requests
from bs4 import BeautifulSoup

_module_instances = 0


class Spider:
    def __init__(self, origin):
        global _module_instances
        _module_instances += 1
        self.module_instance = _module_instances
        self.origin = origin
        self.calls = 0
        self.session = requests.Session()
        self.session.trust_env = False

    def fetch(self, route, params=None):
        self.calls += 1
        response = self.session.get(self.origin + route, params=params, timeout=(2, 2), allow_redirects=False)
        if 300 <= response.status_code < 400:
            response.close()
            raise ValueError("Owned fixture does not follow redirects")
        response.raise_for_status()
        return response

    def homeContent(self, filtered):
        value = self.fetch("/catalog").json()
        value.update(fixture_calls=self.calls, module_instance=self.module_instance,
                     python=sys.version, requests=importlib.metadata.version("requests"))
        return value

    def homeVideoContent(self):
        return self.fetch("/catalog").json()

    def categoryContent(self, category, page, filtered, extend):
        return self.fetch("/catalog", {"id": category, "page": page}).json()

    def searchContent(self, keyword, quick=False):
        return self.fetch("/search", {"q": keyword}).json()

    def detailContent(self, ids):
        value = self.fetch("/detail", {"id": ids[0]}).json()
        value["list"][0]["vod_content"] = BeautifulSoup("<b>本机详情</b>", "html.parser").get_text()
        return value

    def playerContent(self, flag, episode, vip_flags):
        return self.fetch("/play", {"episode": episode}).json()

    def localProxy(self, params):
        response = self.fetch("/binary")
        return {"status": response.status_code, "mime": response.headers["Content-Type"],
                "bodyBase64": base64.b64encode(response.content).decode("ascii"),
                "headers": {"X-Fixture": response.headers["X-Fixture"]},
                "sha256": hashlib.sha256(response.content).hexdigest(), "fixture_calls": self.calls}


def create(origin):
    return Spider(origin)


def dispatch(spider, method, args):
    mapping = {"home": "homeContent", "homeVod": "homeVideoContent", "category": "categoryContent",
               "search": "searchContent", "detail": "detailContent", "play": "playerContent", "proxy": "localProxy"}
    if method not in mapping or not isinstance(args, list):
        raise ValueError("Invalid fixture call")
    return getattr(spider, mapping[method])(*args)


def close(spider):
    spider.session.close()
